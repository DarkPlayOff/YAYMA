use discord_rich_presence::{DiscordIpc, DiscordIpcClient, activity};
use std::time::{SystemTime, UNIX_EPOCH, Instant, Duration};
use crate::audio::signals::AudioSignals;

const CLIENT_ID: &str = "1269826362399522849";
const RECONNECT_INTERVAL: Duration = Duration::from_secs(15);

pub struct DiscordManager;

impl DiscordManager {
    pub fn spawn(signals: AudioSignals) {
        tokio::task::spawn_blocking(move || {
            let mut client: Option<DiscordIpcClient> = None;
            let mut last_track_id: Option<String> = None;
            let mut last_playing = false;
            let mut last_rpc_enabled = false;
            let mut last_connect_attempt = Instant::now() - RECONNECT_INTERVAL;

            loop {
                std::thread::sleep(Duration::from_millis(1000));

                let rpc_enabled = signals.discord_rpc.get();

                // Если выключили - рубим сразу
                if !rpc_enabled {
                    if let Some(mut c) = client.take() {
                        let _ = c.clear_activity();
                        let _ = c.close();
                    }
                    last_track_id = None;
                    last_playing = false;
                    last_rpc_enabled = false;
                    continue;
                }

                // Если только что включили - сбрасываем таймер попытки для мгновенного коннекта
                if rpc_enabled && !last_rpc_enabled {
                    last_connect_attempt = Instant::now() - RECONNECT_INTERVAL;
                }
                last_rpc_enabled = rpc_enabled;

                let track_id = signals.current_track_id.get();
                let is_playing = signals.is_playing.get();
                
                let track_changed = track_id != last_track_id;
                let playing_changed = is_playing != last_playing;

                if track_changed || playing_changed {
                    if let Some(id) = track_id.as_ref() {
                        // Пытаемся подключиться, если клиента нет и прошло достаточно времени
                        if client.is_none() && Instant::now().duration_since(last_connect_attempt) >= RECONNECT_INTERVAL {
                            last_connect_attempt = Instant::now();
                            let mut c = DiscordIpcClient::new(CLIENT_ID);
                            if c.connect().is_ok() {
                                client = Some(c);
                            }
                        }

                        if let Some(c) = client.as_mut() {
                            last_track_id = Some(id.clone());
                            last_playing = is_playing;

                            let title = signals.title.get().unwrap_or_else(|| "Unknown".into());
                            let artists = signals.artists.get().unwrap_or_else(|| "Unknown".into());
                            let duration_ms = signals.duration_ms.get();
                            let position_ms = signals.position_ms.get();

                            let cover_url = signals.current_track.get().and_then(|t| {
                                t.cover_uri.map(|uri| format!("https://{}", uri.replace("%%", "400x400")))
                            }).unwrap_or_else(|| "https://avatars.yandex.net/get-music-content/default/m/400x400".into());

                            if let Err(e) = update_presence(c, id, &title, &artists, &cover_url, is_playing, position_ms, duration_ms) {
                                tracing::error!("Discord RPC error: {:?}", e);
                                let _ = c.close();
                                client = None; 
                            }
                        }
                    } else {
                        if let Some(c) = client.as_mut() {
                            let _ = c.clear_activity();
                        }
                        last_track_id = None;
                        last_playing = false;
                    }
                }
            }
        });
    }
}

fn update_presence(
    client: &mut DiscordIpcClient,
    track_id: &str,
    title: &str,
    artists: &str,
    cover_url: &str,
    is_playing: bool,
    position_ms: u64,
    duration_ms: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut assets = activity::Assets::new()
        .large_image(cover_url)
        .large_text("Yandex Music");

    if !is_playing {
        assets = assets.small_image("pause").small_text("Paused");
    }

    let track_url = format!("https://music.yandex.ru/track/{}", track_id);
    let buttons = vec![activity::Button::new("Listen on Yandex Music", &track_url)];

    let mut payload = activity::Activity::new()
        .state(artists)
        .details(title)
        .assets(assets)
        .buttons(buttons)
        .activity_type(activity::ActivityType::Listening);

    if is_playing {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let start_time = now.saturating_sub(position_ms / 1000);
        let mut timestamps = activity::Timestamps::new().start(start_time as i64);

        if duration_ms > 0 {
            let end_time = start_time + (duration_ms / 1000);
            timestamps = timestamps.end(end_time as i64);
        }
        payload = payload.timestamps(timestamps);
    }

    client
        .set_activity(payload)
        .map_err(|e| format!("{:?}", e).into())
}
