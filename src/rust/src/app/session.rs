use crate::app::AppContext;
use std::sync::Arc;
use tokio::sync::watch;

pub struct AppSession {
    pub context: Arc<AppContext>,
    /// Signal to stop all background tasks of this session
    pub shutdown_tx: watch::Sender<bool>,
}

impl AppSession {
    pub fn new(context: AppContext) -> (Arc<Self>, watch::Receiver<bool>) {
        let (tx, rx) = watch::channel(false);
        let session = Arc::new(Self {
            context: Arc::new(context),
            shutdown_tx: tx,
        });
        (session, rx)
    }

    pub fn stop(&self) {
        let _ = self.shutdown_tx.send(true);
    }
}
