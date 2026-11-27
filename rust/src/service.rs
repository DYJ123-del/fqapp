//! Standalone read-only HTTP service.
//!
//! This adapter deliberately has a smaller surface than the app loopback
//! server: health, the narrow book detail/directory and novel-detail shapes,
//! and one exact `POST /api/v1/chapters/full` Relay. Only the metadata shapes
//! reach the dispatcher.

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderName, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response as AxumResponse};
use axum::Router;
use base64::Engine as _;
use serde_json::json;

use crate::config::Config;
use crate::device::{pool_crypto, DevicePool};
use crate::dispatch::{dispatch, Request, ResponseBody};
use crate::endpoints::full_relay::{self, RelayAuth, RelayHandshakeKey};
use crate::endpoints::{Ctx, Server};
use crate::filter::FilterManager;
use crate::server::read_request_body;
use crate::sign::Manager;
use crate::upstream::UpstreamClient;

const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";

#[derive(Debug, Clone)]
pub struct ServiceOptions {
    pub config_path: PathBuf,
    pub pool_path: PathBuf,
    pub filter_path: PathBuf,
    pub pool_key_path: PathBuf,
    pub listen: SocketAddr,
    pub mock_upstream: Option<String>,
}

pub async fn build_server(options: &ServiceOptions) -> Result<Arc<Server>, String> {
    let config_path = options
        .config_path
        .to_str()
        .ok_or_else(|| "config path is not valid UTF-8".to_string())?;
    let cfg = Arc::new(Config::load(config_path)?);

    provision_pool_key(&options.pool_key_path)?;
    let pool = match options.mock_upstream.as_deref() {
        Some(origin) => DevicePool::with_mock_origin(&options.pool_path, origin).await?,
        None => DevicePool::for_runtime(&options.pool_path).await?,
    };

    let signer = Manager::new();
    let up = Arc::new(match options.mock_upstream.as_deref() {
        Some(origin) => UpstreamClient::with_mock_origin(pool.clone(), signer, origin)?,
        None => UpstreamClient::new(pool.clone(), signer)?,
    });

    let filter_path = options
        .filter_path
        .to_str()
        .ok_or_else(|| "filter path is not valid UTF-8".to_string())?;
    let base_dir = options
        .config_path
        .parent()
        .and_then(|path| path.to_str())
        .unwrap_or("");
    let filters = Arc::new(if filter_path.is_empty() {
        FilterManager::default()
    } else {
        FilterManager::load_with_base(filter_path, base_dir)?
    });

    Ok(Arc::new(Server::new(Arc::new(Ctx {
        up,
        pool,
        cfg,
        src_dir: String::new(),
        filters,
    }))))
}

pub async fn serve(listener: tokio::net::TcpListener, server: Arc<Server>) -> Result<(), String> {
    let relay_auth = RelayAuth::from_env()?.map(Arc::new);
    let relay_handshake_key = RelayHandshakeKey::from_env()?.map(Arc::new);
    if relay_auth.is_some() && relay_handshake_key.is_none() {
        return Err(format!(
            "{} is required when installation authentication is enabled",
            full_relay::HANDSHAKE_KEY_ENV
        ));
    }
    serve_inner(listener, server, relay_auth, relay_handshake_key).await
}

/// Host-test entry point with an explicit Relay handshake key.
///
/// The production [`serve`] path reads the key from the environment. Tests use
/// this helper so they never mutate process-wide environment variables.
pub async fn serve_with_relay_key(
    listener: tokio::net::TcpListener,
    server: Arc<Server>,
    handshake_key: Option<[u8; 16]>,
) -> Result<(), String> {
    serve_inner(
        listener,
        server,
        None,
        handshake_key
            .map(RelayHandshakeKey::from_bytes)
            .map(Arc::new),
    )
    .await
}

async fn serve_inner(
    listener: tokio::net::TcpListener,
    server: Arc<Server>,
    relay_auth: Option<Arc<RelayAuth>>,
    relay_handshake_key: Option<Arc<RelayHandshakeKey>>,
) -> Result<(), String> {
    let local = listener
        .local_addr()
        .map_err(|error| format!("service listener address: {error}"))?;
    if !local.ip().is_loopback() {
        return Err(format!(
            "service listener must be a loopback address, got {local}"
        ));
    }
    let state = ServiceState {
        server,
        port: local.port(),
        relay_auth,
        relay_handshake_key,
    };
    let app = Router::new().fallback(handle_request).with_state(state);
    axum::serve(listener, app)
        .await
        .map_err(|error| format!("service listener: {error}"))
}

#[derive(Clone)]
struct ServiceState {
    server: Arc<Server>,
    port: u16,
    relay_auth: Option<Arc<RelayAuth>>,
    relay_handshake_key: Option<Arc<RelayHandshakeKey>>,
}

