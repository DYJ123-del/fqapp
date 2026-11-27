//! HTTP boundary for the standalone read-only service.
#![cfg(feature = "service")]

mod common;

use std::net::SocketAddr;
use std::time::Duration;

use base64::Engine as _;
use common::{build_server_with_config, pool_json, query_map, MockReply, MockUpstream, TempDir};
use fqapi_core::crypto::{aes_cbc_decrypt, pkcs7_unpad_strict};
use fqapi_core::endpoints::full_relay::FULL_RELAY_BODY_LIMIT;
use fqapi_core::service::serve_with_relay_key;
use md5::{Digest, Md5};
use reqwest::header::{HeaderMap, ALLOW, CACHE_CONTROL, CONTENT_TYPE, REFERRER_POLICY};
use reqwest::{Client, Method, StatusCode};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const MOCK_JSON: &str = r#"{"code":0,"data":{}}"#;
const RELAY_PATH: &str = "/novelfm/playerapi/full/mget/v1/";
const RELAY_ITEM_ID: &str = "chapter-1";
const RELAY_JSON: &str = r#"{"code":0,"data":{"item_infos":{"chapter-1":{"title":"Chapter","key":"peer-key","content":"ciphertext"}},"kept":true},"root_extra":"kept"}"#;
const TEST_HANDSHAKE_KEY: [u8; 16] = [
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
];

struct Fixture {
    _dir: TempDir,
    mock: MockUpstream,
    addr: SocketAddr,
    task: tokio::task::JoinHandle<Result<(), String>>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn fixture(tag: &str) -> Fixture {
    fixture_with_relay_reply(tag, RELAY_JSON).await
}

async fn fixture_with_relay_reply(tag: &str, relay_reply: &'static str) -> Fixture {
    let dir = TempDir::new(tag);
    let mock = MockUpstream::start(move |request| {
        let body = if request.path == RELAY_PATH {
            relay_reply
        } else {
            MOCK_JSON
        };
        MockReply {
            status: 200,
            headers: vec![("content-type".to_string(), "application/json".to_string())],
            body: body.as_bytes().to_vec(),
        }
    })
    .await;
    let server = build_server_with_config(
        &dir,
        Some(mock.origin.clone()),
        &[],
        &[("secret.txt", "DO_NOT_SERVE")],
        &pool_json(5),
        r#"{"algorithm_type":"8404","port":0,"zwsm":"suffix","anti_crawler":{"enabled":false,"redirect_url":""}}"#,
    )
    .await;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind service");
    let addr = listener.local_addr().expect("service address");
    let task = tokio::spawn(serve_with_relay_key(
        listener,
        server,
        Some(TEST_HANDSHAKE_KEY),
    ));
    Fixture {
        _dir: dir,
        mock,
        addr,
        task,
    }
}

fn client() -> Client {
    Client::builder().no_proxy().build().expect("http client")
}

async fn send(
    client: &Client,
    method: Method,
    addr: SocketAddr,
    path: &str,
) -> (StatusCode, HeaderMap, Vec<u8>) {
    let response = client
        .request(method, format!("http://{addr}{path}"))
        .send()
        .await
        .expect("service response");
    let status = response.status();
    let headers = response.headers().clone();
    let body = response.bytes().await.expect("response body").to_vec();
    (status, headers, body)
}

async fn send_json(
    client: &Client,
    addr: SocketAddr,
    body: Vec<u8>,
) -> (StatusCode, HeaderMap, Vec<u8>) {
    let response = client
        .post(format!("http://{addr}/api/v1/chapters/full"))
        .header(CONTENT_TYPE, "application/json")
        .body(body)
        .send()
        .await
        .expect("relay response");
    let status = response.status();
    let headers = response.headers().clone();
    let body = response.bytes().await.expect("relay body").to_vec();
    (status, headers, body)
}

fn relay_body(book_id: &str, item_ids: Value, client_public_key: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "book_id": book_id,
        "item_ids": item_ids,
        "client_public_key": client_public_key,
    }))
    .expect("relay request json")
}

