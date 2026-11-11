use reqwest::header::{COOKIE, ORIGIN, SET_COOKIE};
use reqwest::{Client, Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;
use tokio::sync::Mutex;

const COOKIE_NAME: &str = "_feud_device";
const PROTOCOL_HEADER: &str = "x-feud-protocol";
const PROTOCOL: &str = "1";
const MAX_REPLY: usize = 8 * 1024 * 1024;
const MAX_REQUEST: usize = 65_536;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    path: String,
    method: String,
    body: Option<Value>,
}

#[derive(Serialize)]
pub struct Response {
    status: u16,
    body: String,
}

#[derive(Default)]
struct Session {
    attempted: bool,
    loaded: bool,
    token: Option<String>,
}

pub struct HallClient {
    origin: Url,
    origin_header: String,
    http: Client,
    session: Mutex<Session>,
}

impl HallClient {
    pub fn new(origin: &str) -> Result<Self, &'static str> {
        let origin = server_origin(origin)?;
        let origin_header = origin.origin().ascii_serialization();
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(8))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "native_connection_unavailable")?;
        Ok(Self {
            origin,
            origin_header,
            http,
            session: Mutex::default(),
        })
    }

    pub async fn send(&self, request: Request) -> Result<Response, &'static str> {
        let (method, url) = request.target(&self.origin)?;
        let can_set_cookie = method == Method::POST;
        let mut session = self.session.lock().await;
        if !session.loaded && (can_set_cookie || !session.attempted) {
            let origin = self.origin_header.clone();
            session.attempted = true;
            let credential = tauri::async_runtime::spawn_blocking(move || load_credential(&origin))
                .await
                .map_err(|_| "native_storage_unavailable")?;
            match credential {
                Ok(token) => {
                    session.loaded = true;
                    session.token = token;
                }
                Err(error) if can_set_cookie => return Err(error),
                Err(_) => {}
            }
        }

        let mut outgoing = self
            .http
            .request(method, url)
            .header(PROTOCOL_HEADER, PROTOCOL)
            .header("accept", "application/json");
        if let Some(token) = &session.token {
            outgoing = outgoing.header(COOKIE, format!("{COOKIE_NAME}={token}"));
        }
        if let Some(body) = request.body {
            let json = serde_json::to_vec(&body).map_err(|_| "invalid_native_request")?;
            if json.len() > MAX_REQUEST {
                return Err("invalid_native_request");
            }
            outgoing = outgoing
                .header(ORIGIN, &self.origin_header)
                .header("x-feud-command", "1")
                .header("content-type", "application/json")
                .body(json);
        }

        let mut reply = outgoing
            .send()
            .await
            .map_err(|_| "native_connection_unavailable")?;
        let status = reply.status();
        if status.is_redirection() {
            return Err("native_connection_unavailable");
        }
        if status.as_u16() == 426
            || (!status.is_server_error()
                && reply
                    .headers()
                    .get(PROTOCOL_HEADER)
                    .and_then(|header| header.to_str().ok())
                    != Some(PROTOCOL))
        {
            return Err("client_update_required");
        }

        if can_set_cookie && status.is_success() {
            if let Some(cookie) = reply
                .headers()
                .get_all(SET_COOKIE)
                .iter()
                .filter_map(|header| header.to_str().ok())
                .find_map(device_cookie)
            {
                let origin = self.origin_header.clone();
                let stored = cookie.clone();
                let saved =
                    tauri::async_runtime::spawn_blocking(move || save_credential(&origin, stored))
                        .await
                        .map_err(|_| "native_storage_unavailable")
                        .and_then(|result| result);
                if cookie.is_some() {
                    saved?;
                }
                // A durable server revocation remains conclusive if the local
                // store cannot delete the now-useless token.
                session.token = cookie;
            }
        }
        drop(session);

        let mut body = Vec::new();
        while let Some(chunk) = reply
            .chunk()
            .await
            .map_err(|_| "native_connection_unavailable")?
        {
            if body.len() + chunk.len() > MAX_REPLY {
                return Err("native_connection_unavailable");
            }
            body.extend_from_slice(&chunk);
        }
        Ok(Response {
            status: status.as_u16(),
            body: String::from_utf8(body).map_err(|_| "native_connection_unavailable")?,
        })
    }
}

