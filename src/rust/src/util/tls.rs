//! Scoped TLS trust for Yandex hosts under RU whitelist restrictions.
//!
//! The official Yandex Music APK ships extra trust anchors in `res/` and can
//! enable them remotely (`enableYandexInternalAndNucCertificatesByRemoteConfig`).
//! Of those, only the national root matters for public endpoints, so only it
//! is bundled (`assets/certs/russian-trusted-root-ca.pem`, byte-identical to
//! the APK's `res/aIf.crt`):
//!
//! - `CN=Russian Trusted Root CA` (Ministry of Digital Development,
//!   SHA256 `D2:6D:…:CF:31`, valid through 2032-02-27).
//!   Cross-check with https://www.gosuslugi.ru/crt.
//!
//! Deliberately NOT bundled: the APK's `YandexInternalRootCA` (internal
//! corporate CA, never chains public music endpoints) and `TCI ECDSA ROOT A1`
//! (no whitelist scenario terminates there) — extra roots are extra trust
//! surface with zero benefit.
//!
//! This root is attached to clients that routinely talk to Yandex hosts
//! (API, streaming CDN, cover art via `HttpCache`). Third-party clients
//! (lyrics providers, GitHub update checks) keep the default verifier, so
//! a state-controlled CA is not in a position to MITM non-Yandex traffic
//! under current callers. Note: `HttpCache::get_file` takes arbitrary URLs —
//! today only Yandex cover hosts flow through it by convention, not by
//! enforcement — so avoid passing non-Yandex URLs through these clients.

use yandex_music::{DEFAULT_CLIENT_ID, YandexMusicClient};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

const RUSSIAN_TRUSTED_ROOT_CA: &[u8] =
    include_bytes!("../../../assets/certs/russian-trusted-root-ca.pem");
/// Mozilla bundle for the Android fallback below (PEM, 118 roots, fetched
/// 2026-10-27 from https://curl.se/ca/cacert.pem — refresh periodically).
/// `reqwest` cannot merge extra roots into the Android platform verifier,
/// so there we pin the whole trust store instead of merging.
#[cfg(target_os = "android")]
const MOZILLA_BUNDLE: &[u8] = include_bytes!("../../../assets/certs/mozilla-cacert.pem");

/// Base builder for every client talking to Yandex hosts, with the bundled
/// whitelist roots attached. Desktop merges them into the platform verifier
/// (system + Mozilla roots keep working); Android falls back to a pinned
/// Mozilla + extras bundle.
pub fn builder() -> reqwest::ClientBuilder {
    let extra = extra_roots();
    if extra.is_empty() {
        return reqwest::Client::builder();
    }
    #[cfg(target_os = "android")]
    {
        android_pinned_bundle(reqwest::Client::builder(), extra)
    }
    #[cfg(not(target_os = "android"))]
    {
        reqwest::Client::builder().tls_certs_merge(extra)
    }
}

/// Ready `YandexMusicClient` on the same scoped trust. `custom_client`
/// overrides the defaults `ClientBuilder` sets, so headers are replicated here.
pub fn yandex_music_client(token: String) -> Result<YandexMusicClient> {
    let mut headers = reqwest::header::HeaderMap::with_capacity(2);
    headers.insert(
        reqwest::header::AUTHORIZATION,
        reqwest::header::HeaderValue::from_str(&format!("OAuth {token}"))?,
    );
    headers.insert(
        "X-Yandex-Music-Client",
        reqwest::header::HeaderValue::from_str(DEFAULT_CLIENT_ID)?,
    );
    let http_client = builder().default_headers(headers).build()?;
    Ok(YandexMusicClient::builder(token)
        .custom_client(http_client)
        .build()?)
}

/// Parse the bundled whitelist root. Failure is logged and skipped so a
/// stale/corrupt PEM can never break client construction outright.
fn extra_roots() -> Vec<reqwest::Certificate> {
    match reqwest::Certificate::from_pem(RUSSIAN_TRUSTED_ROOT_CA) {
        Ok(cert) => vec![cert],
        Err(error) => {
            tracing::warn!(%error, "skipping bundled TLS root");
            Vec::new()
        }
    }
}

/// Android-only: platform-verifier extra-root merge is unsupported by
/// `reqwest`, so build a `tls_certs_only` bundle (Mozilla + extras) instead.
#[cfg(target_os = "android")]
fn android_pinned_bundle(
    builder: reqwest::ClientBuilder,
    extra: Vec<reqwest::Certificate>,
) -> reqwest::ClientBuilder {
    let mut all = match reqwest::Certificate::from_pem_bundle(MOZILLA_BUNDLE) {
        Ok(bundle) => bundle,
        Err(error) => {
            tracing::warn!(%error, "mozilla bundle unreadable, extras only");
            Vec::new()
        }
    };
    all.extend(extra);
    if all.is_empty() {
        builder
    } else {
        builder.tls_certs_only(all)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_root_parses() {
        assert_eq!(extra_roots().len(), 1);
    }

    #[test]
    fn yandex_clients_build() {
        assert!(builder().build().is_ok());
        assert!(yandex_music_client("test-token".to_string()).is_ok());
    }
}
