use keyring::Entry;
use std::sync::{Arc, LazyLock};
use yandex_music::YandexMusicClient;

static SERVICE_NAME: LazyLock<String> =
    LazyLock::new(|| format!("{}_auth", env!("CARGO_PKG_NAME")));

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub struct TokenProvider;

impl TokenProvider {
    pub fn resolve() -> Option<(String, u64)> {
        let stored = Self::load_from_keyring().ok()?;
        let mut parts = stored.split(':');
        let token = parts.next()?.to_string();
        let uid = parts.next()?.parse().ok()?;
        Some((token, uid))
    }

    pub fn store(token: &str, user_id: u64) -> Result<()> {
        let entry = Entry::new(&SERVICE_NAME, "default")?;
        entry.set_password(&format!("{}:{}", token, user_id))?;
        Ok(())
    }

    fn load_from_keyring() -> Result<String> {
        Ok(Entry::new(&SERVICE_NAME, "default")?.get_password()?)
    }

    pub fn delete() -> Result<()> {
        Ok(Entry::new(&SERVICE_NAME, "default")?.delete_credential()?)
    }

    pub async fn validate(token: String) -> Result<(Arc<YandexMusicClient>, u64)> {
        let client = YandexMusicClient::builder(&token).build()?;
        let status = client.get_account_status().await?;

        if !status.plus.has_plus {
            return Err("No Yandex Plus subscription found".into());
        }

        let user_id = status.account.uid.ok_or("No user id found")?;
        Ok((Arc::new(client), user_id))
    }
}