// This build binds loopback only. A public deployment must replace this check
// with its configured reverse-proxy authority rather than disabling it.
fn request_refusal(headers: &axum::http::HeaderMap, port: u16) -> Option<&'static str> {
    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    if !host.is_some_and(|authority| is_loopback_authority(authority, port)) {
        return Some("host not allowed");
    }
    if let Some(origin) = headers.get(header::ORIGIN) {
        if !origin
            .to_str()
            .is_ok_and(|value| is_loopback_origin(value, port))
        {
            return Some("origin not allowed");
        }
    }
    None
}

fn is_loopback_authority(authority: &str, port: u16) -> bool {
    let Some((host, authority_port)) = authority.rsplit_once(':') else {
        return false;
    };
    if authority_port.parse::<u16>().ok() != Some(port) {
        return false;
    }
    let host = host
        .strip_prefix('[')
        .and_then(|value| value.strip_suffix(']'))
        .unwrap_or(host);
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

fn is_loopback_origin(origin: &str, port: u16) -> bool {
    let Some((scheme, authority)) = origin.split_once("://") else {
        return false;
    };
    (scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https"))
        && is_loopback_authority(authority, port)
}

fn provision_pool_key(path: &std::path::Path) -> Result<(), String> {
    let encoded = std::fs::read_to_string(path)
        .map_err(|error| format!("read pool key file {}: {error}", path.display()))?;
    let key = base64::engine::general_purpose::STANDARD
        .decode(encoded.trim())
        .map_err(|_| "pool key file is not valid base64".to_string())?;
    if key.len() != 32 {
        return Err(format!(
            "pool key file must decode to 32 bytes, got {}",
            key.len()
        ));
    }
    pool_crypto::provision_pool_key(key)
}

#[derive(Debug)]
enum ServiceRoute {
    Health,
    Book(String),
    Novel(String),
}

fn route_for(path: &str) -> Option<ServiceRoute> {
    if path == "/health" {
        return Some(ServiceRoute::Health);
    }

    let trimmed = path.strip_suffix('/').unwrap_or(path);
    if let Some(rest) = trimmed.strip_prefix("/api/v1/novels/") {
        return valid_book_id(rest).then(|| ServiceRoute::Novel(trimmed.to_string()));
    }

    let rest = trimmed.strip_prefix("/api/v1/books/")?;
    let mut parts = rest.split('/');
    let book_id = parts.next()?;
    if !valid_book_id(book_id) {
        return None;
    }

    let allowed = match parts.collect::<Vec<_>>().as_slice() {
        [] => true,
        ["detail"] | ["directory"] => true,
        ["directory", "novel"] | ["directory", "fanqie"] => true,
        _ => false,
    };
    allowed.then(|| ServiceRoute::Book(trimmed.to_string()))
}

fn valid_book_id(book_id: &str) -> bool {
    !book_id.is_empty()
        && book_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

async fn handle_request(
    State(state): State<ServiceState>,
    incoming: axum::extract::Request,
) -> AxumResponse {
    if let Some(reason) = request_refusal(incoming.headers(), state.port) {
        return error_response(StatusCode::FORBIDDEN, reason, false);
    }
    let path = incoming.uri().path().to_string();
    let query = incoming.uri().query().unwrap_or("").to_string();
    let is_get = incoming.method() == axum::http::Method::GET;

    if path == full_relay::FULL_RELAY_PATH {
        if incoming.method() != axum::http::Method::POST {
            return relay_error_response(
                StatusCode::METHOD_NOT_ALLOWED,
                "method_not_allowed",
                "method not allowed",
                Some("POST"),
            );
        }
        return handle_full_relay(state, incoming).await;
    }

    let Some(route) = route_for(&path) else {
        return error_response(StatusCode::NOT_FOUND, "not found", false);
    };
    if !is_get {
        return error_response(StatusCode::METHOD_NOT_ALLOWED, "method not allowed", true);
    }

    let path = match route {
        ServiceRoute::Health => "/health".to_string(),
        ServiceRoute::Book(path) => path,
        ServiceRoute::Novel(path) => path,
    };
    let request = Request {
        method: "GET".to_string(),
        path,
        query,
        body: Vec::new(),
        headers: Vec::new(),
    };
    drop(incoming);
    match crate::upstream::budget::within(
        crate::upstream::budget::HTTP_REQUEST_TIMEOUT,
        dispatch(&state.server, &request),
    )
    .await
    {
        Ok(response) => response_from_dispatch(response),
        Err(()) => error_response(
            StatusCode::GATEWAY_TIMEOUT,
            "request deadline exceeded",
            false,
        ),
    }
}

async fn handle_full_relay(state: ServiceState, incoming: axum::extract::Request) -> AxumResponse {
    let declared = incoming
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok());
    if declared.is_some_and(|len| len > full_relay::FULL_RELAY_BODY_LIMIT as u64) {
        return relay_error_response(
            StatusCode::PAYLOAD_TOO_LARGE,
            "request_too_large",
            "request body too large",
            None,
        );
    }
    let headers: Vec<(String, String)> = incoming
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_ascii_lowercase(),
                value.to_str().unwrap_or("").to_string(),
            )
        })
        .collect();

    match crate::upstream::budget::within(
        crate::upstream::budget::HTTP_REQUEST_TIMEOUT,
        async move {
            let body =
                match read_request_body(incoming.into_body(), full_relay::FULL_RELAY_BODY_LIMIT)
                    .await
                {
                    Ok(body) => body,
                    Err(status) if status == StatusCode::PAYLOAD_TOO_LARGE => {
                        return relay_error_response(
                            StatusCode::PAYLOAD_TOO_LARGE,
                            "request_too_large",
                            "request body too large",
                            None,
                        );
                    }
                    Err(_) => {
                        return relay_error_response(
                            StatusCode::BAD_REQUEST,
                            "invalid_request",
                            "invalid request",
                            None,
                        );
                    }
                };
            let response = full_relay::handle(
                &state.server.ctx,
                state.relay_auth.as_deref(),
                state.relay_handshake_key.as_deref(),
                &headers,
                &body,
            )
            .await;
            response_from_dispatch(response)
        },
    )
    .await
    {
        Ok(response) => response,
        Err(()) => relay_error_response(
            StatusCode::GATEWAY_TIMEOUT,
            "deadline_exceeded",
            "request deadline exceeded",
            None,
        ),
    }
}

