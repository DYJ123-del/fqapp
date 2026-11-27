//! A3 novel `full` Relay.
//!
//! The server validates the App's temporary CM public key, wraps it for the
//! upstream handshake, forwards one `full/mget` request through the device
//! pool, and returns the upstream ciphertext untouched. It never creates an
//! App private key and never decrypts chapter content.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;
use zeroize::Zeroizing;

use crate::dispatch::Response;
use crate::endpoints::full::fetch_full_mget_raw;
use crate::endpoints::Ctx;
use crate::upstream::cm::wrap_client_public_key;

pub const FULL_RELAY_PATH: &str = "/api/v1/chapters/full";
pub const FULL_RELAY_BODY_LIMIT: usize = 16 * 1024;
pub const HANDSHAKE_KEY_ENV: &str = "FQ_CM_HANDSHAKE_KEY";

const AUTH_CLOCK_SKEW_SECONDS: i64 = 300;
const NONCE_RETENTION: Duration = Duration::from_secs(10 * 60);
const MAX_CONCURRENT_RELAYS: usize = 4;

static RELAY_SLOTS: Lazy<Arc<Semaphore>> =
    Lazy::new(|| Arc::new(Semaphore::new(MAX_CONCURRENT_RELAYS)));
static REPLAYED_NONCES: Lazy<Mutex<HashMap<String, Instant>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/// Deployment-provided 16-byte key used to wrap the App's temporary CM public
/// key into the upstream handshake. Only the base64 value is read from the
/// environment; it is never logged, persisted, or returned.
pub struct RelayHandshakeKey {
    key: Zeroizing<[u8; 16]>,
}

impl RelayHandshakeKey {
    pub fn from_env() -> Result<Option<Self>, String> {
        match env_value(HANDSHAKE_KEY_ENV)? {
            Some(value) => Self::from_base64(&value).map(Some),
            None => Ok(None),
        }
    }

    pub fn from_base64(value: &str) -> Result<Self, String> {
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(value)
            .map_err(|_| format!("{HANDSHAKE_KEY_ENV} must be standard base64"))?;
        let key: [u8; 16] = decoded
            .as_slice()
            .try_into()
            .map_err(|_| format!("{HANDSHAKE_KEY_ENV} must decode to 16 bytes"))?;
        Ok(Self {
            key: Zeroizing::new(key),
        })
    }

    pub(crate) fn from_bytes(key: [u8; 16]) -> Self {
        Self {
            key: Zeroizing::new(key),
        }
    }

    fn as_bytes(&self) -> &[u8] {
        &self.key[..]
    }
}

/// Installation authentication for the Relay.
///
/// Both environment variables must be present together:
/// - `FQ_INSTALL_TOKEN`: the exact Bearer token;
/// - `FQ_INSTALL_SIGNING_KEY`: the HMAC-SHA256 key as UTF-8 bytes, using the
///   same value the App passes to its HMAC implementation.
///
/// Empty values are treated as absent. A deployment that configures only one
/// of them fails to start instead of silently running without authentication.
pub struct RelayAuth {
    install_token: Vec<u8>,
    signing_key: Vec<u8>,
}

impl RelayAuth {
    pub fn from_env() -> Result<Option<Self>, String> {
        let token = env_value("FQ_INSTALL_TOKEN")?;
        let signing_key = env_value("FQ_INSTALL_SIGNING_KEY")?;
        Self::from_values(token, signing_key)
    }

    fn from_values(
        install_token: Option<String>,
        signing_key: Option<String>,
    ) -> Result<Option<Self>, String> {
        match (install_token, signing_key) {
            (None, None) => Ok(None),
            (Some(token), Some(signing_key)) => {
                if signing_key.is_empty() {
                    return Err("FQ_INSTALL_SIGNING_KEY must not be empty".to_string());
                }
                Ok(Some(RelayAuth {
                    install_token: token.into_bytes(),
                    signing_key: signing_key.into_bytes(),
                }))
            }
            _ => {
                Err("FQ_INSTALL_TOKEN and FQ_INSTALL_SIGNING_KEY must be set together".to_string())
            }
        }
    }

    fn authenticate(&self, headers: &[(String, String)], body: &[u8]) -> bool {
        let Some(authorization) = header_value(headers, "authorization") else {
            return false;
        };
        let Some(token) = authorization.strip_prefix("Bearer ") else {
            return false;
        };
        if !constant_time_eq(token.as_bytes(), &self.install_token) {
            return false;
        }

        let Some(timestamp_header) = header_value(headers, "x-fq-timestamp") else {
            return false;
        };
        let Ok(timestamp) = timestamp_header.parse::<i64>() else {
            return false;
        };
        let now = crate::timeutil::now_secs();
        if !now
            .checked_sub(timestamp)
            .is_some_and(|delta| delta.abs() <= AUTH_CLOCK_SKEW_SECONDS)
        {
            return false;
        }

        let Some(nonce) = header_value(headers, "x-fq-nonce") else {
            return false;
        };
        if nonce.len() != 32
            || !nonce
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return false;
        }

