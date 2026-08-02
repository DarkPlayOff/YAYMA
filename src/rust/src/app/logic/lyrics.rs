use crate::api::models::{AppError, LyricsProviderSettingDto, LyricsResultDto};
use crate::api::simple::AppEvent;
use crate::app::AppContext;
use crate::lyrics::{LyricsQuery, ParsedLine, ProviderId, fetch_from_provider, has_word_sync, lrc, to_lines_dto};
use futures::StreamExt;
use futures::stream::FuturesUnordered;
use std::collections::HashMap;
use std::time::Duration;

const ENABLED_KEY: &str = "lyrics_provider_enabled";

/// Hard ceiling on a single provider's lookup, so one slow/hanging source
/// can't stall the whole fallback chain (and the "Текст отсутствует" empty
/// state in the UI) indefinitely.
const PROVIDER_TIMEOUT: Duration = Duration::from_secs(10);

/// Providers that can return word-level (karaoke) timing, derived from
/// `ProviderId::supports_word_sync` so adding a provider only ever needs to
/// update that one place.
fn word_sync_batch() -> Vec<ProviderId> {
    ProviderId::ALL
        .into_iter()
        .filter(ProviderId::supports_word_sync)
        .collect()
}

async fn resolve_enabled(ctx: &AppContext) -> HashMap<String, bool> {
    ctx.core
        .db
        .lock()
        .await
        .load_setting::<HashMap<String, bool>>(ENABLED_KEY)
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

fn is_enabled(enabled: &HashMap<String, bool>, provider: ProviderId) -> bool {
    // Yandex Music is the primary source and can't be turned off — if every
    // alternative source is disabled (or fails), it's the guaranteed
    // fallback for lyrics.
    if provider == ProviderId::Yandex {
        return true;
    }
    enabled.get(provider.key()).copied().unwrap_or(true)
}

fn warn_provider_timeout(ctx: &AppContext, provider: ProviderId) {
    ctx.send_event(AppEvent::Notification(
        "Текст песни".to_string(),
        format!(
            "Источник «{}» не ответил вовремя, пробуем следующий",
            provider.display_name()
        ),
    ));
}

async fn fetch_provider(
    ctx: &AppContext,
    provider: ProviderId,
    track_id: &str,
    query: Option<&LyricsQuery>,
) -> Option<Vec<ParsedLine>> {
    if provider == ProviderId::Yandex {
        let raw = ctx
            .core
            .api
            .fetch_lyrics(
                track_id.to_string(),
                yandex_music::model::info::lyrics::LyricsFormat::LRC,
            )
            .await
            .ok()
            .flatten()?;
        let lines = lrc::parse(&raw);
        return if lines.is_empty() { None } else { Some(lines) };
    }
    fetch_from_provider(provider, query?).await
}

async fn fetch_provider_timed(
    ctx: &AppContext,
    provider: ProviderId,
    track_id: &str,
    query: Option<&LyricsQuery>,
) -> Option<(ProviderId, Vec<ParsedLine>)> {
    match tokio::time::timeout(
        PROVIDER_TIMEOUT,
        fetch_provider(ctx, provider, track_id, query),
    )
    .await
    {
        Ok(lines) => lines.map(|l| (provider, l)),
        Err(_) => {
            warn_provider_timeout(ctx, provider);
            None
        }
    }
}

/// Result of racing a provider batch: `word_sync` is set as soon as a
/// word-synced result lands (the winner); `first_any` is the earliest
/// response regardless of sync quality, kept as a fallback so a caller that
/// rejects the word-sync miss doesn't need to re-query the same providers.
struct BatchResult {
    word_sync: Option<(ProviderId, Vec<ParsedLine>)>,
    first_any: Option<(ProviderId, Vec<ParsedLine>)>,
}

/// Races every provider in `batch` concurrently, returning as soon as the
/// first word-synced result lands (the rest are dropped/cancelled at that
/// point). If the whole batch drains with no word-synced result, the
/// earliest response of any kind is still returned via `first_any`.
async fn race_batch(
    ctx: &AppContext,
    track_id: &str,
    query: Option<&LyricsQuery>,
    batch: &[ProviderId],
) -> BatchResult {
    let mut pending: FuturesUnordered<_> = batch
        .iter()
        .map(|&provider| fetch_provider_timed(ctx, provider, track_id, query))
        .collect();

    let mut first_any: Option<(ProviderId, Vec<ParsedLine>)> = None;

    while let Some(result) = pending.next().await {
        let Some((provider, lines)) = result else { continue };
        if has_word_sync(&lines) {
            // Winner: the rest of `pending` is dropped here, cancelling
            // whatever's still in flight instead of waiting on it.
            return BatchResult {
                word_sync: Some((provider, lines)),
                first_any,
            };
        }
        if first_any.is_none() {
            first_any = Some((provider, lines));
        }
    }

    BatchResult {
        word_sync: None,
        first_any,
    }
}

async fn build_query(ctx: &AppContext, track_id: &str) -> Option<LyricsQuery> {
    let fetch = ctx.core.api.fetch_tracks(vec![track_id.to_string()]);
    let track = tokio::time::timeout(PROVIDER_TIMEOUT, fetch)
        .await
        .ok()?
        .ok()?
        .into_iter()
        .next()?;

    Some(LyricsQuery {
        id: track_id.to_string(),
        title: track.title.clone().unwrap_or_default(),
        artist: track
            .artists
            .iter()
            .filter_map(|a| a.name.clone())
            .collect::<Vec<_>>()
            .join(", "),
        duration: track.duration.map(|d| d.as_secs() as i32).unwrap_or(-1),
        album: track.albums.first().and_then(|a| a.title.clone()),
    })
}

/// Fetches lyrics for a track: races the word-sync-capable providers first
/// (currently LrcLib, BetterLyrics and YouLyPlus — first one to actually
/// return word timing wins, no waiting on the others). If none of them has
/// word sync, tries Yandex directly as the guaranteed primary source; only
/// if Yandex also has nothing does it fall back to whichever line-sync
/// response arrived first from that same trio. Providers the user disabled
/// in settings are skipped entirely.
pub async fn get_lyrics(ctx: &AppContext, track_id: String) -> Option<LyricsResultDto> {
    let query = build_query(ctx, &track_id).await;
    let enabled = resolve_enabled(ctx).await;

    let word_sync: Vec<ProviderId> = word_sync_batch()
        .into_iter()
        .filter(|&p| is_enabled(&enabled, p))
        .collect();

    let batch_result = race_batch(ctx, &track_id, query.as_ref(), &word_sync).await;
    if let Some((provider, lines)) = batch_result.word_sync {
        return Some(to_result(provider, lines));
    }

    if let Some((provider, lines)) =
        fetch_provider_timed(ctx, ProviderId::Yandex, &track_id, query.as_ref()).await
    {
        return Some(to_result(provider, lines));
    }

    batch_result.first_any.map(|(provider, lines)| to_result(provider, lines))
}

fn to_result(provider: ProviderId, lines: Vec<ParsedLine>) -> LyricsResultDto {
    LyricsResultDto {
        lines: to_lines_dto(lines),
        provider_name: provider.display_name().to_string(),
    }
}

pub async fn get_lyrics_provider_settings(ctx: &AppContext) -> Vec<LyricsProviderSettingDto> {
    let enabled = resolve_enabled(ctx).await;

    ProviderId::ALL
        .into_iter()
        // Yandex is always on and not user-toggleable, so it's not listed.
        .filter(|&p| p != ProviderId::Yandex)
        .map(|p| LyricsProviderSettingDto {
            id: p.key().to_string(),
            name: p.display_name().to_string(),
            enabled: is_enabled(&enabled, p),
        })
        .collect()
}

pub async fn set_lyrics_provider_enabled(
    ctx: &AppContext,
    id: String,
    is_enabled_flag: bool,
) -> Result<(), AppError> {
    let Some(provider) = ProviderId::from_key(&id) else {
        return Err(AppError::NotFound(format!("Unknown lyrics provider: {id}")));
    };
    if provider == ProviderId::Yandex && !is_enabled_flag {
        return Err(AppError::Unknown(
            "Источник «Яндекс Музыка» нельзя отключить".to_string(),
        ));
    }
    let mut enabled = resolve_enabled(ctx).await;
    enabled.insert(id, is_enabled_flag);
    ctx.core.db.lock().await.save_setting(ENABLED_KEY, &enabled).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn yandex_is_always_enabled_regardless_of_settings() {
        let mut settings = HashMap::new();
        settings.insert(ProviderId::Yandex.key().to_string(), false);
        assert!(is_enabled(&settings, ProviderId::Yandex));
    }

    #[test]
    fn other_providers_default_enabled_when_unset() {
        let settings = HashMap::new();
        assert!(is_enabled(&settings, ProviderId::LrcLib));
    }

    #[test]
    fn other_providers_respect_explicit_disable() {
        let mut settings = HashMap::new();
        settings.insert(ProviderId::LrcLib.key().to_string(), false);
        assert!(!is_enabled(&settings, ProviderId::LrcLib));
    }

    #[test]
    fn word_sync_batch_only_contains_word_sync_capable_providers() {
        for provider in word_sync_batch() {
            assert!(provider.supports_word_sync());
        }
    }

    #[test]
    fn word_sync_batch_plus_yandex_cover_every_provider_exactly_once() {
        let mut seen: Vec<ProviderId> = word_sync_batch();
        seen.push(ProviderId::Yandex);

        let seen_set: HashSet<ProviderId> = seen.iter().copied().collect();
        assert_eq!(seen.len(), seen_set.len(), "no provider should appear twice");
        assert_eq!(seen_set, ProviderId::ALL.into_iter().collect());
    }
}
