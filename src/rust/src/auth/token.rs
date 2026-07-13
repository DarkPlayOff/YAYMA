use yandex_music::YandexMusicClient;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub struct TokenProvider;

impl TokenProvider {
    pub async fn resolve() -> Option<(String, u64)> {
        let mut db = crate::storage::db::AppDatabase::init(crate::app::get_data_dir())
            .await
            .ok()?;
        db.load_auth_token().await.ok().flatten()
    }

    pub async fn store(token: &str, user_id: u64) -> Result<()> {
        let mut db = crate::storage::db::AppDatabase::init(crate::app::get_data_dir()).await?;
        db.save_auth_token(token, user_id).await?;
        Ok(())
    }

    pub async fn delete() -> Result<()> {
        let mut db = crate::storage::db::AppDatabase::init(crate::app::get_data_dir()).await?;
        db.delete_auth_token().await?;
        Ok(())
    }

    pub async fn validate(token: String) -> Result<u64> {
        let client = YandexMusicClient::builder(&token).build()?;
        let status = client.get_account_status().await?;

        status.account.uid.ok_or("No user id found".into())
    }
}