        let Some(signature_header) = header_value(headers, "x-fq-signature") else {
            return false;
        };
        let Some(signature_hex) = signature_header.strip_prefix("v1=") else {
            return false;
        };
        if signature_hex.len() != 64
            || !signature_hex
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return false;
        }
        let Ok(signature) = hex::decode(signature_hex) else {
            return false;
        };

        let body_hash = hex::encode(Sha256::digest(body));
        let canonical =
            format!("POST\n{FULL_RELAY_PATH}\n{timestamp_header}\n{nonce}\n{body_hash}");
        let expected = hmac_sha256(&self.signing_key, canonical.as_bytes());
        if !constant_time_eq(&signature, &expected) {
            return false;
        }

        let mut nonces = REPLAYED_NONCES
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        nonces.retain(|_, seen| seen.elapsed() < NONCE_RETENTION);
        if nonces.contains_key(nonce) {
            return false;
        }
        nonces.insert(nonce.to_string(), Instant::now());
        true
    }
}

fn env_value(name: &str) -> Result<Option<String>, String> {
    match std::env::var(name) {
        Ok(value) => {
            let value = value.trim();
            Ok((!value.is_empty()).then(|| value.to_string()))
        }
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(_)) => Err(format!("{name} is not valid UTF-8")),
    }
}

fn header_value<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(header, _)| header.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut diff = 0u8;
    for (&a, &b) in left.iter().zip(right) {
        diff |= a ^ b;
    }
    diff == 0
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut key_block = Zeroizing::new([0u8; 64]);
    let key_block = &mut *key_block;
    if key.len() > key_block.len() {
        let digest = Sha256::digest(key);
        key_block[..32].copy_from_slice(&digest[..]);
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }

    let mut inner = Sha256::new();
    for byte in key_block.iter() {
        inner.update([*byte ^ 0x36]);
    }
    inner.update(data);
    let inner_hash = inner.finalize();

    let mut outer = Sha256::new();
    for byte in key_block.iter() {
        outer.update([*byte ^ 0x5c]);
    }
    outer.update(inner_hash);
    let digest = outer.finalize();
    let mut output = [0u8; 32];
    output.copy_from_slice(&digest[..]);
    output
}

struct RelayRequest {
    book_id: String,
    item_id: String,
    client_public_key: String,
}

fn parse_request(body: &[u8]) -> Result<RelayRequest, Response> {
    let root: Value =
        serde_json::from_slice(body).map_err(|_| invalid_request("invalid request"))?;
    let object = root
        .as_object()
        .ok_or_else(|| invalid_request("invalid request"))?;

    let book_id = object
        .get("book_id")
        .and_then(Value::as_str)
        .filter(|value| valid_identifier(value))
        .ok_or_else(|| invalid_request("invalid request"))?
        .to_string();

    let item_ids = object
        .get("item_ids")
        .and_then(Value::as_array)
        .filter(|values| values.len() == 1)
        .ok_or_else(|| invalid_request("invalid request"))?;
    let item_id = item_ids[0]
        .as_str()
        .filter(|value| valid_identifier(value))
        .ok_or_else(|| invalid_request("invalid request"))?
        .to_string();

    let client_public_key = object
        .get("client_public_key")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_request("invalid request"))?
        .to_string();

    Ok(RelayRequest {
        book_id,
        item_id,
        client_public_key,
    })
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

pub async fn handle(
    ctx: &Ctx,
    auth: Option<&RelayAuth>,
    handshake_key: Option<&RelayHandshakeKey>,
    headers: &[(String, String)],
    body: &[u8],
) -> Response {
    if auth.is_some_and(|auth| !auth.authenticate(headers, body)) {
        return failure(401, "unauthorized", "unauthorized");
    }

    let request = match parse_request(body) {
        Ok(request) => request,
        Err(response) => return response,
    };

    let _permit = match Arc::clone(&RELAY_SLOTS).try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => return failure(429, "rate_limited", "too many concurrent requests"),
    };

    if !ctx.pool.has_usable_device().await {
        return failure(503, "service_unavailable", "service unavailable");
    }

    let Some(handshake_key) = handshake_key else {
        return failure(503, "service_unavailable", "service unavailable");
    };
    let wrapped_key =
        match wrap_client_public_key(&request.client_public_key, handshake_key.as_bytes()).await {
            Ok(key) => key,
            Err(_) => return failure(400, "invalid_client_key", "invalid client public key"),
        };

    let raw = match fetch_full_mget_raw(
        ctx,
        &request.book_id,
        std::slice::from_ref(&request.item_id),
        &wrapped_key,
    )
    .await
    {
        Ok(root) => root,
        Err(_) => return failure(502, "upstream_error", "upstream request failed"),
    };
    relay_response(ctx, raw, &request.item_id)
}

