use souvlaki::{MediaControlEvent, MediaControls, MediaMetadata, MediaPlayback, PlatformConfig};

#[cfg(target_os = "windows")]
use windows::{Win32::UI::Shell::SetCurrentProcessExplicitAppUserModelID, core::w};

use crate::audio::commands::AudioMessage;
use crate::audio::events::Event;
use flume::Sender;
use tokio::sync::mpsc;
use yandex_music::model::track::Track;

#[cfg(target_os = "windows")]
use crate::audio::thumbnail::ThumbnailManager;

pub struct SmtcManager {
    controls: MediaControls,
    _cmd_tx: mpsc::UnboundedSender<AudioMessage>,
    #[cfg(target_os = "windows")]
    thumbnail_manager: Option<ThumbnailManager>,
}

impl SmtcManager {
    pub fn new(
        _event_tx: Sender<Event>,
        cmd_tx: mpsc::UnboundedSender<AudioMessage>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        #[cfg(target_os = "windows")]
        unsafe {
            let _ = SetCurrentProcessExplicitAppUserModelID(w!("com.vyfor.yamusic"));
        }

        #[cfg(target_os = "windows")]
        let hwnd =
            crate::audio::thumbnail::get_flutter_hwnd().map(|h| h.0);
        #[cfg(not(target_os = "windows"))]
        let hwnd = None;

        let config = PlatformConfig {
            dbus_name: "yamusic",
            display_name: "YaMusic",
            hwnd,
        };

        let mut controls = MediaControls::new(config).map_err(|e| {
            Box::<dyn std::error::Error + Send + Sync>::from(format!(
                "SMTC init error: {:?}. HWND found: {:?}",
                e, hwnd
            ))
        })?;

        let cmd_tx_clone = cmd_tx.clone();
        controls
            .attach(move |event| match event {
                MediaControlEvent::Play => {
                    let _ = cmd_tx_clone.send(AudioMessage::Resume);
                }
                MediaControlEvent::Pause => {
                    let _ = cmd_tx_clone.send(AudioMessage::Pause);
                }
                MediaControlEvent::Next => {
                    let _ = cmd_tx_clone.send(AudioMessage::Next);
                }
                MediaControlEvent::Previous => {
                    let _ = cmd_tx_clone.send(AudioMessage::Prev);
                }
                MediaControlEvent::Stop => {
                    let _ = cmd_tx_clone.send(AudioMessage::Stop);
                }
                MediaControlEvent::SetPosition(pos) => {
                    let _ = cmd_tx_clone.send(AudioMessage::Seek(pos.0));
                }
                _ => {}
            })
            .map_err(|e| {
                Box::<dyn std::error::Error + Send + Sync>::from(format!(
                    "SMTC attach error: {:?}",
                    e
                ))
            })?;

        #[cfg(target_os = "windows")]
        let thumbnail_manager = {
            let thumbnail_hwnd =
                crate::audio::thumbnail::get_flutter_hwnd().map(|h| h.0);
            thumbnail_hwnd.and_then(ThumbnailManager::new)
        };

        Ok(Self {
            controls,
            _cmd_tx: cmd_tx,
            #[cfg(target_os = "windows")]
            thumbnail_manager,
        })
    }

    pub fn update_metadata(&mut self, track: &Track) {
        let title = track.title.as_deref().unwrap_or("Unknown Title");

        let artists = track
            .artists
            .iter()
            .filter_map(|a| a.name.as_deref())
            .collect::<Vec<_>>()
            .join(", ");

        let album = track.albums.first().and_then(|a| a.title.as_deref());

        let cover_url = track
            .cover_uri
            .as_ref()
            .map(|uri| format!("https://{}", uri.replace("%%", "400x400")));

        #[cfg(target_os = "windows")]
        if let (Some(url), Some(thumb_mgr)) = (&cover_url, self.thumbnail_manager) {
            let url_clone = url.clone();
            tokio::spawn(async move {
                let cache = crate::storage::cache::get_http_cache().await;
                if let Ok(path) = cache.get_file(&url_clone).await
                    && let Ok(bytes) = tokio::fs::read(path).await
                {
                    thumb_mgr.update_cover(bytes);
                }
            });
        }

        let metadata = MediaMetadata {
            title: Some(title),
            artist: Some(&artists),
            album,
            cover_url: cover_url.as_deref(),
            duration: track.duration,
        };

        if let Err(e) = self.controls.set_metadata(metadata) {
            tracing::error!("Failed to update SMTC metadata: {:?}", e);
        }
    }

    pub fn update_playback_status(&mut self, is_playing: bool) {
        let status = if is_playing {
            MediaPlayback::Playing { progress: None }
        } else {
            MediaPlayback::Paused { progress: None }
        };

        if let Err(e) = self.controls.set_playback(status) {
            tracing::error!("Failed to update SMTC playback status: {:?}", e);
        }
    }
}
