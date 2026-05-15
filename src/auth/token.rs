#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
use keyring::Entry;
use std::sync::{Arc, LazyLock};
use yandex_music::YandexMusicClient;

#[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
static SERVICE_NAME: LazyLock<String> =
    LazyLock::new(|| format!("{}_auth", env!("CARGO_PKG_NAME")));

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub struct TokenProvider;

impl TokenProvider {
    pub fn resolve() -> Option<(String, u64)> {
        #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
        {
            let stored = Self::load_from_keyring().ok()?;
            let mut parts = stored.split(':');
            let token = parts.next()?.to_string();
            let uid = parts.next()?.parse().ok()?;
            Some((token, uid))
        }
        #[cfg(target_os = "android")]
        {
            let db = crate::storage::db::AppDatabase::init(crate::app::get_data_dir()).ok()?;
            db.load_auth_token().ok().flatten()
        }
        #[cfg(not(any(
            target_os = "windows",
            target_os = "macos",
            target_os = "linux",
            target_os = "android"
        )))]
        None
    }

    pub fn store(token: &str, user_id: u64) -> Result<()> {
        #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
        {
            let entry = Entry::new(&SERVICE_NAME, "default")?;
            entry.set_password(&format!("{}:{}", token, user_id))?;
            Ok(())
        }
        #[cfg(target_os = "android")]
        {
            let db = crate::storage::db::AppDatabase::init(crate::app::get_data_dir())?;
            db.save_auth_token(token, user_id)?;
            Ok(())
        }
        #[cfg(not(any(
            target_os = "windows",
            target_os = "macos",
            target_os = "linux",
            target_os = "android"
        )))]
        {
            let _ = (token, user_id);
            Err("Auth storage not supported on this platform".into())
        }
    }

    #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
    fn load_from_keyring() -> Result<String> {
        Ok(Entry::new(&SERVICE_NAME, "default")?.get_password()?)
    }

    pub fn delete() -> Result<()> {
        #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
        {
            Ok(Entry::new(&SERVICE_NAME, "default")?.delete_credential()?)
        }
        #[cfg(target_os = "android")]
        {
            let db = crate::storage::db::AppDatabase::init(crate::app::get_data_dir())?;
            db.delete_auth_token()?;
            Ok(())
        }
        #[cfg(not(any(
            target_os = "windows",
            target_os = "macos",
            target_os = "linux",
            target_os = "android"
        )))]
        Ok(())
    }

    pub async fn validate(token: String) -> Result<(Arc<YandexMusicClient>, u64)> {
        let client = YandexMusicClient::builder(&token).build()?;
        let status = client.get_account_status().await?;

        let user_id = status.account.uid.ok_or("No user id found")?;
        Ok((Arc::new(client), user_id))
    }
}