impl Request {
    fn target(&self, origin: &Url) -> Result<(Method, Url), &'static str> {
        let (path, query) = self.path.split_once('?').unwrap_or((&self.path, ""));
        let method = match (self.method.as_str(), path, self.body.is_some()) {
            (
                "GET",
                "/api/state" | "/api/quote" | "/api/dining-options" | "/api/dining-history",
                false,
            ) => Method::GET,
            ("POST", "/api/device" | "/api/commands", true) if query.is_empty() => Method::POST,
            _ => return Err("invalid_native_request"),
        };
        if self.path.len() > 4096 || query.contains('#') {
            return Err("invalid_native_request");
        }
        let mut url = origin.clone();
        url.set_path(path);
        if !query.is_empty() {
            url.set_query(Some(query));
        }
        Ok((method, url))
    }
}

fn server_origin(raw: &str) -> Result<Url, &'static str> {
    let url = Url::parse(raw).map_err(|_| "invalid_server_origin")?;
    let trusted_transport = match (url.scheme(), url.host_str()) {
        ("https", Some(_)) | ("http", Some("localhost" | "127.0.0.1")) => true,
        _ => false,
    };
    if !trusted_transport
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("invalid_server_origin");
    }
    Ok(url)
}

fn device_cookie(header: &str) -> Option<Option<String>> {
    let (name, value) = header.split(';').next()?.split_once('=')?;
    if name != COOKIE_NAME {
        return None;
    }
    if value.is_empty() {
        Some(None)
    } else if valid_token(value) {
        Some(Some(value.to_owned()))
    } else {
        None
    }
}

fn valid_token(token: &str) -> bool {
    !token.is_empty()
        && token.len() <= 4096
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}

fn load_credential(origin: &str) -> Result<Option<String>, &'static str> {
    let result = keyring::Entry::new("io.github.adsouza.FeudHall", origin)
        .and_then(|entry| entry.get_password());
    match result {
        Ok(token) => Ok(valid_token(&token).then_some(token)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err("native_storage_unavailable"),
    }
}

fn save_credential(origin: &str, token: Option<String>) -> Result<(), &'static str> {
    let result = keyring::Entry::new("io.github.adsouza.FeudHall", origin).and_then(|entry| {
        if let Some(token) = token {
            entry.set_password(&token)
        } else {
            match entry.delete_credential() {
                Err(keyring::Error::NoEntry) => Ok(()),
                result => result,
            }
        }
    });
    result.map_err(|_| "native_storage_unavailable")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_origin_is_fixed_and_credentials_require_a_secure_transport() {
        for valid in [
            "https://game.example",
            "http://localhost:4000",
            "http://127.0.0.1:8000",
        ] {
            assert!(server_origin(valid).is_ok());
        }
        for invalid in [
            "http://game.example",
            "http://localhost.evil.example",
            "https://user@game.example",
            "https://game.example/redirect",
            "https://game.example?host=elsewhere",
            "file:///tmp/app",
        ] {
            assert!(server_origin(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn paths_and_methods_cannot_escape_the_native_api() {
        let origin = server_origin("https://game.example").unwrap();
        let request = |method: &str, path: &str, body: Option<Value>| Request {
            path: path.into(),
            method: method.into(),
            body,
        };
        assert_eq!(
            request("GET", "/api/quote?main=one%26two", None)
                .target(&origin)
                .unwrap()
                .1
                .as_str(),
            "https://game.example/api/quote?main=one%26two"
        );
        for path in [
            "//elsewhere/api/state",
            "/api/../operator/seed",
            "/api/state#spoof",
            "/api/operator/seed",
            "https://game.example/api/state",
            "/api/%73tate",
        ] {
            assert!(
                request("GET", path, None).target(&origin).is_err(),
                "{path}"
            );
            assert!(
                request("POST", path, Some(Value::Null))
                    .target(&origin)
                    .is_err(),
                "{path}"
            );
        }
        assert!(request("POST", "/api/commands", Some(Value::Null))
            .target(&origin)
            .is_ok());
        assert!(
            request("POST", "/api/commands?other=true", Some(Value::Null))
                .target(&origin)
                .is_err()
        );
    }

    #[test]
    fn only_the_hall_device_cookie_can_update_the_credential() {
        assert_eq!(device_cookie("other=secret"), None);
        assert_eq!(
            device_cookie("_feud_device=a-b.c_1; HttpOnly"),
            Some(Some("a-b.c_1".into()))
        );
        assert_eq!(device_cookie("_feud_device=; Max-Age=0"), Some(None));
        assert_eq!(device_cookie("_feud_device=bad token"), None);
    }
}