fn valid_client_key() -> String {
    base64::engine::general_purpose::STANDARD.encode([2u8])
}

fn error_code(body: &[u8]) -> Option<String> {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|value| value.get("error_code")?.as_str().map(str::to_string))
}

async fn send_raw(addr: SocketAddr, request: &str) -> (StatusCode, Vec<u8>) {
    let mut stream = tokio::net::TcpStream::connect(addr)
        .await
        .expect("raw service connection");
    stream
        .write_all(request.as_bytes())
        .await
        .expect("raw request write");
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(&mut response))
        .await
        .expect("raw response timeout")
        .expect("raw response read");
    let header_end = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
        .expect("response headers");
    let head = String::from_utf8_lossy(&response[..header_end]);
    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .expect("response status");
    (
        StatusCode::from_u16(status).expect("valid response status"),
        response[header_end..].to_vec(),
    )
}

fn raw_get(target: &str, host: &str, origin: Option<&str>) -> String {
    let mut request = format!(
        "GET {target} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nAccept: application/json\r\n"
    );
    if let Some(origin) = origin {
        request.push_str(&format!("Origin: {origin}\r\n"));
    }
    request.push_str("\r\n");
    request
}

fn assert_security_headers(headers: &HeaderMap) {
    assert_eq!(
        headers
            .get(CACHE_CONTROL)
            .and_then(|value| value.to_str().ok()),
        Some("no-store")
    );
    assert_eq!(
        headers
            .get(REFERRER_POLICY)
            .and_then(|value| value.to_str().ok()),
        Some("no-referrer")
    );
    assert_eq!(
        headers
            .get("x-content-type-options")
            .and_then(|value| value.to_str().ok()),
        Some("nosniff")
    );
}

#[tokio::test]
async fn health_and_allowed_read_shapes_return_json_unchanged() {
    let fixture = fixture("service-allowed").await;
    let client = client();

    let (status, headers, body) = send(&client, Method::GET, fixture.addr, "/health").await;
    assert_eq!(status, StatusCode::OK);
    assert_security_headers(&headers);
    let health: Value = serde_json::from_slice(&body).expect("health json");
    assert_eq!(health["devices"], 5);
    assert_eq!(fixture.mock.requests().len(), 0);

    for path in [
        "/api/v1/books/123",
        "/api/v1/books/123/detail",
        "/api/v1/books/123/directory",
        "/api/v1/books/123/directory/novel",
        "/api/v1/books/123/directory/fanqie",
        "/api/v1/novels/123",
    ] {
        let before = fixture.mock.requests().len();
        let (status, headers, body) = send(&client, Method::GET, fixture.addr, path).await;
        assert_eq!(status, StatusCode::OK, "{path}");
        assert_security_headers(&headers);
        assert_eq!(body, MOCK_JSON.as_bytes(), "{path}");
        assert_eq!(fixture.mock.requests().len(), before + 1, "{path}");
    }

    let before = fixture.mock.requests().len();
    let (status, _, body) = send(
        &client,
        Method::GET,
        fixture.addr,
        "/api/v1/books/123/detail/",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, MOCK_JSON.as_bytes());
    assert_eq!(fixture.mock.requests().len(), before + 1);
}

#[tokio::test]
async fn full_relay_is_post_only() {
    let fixture = fixture("service-full-method").await;
    let client = client();
    let before = fixture.mock.requests().len();

    for method in [
        Method::GET,
        Method::HEAD,
        Method::PUT,
        Method::PATCH,
        Method::DELETE,
        Method::OPTIONS,
    ] {
        let (status, headers, body) = send(
            &client,
            method.clone(),
            fixture.addr,
            "/api/v1/chapters/full",
        )
        .await;
        assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED, "{method}");
        assert_eq!(
            headers.get(ALLOW).and_then(|value| value.to_str().ok()),
            Some("POST"),
            "{method}"
        );
        assert_security_headers(&headers);
        if method != Method::HEAD {
            assert_eq!(
                error_code(&body).as_deref(),
                Some("method_not_allowed"),
                "{method}"
            );
        }
    }
    assert_eq!(fixture.mock.requests().len(), before);
}

