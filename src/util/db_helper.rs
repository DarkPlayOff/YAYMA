use crate::db::AppDatabase;
use parking_lot::Mutex;
use std::sync::Arc;

pub trait DbExt {
    fn with_db<F, R>(&self, f: F) -> R
    where
        F: FnOnce(&AppDatabase) -> R;
}

impl DbExt for Arc<Mutex<AppDatabase>> {
    fn with_db<F, R>(&self, f: F) -> R
    where
        F: FnOnce(&AppDatabase) -> R
    {
        tokio::task::block_in_place(|| {
            let db = self.lock();
            f(&db)
        })
    }
}