fn response_from_dispatch(response: crate::dispatch::Response) -> AxumResponse {
    let crate::dispatch::Response {
        status,
        content_type,
        headers,
        body,
    } = response;
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    let ResponseBody::Bytes(bytes) = body else {
        return error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal server error",
            false,
        );
    };

    let mut builder = secured_builder(status, &content_type);
    for (name, value) in headers {
        let name_lower = name.to_ascii_lowercase();
        if matches!(
            name_lower.as_str(),
            "content-type" | "cache-control" | "referrer-policy" | "x-content-type-options"
        ) {
            continue;
        }
        if let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(&value),
        ) {
            builder = builder.header(name, value);
        }
    }
    builder
        .body(Body::from(bytes))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn error_response(status: StatusCode, message: &'static str, allow_get: bool) -> AxumResponse {
    let body = serde_json::to_vec(&json!({
        "success": false,
        "error": message,
    }))
    .unwrap_or_default();
    let mut builder = secured_builder(status, JSON_CONTENT_TYPE);
    if allow_get {
        builder = builder.header(header::ALLOW, HeaderValue::from_static("GET"));
    }
    builder
        .body(Body::from(body))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn relay_error_response(
    status: StatusCode,
    error_code: &'static str,
    message: &'static str,
    allow: Option<&'static str>,
) -> AxumResponse {
    let body = serde_json::to_vec(&json!({
        "success": false,
        "error": message,
        "error_code": error_code,
    }))
    .unwrap_or_default();
    let mut builder = secured_builder(status, JSON_CONTENT_TYPE);
    if let Some(allow) = allow {
        builder = builder.header(header::ALLOW, HeaderValue::from_static(allow));
    }
    builder
        .body(Body::from(body))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

fn secured_builder(status: StatusCode, content_type: &str) -> axum::http::response::Builder {
    let content_type = HeaderValue::from_str(content_type)
        .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    AxumResponse::builder()
        .status(status)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CACHE_CONTROL, HeaderValue::from_static("no-store"))
        .header(
            header::REFERRER_POLICY,
            HeaderValue::from_static("no-referrer"),
        )
        .header(
            HeaderName::from_static("x-content-type-options"),
            HeaderValue::from_static("nosniff"),
        )
}

// `server.rs` is also used by the shared host-test harness. In a service-only
// build it needs the same race helper as the Flutter bridge, but must not pull
// in the bridge module itself.
#[cfg(all(feature = "service", not(feature = "app")))]
#[derive(Debug)]
pub(crate) enum RaceOutcome<T> {
    Done(T),
    Cancelled,
    TimedOut,
}

#[cfg(all(feature = "service", not(feature = "app")))]
pub(crate) async fn race_dispatch<F>(
    token: &tokio_util::sync::CancellationToken,
    deadline: Option<std::time::Duration>,
    work: F,
) -> RaceOutcome<F::Output>
where
    F: std::future::Future,
{
    tokio::pin!(work);
    let outcome = match deadline {
        Some(limit) => tokio::select! {
            biased;
            _ = token.cancelled() => RaceOutcome::Cancelled,
            result = crate::upstream::budget::within(limit, &mut work) => match result {
                Ok(response) => RaceOutcome::Done(response),
                Err(()) => RaceOutcome::TimedOut,
            },
        },
        None => tokio::select! {
            biased;
            _ = token.cancelled() => RaceOutcome::Cancelled,
            response = &mut work => RaceOutcome::Done(response),
        },
    };
    if token.is_cancelled() {
        RaceOutcome::Cancelled
    } else {
        outcome
    }
}