#[tokio::test]
async fn full_relay_rejects_bad_params_keys_and_oversized_bodies() {
    let fixture = fixture("service-full-validation").await;
    let client = client();
    let key = valid_client_key();
    let before = fixture.mock.requests().len();

    let invalid_requests = [
        ("malformed json", b"{".to_vec()),
        (
            "missing fields",
            serde_json::to_vec(&json!({})).expect("json"),
        ),
        (
            "multiple items",
            relay_body("book-1", json!(["chapter-1", "chapter-2"]), &key),
        ),
        ("empty items", relay_body("book-1", json!([]), &key)),
        ("non-string item", relay_body("book-1", json!([42]), &key)),
        (
            "bad book id",
            relay_body("../book", json!(["chapter-1"]), &key),
        ),
        (
            "bad item id",
            relay_body("book-1", json!(["chapter/one"]), &key),
        ),
        (
            "long book id",
            relay_body(&"a".repeat(129), json!(["chapter-1"]), &key),
        ),
    ];
    for (label, body) in invalid_requests {
        let (status, _, body) = send_json(&client, fixture.addr, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{label}");
        assert_eq!(
            error_code(&body).as_deref(),
            Some("invalid_request"),
            "{label}"
        );
    }

    for (label, client_key) in [
        ("unpadded", "Ag"),
        ("url-safe", "_-8="),
        ("zero", "AA=="),
        ("one", "AQ=="),
        ("sign prefix", "AAI="),
    ] {
        let body = relay_body("book-1", json!(["chapter-1"]), client_key);
        let (status, _, body) = send_json(&client, fixture.addr, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{label}");
        assert_eq!(
            error_code(&body).as_deref(),
            Some("invalid_client_key"),
            "{label}"
        );
    }

    let (status, _, body) =
        send_json(&client, fixture.addr, vec![b'x'; FULL_RELAY_BODY_LIMIT + 1]).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(error_code(&body).as_deref(), Some("request_too_large"));
    assert_eq!(fixture.mock.requests().len(), before);
}

#[tokio::test]
async fn full_relay_forwards_ciphertext_unchanged_with_relay_metadata() {
    let fixture = fixture("service-full-success").await;
    let client = client();
    let key = valid_client_key();
    let mut request: Value =
        serde_json::from_slice(&relay_body("book-1", json!([RELAY_ITEM_ID]), &key))
            .expect("request json");
    request["ignored"] = json!({"future": true});
    let request_body = serde_json::to_vec(&request).expect("request body");
    let before = fixture.mock.requests().len();

    let (status, headers, body) = send_json(&client, fixture.addr, request_body).await;
    assert_eq!(status, StatusCode::OK);
    assert_security_headers(&headers);
    let response: Value = serde_json::from_slice(&body).expect("response json");
    assert_eq!(response["code"], 0);
    assert_eq!(
        response["data"]["item_infos"][RELAY_ITEM_ID]["title"],
        "Chapter"
    );
    assert_eq!(
        response["data"]["item_infos"][RELAY_ITEM_ID]["key"],
        "peer-key"
    );
    assert_eq!(
        response["data"]["item_infos"][RELAY_ITEM_ID]["content"],
        "ciphertext"
    );
    assert_eq!(response["data"]["kept"], true);
    assert_eq!(response["root_extra"], "kept");
    assert_eq!(response["relay"]["protocol"], 1);
    assert_eq!(response["relay"]["content_suffix"], "suffix");
    assert_eq!(fixture.mock.requests().len(), before + 1);

    let upstream = fixture.mock.last_request().expect("upstream request");
    assert_eq!(upstream.method, "POST");
    assert_eq!(upstream.path, RELAY_PATH);
    for header in ["x-argus", "x-ladon", "x-khronos", "x-ss-stub"] {
        assert!(upstream.header(header).is_some(), "missing {header}");
    }
    let expected_stub = hex::encode(Md5::digest(&upstream.body));
    assert_eq!(upstream.header("x-ss-stub"), Some(expected_stub.as_str()));
    assert!(
        query_map(&upstream.query)
            .get("device_id")
            .is_some_and(|device_id| !device_id.is_empty()),
        "the request must be made under a pooled device"
    );

    let upstream_body: Value =
        serde_json::from_slice(&upstream.body).expect("upstream request json");
    assert_eq!(upstream_body["book_id"], "book-1");
    assert_eq!(upstream_body["item_ids"], json!([RELAY_ITEM_ID]));
    let wrapped = upstream_body["key"].as_str().expect("wrapped client key");
    assert_ne!(wrapped, key);
    let blob = base64::engine::general_purpose::STANDARD
        .decode(wrapped)
        .expect("wrapped key base64");
    assert_eq!(blob.len(), 32);
    let padded = aes_cbc_decrypt(&blob[16..], &TEST_HANDSHAKE_KEY, &blob[..16]);
    assert_eq!(
        pkcs7_unpad_strict(&padded, 16).expect("wrapped key padding"),
        &[2u8][..]
    );
}

#[tokio::test]
async fn full_relay_preserves_business_errors_and_rejects_missing_items() {
    let business = fixture_with_relay_reply(
        "service-full-business-error",
        r#"{"code":7,"data":{"message":"upstream refused"}}"#,
    )
    .await;
    let client = client();
    let body = relay_body("book-1", json!([RELAY_ITEM_ID]), &valid_client_key());
    let (status, _, response) = send_json(&client, business.addr, body).await;
    assert_eq!(status, StatusCode::OK);
    let response: Value = serde_json::from_slice(&response).expect("business response");
    assert_eq!(response["code"], 7);
    assert!(response.get("relay").is_none());

    let invalid = fixture_with_relay_reply(
        "service-full-invalid-upstream",
        r#"{"code":0,"data":{"item_infos":{}}}"#,
    )
    .await;
    let body = relay_body("book-1", json!([RELAY_ITEM_ID]), &valid_client_key());
    let (status, _, response) = send_json(&client, invalid.addr, body).await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(
        error_code(&response).as_deref(),
        Some("upstream_invalid_response")
    );

    let non_json = fixture_with_relay_reply("service-full-non-json", "not json").await;
    let body = relay_body("book-1", json!([RELAY_ITEM_ID]), &valid_client_key());
    let (status, _, response) = send_json(&client, non_json.addr, body).await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(
        error_code(&response).as_deref(),
        Some("upstream_invalid_response")
    );
}

#[tokio::test]
async fn forbidden_routes_are_404_before_dispatch_and_do_not_touch_upstream() {
    let fixture = fixture("service-forbidden").await;
    let client = client();
    let before = fixture.mock.requests().len();

    for (method, path) in [
        (Method::POST, "/api/v1/account/fanqie/history"),
        (Method::POST, "/api/v1/account/fanqie/library"),
        (Method::GET, "/api/v1/account/fanqie/history"),
        (Method::GET, "/api/v1/account/fanqie/library"),
        (Method::GET, "/api/v1/chapters/123"),
        (Method::GET, "/api/v1/chapters/123/"),
        (Method::GET, "/api/v1/chapters/123/summary"),
        (Method::GET, "/api/v1/chapters/123/timeline"),
        (Method::GET, "/api/v1/chapters/123/timepoints"),
        (Method::GET, "/src"),
        (Method::GET, "/src/secret.txt"),
        (Method::GET, "/src/"),
        (Method::GET, "/api/v1/shuqi/search"),
        (Method::GET, "/api/v1/shuqi/search/"),
        (Method::GET, "/api/v1/comments/123/digg"),
        (Method::GET, "/api/v1/books/123/reviews"),
        (Method::GET, "/api/v1/books/123/tones"),
        (Method::GET, "/api/v1/books/123/share"),
        (Method::GET, "/api/v1/books/123/video-match"),
        (Method::GET, "/api/v1/books/123/chapters/summary"),
        (Method::GET, "/api/v1/manga/123"),
        (Method::GET, "/api/v1/series/123"),
        (Method::GET, "/api/v1/videos/123"),
        (Method::GET, "/api/v1/audio/books/123"),
        (Method::GET, "/api/v1/audio/books/123/"),
        (Method::GET, "/api/v1/audio/books/123/chapters/456"),
        (Method::GET, "/api/v1/audio/play"),
        (Method::GET, "/api/v1/audio/wkcontent/123"),
        (Method::POST, "/api/v1/series/123/comments/add"),
        (Method::POST, "/api/v1/videos/456/danmaku/add"),
        (Method::GET, "/api/v1/search"),
        (Method::GET, "/api/v1/search/"),
        (Method::GET, "/api/v1/authors/123"),
        (Method::GET, "/api/v1/items/123"),
    ] {
        let (status, headers, body) = send(&client, method, fixture.addr, path).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{path}");
        assert_security_headers(&headers);
        assert!(!String::from_utf8_lossy(&body).contains("DO_NOT_SERVE"));
    }
    assert_eq!(fixture.mock.requests().len(), before);

    for method in [
        Method::POST,
        Method::HEAD,
        Method::PUT,
        Method::PATCH,
        Method::DELETE,
        Method::OPTIONS,
    ] {
        for path in ["/api/v1/books/123", "/health"] {
            let before = fixture.mock.requests().len();
            let (status, headers, _) = send(&client, method.clone(), fixture.addr, path).await;
            assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED, "{method} {path}");
            assert_eq!(
                headers.get(ALLOW).and_then(|value| value.to_str().ok()),
                Some("GET")
            );
            assert_security_headers(&headers);
            assert_eq!(fixture.mock.requests().len(), before, "{method} {path}");
        }
    }
}

#[tokio::test]
async fn malformed_book_paths_are_404_and_health_is_exact() {
    let fixture = fixture("service-path-shape").await;
    let client = client();
    let before = fixture.mock.requests().len();

    for path in [
        "/health/",
        "/api/v1/chapters/full/",
        "/api/v1/books",
        "/api/v1/books/",
        "/api/v1/books//detail",
        "/api/v1/books/123/detail/extra",
        "/api/v1/books/123/directory/novel/extra",
        "/api/v1/books/123//",
        "/api/v1/books/12.3",
        "/api/v1/books/123%20",
    ] {
        let (status, _, _) = send(&client, Method::GET, fixture.addr, path).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{path}");
    }
    assert_eq!(fixture.mock.requests().len(), before);
}

#[tokio::test]
async fn raw_encoded_paths_and_foreign_authorities_are_rejected() {
    let fixture = fixture("service-raw-boundary").await;
    let authority = fixture.addr.to_string();
    let before = fixture.mock.requests().len();

    for target in [
        "/api/v1/books/123%2Fchapters",
        "/api/v1/books/123%2f..%2fchapters",
        "/api/v1/books/123%5Cchapters",
        "/api/v1/books/123%252Fchapters",
        "/api/v1/books/123/detail%2F..%2F..%2Fchapters",
        "/api/v1/%62ooks/123",
        "/api/v1/chapters/123?api=books&book_id=123",
    ] {
        let (status, body) = send_raw(fixture.addr, &raw_get(target, &authority, None)).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{target}");
        assert!(!String::from_utf8_lossy(&body).contains("DO_NOT_SERVE"));
    }

    let (status, _) = send_raw(
        fixture.addr,
        &raw_get("/api/v1/books/123", "evil.example", None),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let wrong_port_authority = format!("127.0.0.1:{}", fixture.addr.port() + 1);
    let (status, _) = send_raw(
        fixture.addr,
        &raw_get("/api/v1/books/123", &wrong_port_authority, None),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (status, _) = send_raw(
        fixture.addr,
        &raw_get("/api/v1/books/123", &authority, Some("http://evil.example")),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(fixture.mock.requests().len(), before);

    let origin = format!("http://{authority}");
    let (status, _) = send_raw(fixture.addr, &raw_get("/health", &authority, Some(&origin))).await;
    assert_eq!(status, StatusCode::OK);
}
