use crate::audio::cache::UrlCache;
use crate::http::ApiService;
use foldhash::HashSet;
use foldhash::HashSetExt;
use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;
use tokio::{sync::mpsc, task::JoinHandle};
use tracing::{error, warn};

const URL_PREFETCH_BATCH_SIZE: usize = 3;

#[derive(Debug, Clone)]
enum PrefetchMessage {
    UpdateInterest {
        needed_ids: Vec<String>,
        current_id: Option<String>,
    },
    Reset,
}

#[derive(Clone)]
pub struct UrlPrefetcher {
    tx: mpsc::UnboundedSender<PrefetchMessage>,
}

impl UrlPrefetcher {
    pub fn new(api: Arc<ApiService>, url_cache: UrlCache) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel::<PrefetchMessage>();

        tokio::spawn(async move {
            let mut current_task: Option<JoinHandle<()>> = None;
            let mut current_task_ids: HashSet<String> = HashSet::new();
            let mut pending_ids: VecDeque<String> = VecDeque::new();

            loop {
                if current_task.is_none() && !pending_ids.is_empty() {
                    let mut batch = Vec::new();
                    while batch.len() < URL_PREFETCH_BATCH_SIZE {
                        if let Some(id) = pending_ids.pop_front() {
                            if url_cache.get(&id).is_none() {
                                batch.push(id);
                            }
                        } else {
                            break;
                        }
                    }

                    if !batch.is_empty() {
                        let api = api.clone();
                        let cache = url_cache.clone();

                        current_task_ids = batch.iter().cloned().collect();

                        current_task = Some(tokio::spawn(async move {
                            let result = tokio::time::timeout(
                                Duration::from_secs(10),
                                api.fetch_track_urls_batch(batch),
                            )
                            .await;

                            match result {
                                Ok(Ok(urls)) => {
                                    for (id, url, codec) in urls {
                                        cache.insert(id, url, codec);
                                    }
                                }
                                Ok(Err(e)) => {
                                    error!(error = %e, "url_fetch_failed");
                                }
                                Err(_) => {
                                    warn!("url_fetch_timeout");
                                }
                            }
                        }));
                    }
                }

                tokio::select! {
                    msg = rx.recv() => {
                        match msg {
                            Some(PrefetchMessage::UpdateInterest { needed_ids, current_id }) => {
                                let should_abort = if current_task.is_some() {
                                    if let Some(focus) = &current_id {
                                        !current_task_ids.contains(focus)
                                    } else {
                                        true
                                    }
                                } else {
                                    false
                                };

                                if should_abort {
                                    if let Some(task) = current_task.take() {
                                        task.abort();
                                    }
                                    current_task_ids.clear();
                                }
                                pending_ids.clear();
                                for id in needed_ids {
                                    if url_cache.get(&id).is_none() && !current_task_ids.contains(&id) {
                                        pending_ids.push_back(id);
                                    }
                                }
                            }
                            Some(PrefetchMessage::Reset) => {
                                if let Some(task) = current_task.take() {
                                    task.abort();
                                }
                                current_task_ids.clear();
                                pending_ids.clear();
                            }
                            None => break,
                        }
                    }
                    _ = async {
                        if let Some(task) = &mut current_task {
                             let _ = task.await;
                        } else {
                             std::future::pending::<()>().await;
                        }
                    } => {
                        current_task = None;
                        current_task_ids.clear();
                    }
                }
            }
        });

        Self { tx }
    }

    pub fn update(&self, needed: Vec<String>, current: Option<String>) {
        let _ = self.tx.send(PrefetchMessage::UpdateInterest {
            needed_ids: needed,
            current_id: current,
        });
    }

    pub fn reset(&self) {
        let _ = self.tx.send(PrefetchMessage::Reset);
    }
}