fn relay_response(ctx: &Ctx, raw: Vec<u8>, item_id: &str) -> Response {
    let mut root: Value = match serde_json::from_slice(&raw) {
        Ok(root) => root,
        Err(_) => return invalid_upstream(),
    };
    let Some(object) = root.as_object() else {
        return invalid_upstream();
    };
    let Some(code) = object.get("code") else {
        return invalid_upstream();
    };
    let is_zero =
        code.as_i64() == Some(0) || code.as_u64() == Some(0) || code.as_f64() == Some(0.0);
    if !is_zero {
        if code.is_number() {
            return Response::text(200, "application/json; charset=utf-8", raw);
        }
        return invalid_upstream();
    }

    let Some(item) = object
        .get("data")
        .and_then(Value::as_object)
        .and_then(|data| data.get("item_infos"))
        .and_then(Value::as_object)
        .and_then(|items| items.get(item_id))
        .and_then(Value::as_object)
    else {
        return invalid_upstream();
    };
    if item
        .get("key")
        .and_then(Value::as_str)
        .is_none_or(str::is_empty)
        || item
            .get("content")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
    {
        return invalid_upstream();
    }

    let relay = if ctx.cfg.zwsm.is_empty() {
        json!({ "protocol": 1 })
    } else {
        json!({ "protocol": 1, "content_suffix": ctx.cfg.zwsm.as_str() })
    };
    root.as_object_mut()
        .expect("checked above")
        .insert("relay".to_string(), relay);
    Response::json(200, &root)
}

fn invalid_request(message: &'static str) -> Response {
    failure(400, "invalid_request", message)
}

fn invalid_upstream() -> Response {
    failure(
        502,
        "upstream_invalid_response",
        "invalid upstream response",
    )
}

fn failure(status: u16, error_code: &'static str, message: &'static str) -> Response {
    Response::json(
        status,
        &json!({
            "success": false,
            "error": message,
            "error_code": error_code,
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_matches_rfc_4231_case_one() {
        let key = [0x0b; 20];
        let signature = hmac_sha256(&key, b"Hi There");
        assert_eq!(
            hex::encode(signature),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
    }

    #[test]
    fn relay_auth_requires_both_environment_values() {
        assert!(RelayAuth::from_values(Some("token".to_string()), None).is_err());
        assert!(RelayAuth::from_values(None, Some("a2V5".to_string())).is_err());
        assert!(RelayAuth::from_values(None, None)
            .expect("disabled")
            .is_none());
        assert!(
            RelayAuth::from_values(Some("token".to_string()), Some("a2V5".to_string()))
                .expect("enabled")
                .is_some(),
            "both values must enable authentication"
        );
    }

    #[test]
    fn handshake_key_requires_exactly_sixteen_base64_bytes() {
        let key = base64::engine::general_purpose::STANDARD.encode([7u8; 16]);
        assert!(RelayHandshakeKey::from_base64(&key).is_ok());
        assert!(RelayHandshakeKey::from_base64("").is_err());
        assert!(RelayHandshakeKey::from_base64("AA==").is_err());
        assert!(RelayHandshakeKey::from_base64("not base64").is_err());
    }

    fn signed_headers(
        auth: &RelayAuth,
        body: &[u8],
        timestamp: i64,
        nonce: &str,
    ) -> Vec<(String, String)> {
        let body_hash = hex::encode(Sha256::digest(body));
        let canonical = format!("POST\n{FULL_RELAY_PATH}\n{timestamp}\n{nonce}\n{body_hash}");
        let signature = hex::encode(hmac_sha256(&auth.signing_key, canonical.as_bytes()));
        vec![
            (
                "authorization".to_string(),
                format!("Bearer {}", String::from_utf8_lossy(&auth.install_token)),
            ),
            ("x-fq-timestamp".to_string(), timestamp.to_string()),
            ("x-fq-nonce".to_string(), nonce.to_string()),
            ("x-fq-signature".to_string(), format!("v1={signature}")),
        ]
    }

    #[test]
    fn relay_auth_checks_the_body_and_rejects_a_replayed_nonce() {
        let auth = RelayAuth {
            install_token: b"install-test-token".to_vec(),
            signing_key: b"signing-test-key".to_vec(),
        };
        let body = br#"{"book_id":"book-1","item_ids":["chapter-1"],"client_public_key":"Ag=="}"#;
        let nonce = "0123456789abcdef0123456789abcdef";
        let headers = signed_headers(&auth, body, crate::timeutil::now_secs(), nonce);
        assert!(auth.authenticate(&headers, body));
        assert!(!auth.authenticate(&headers, body), "nonce replay must fail");

        let tampered_nonce = "fedcba9876543210fedcba9876543210";
        let mut tampered_headers =
            signed_headers(&auth, body, crate::timeutil::now_secs(), tampered_nonce);
        tampered_headers.push(("ignored".to_string(), "value".to_string()));
        assert!(
            !auth.authenticate(&tampered_headers, b"different body"),
            "the body hash must be authenticated"
        );
    }
}
