pub mod lrc;
pub mod providers;
pub mod ttml;

use crate::api::models::{LyricsLineDto, LyricsWordDto};
use std::sync::LazyLock;
use std::time::Duration;

/// A single parsed lyric line with optional word-level (karaoke) timing, in
/// seconds. The common intermediate representation every provider converges
/// on before crossing the FRB boundary as [`LyricsLineDto`].
#[derive(Debug, Clone, PartialEq)]
pub struct ParsedLine {
    pub start: f64,
    pub text: String,
    pub words: Vec<ParsedWord>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ParsedWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

/// True if any line carries word-level (karaoke) timing.
pub fn has_word_sync(lines: &[ParsedLine]) -> bool {
    lines.iter().any(|l| !l.words.is_empty())
}

/// Sorts by start time and converts to the FRB-exposed DTO shape (millisecond ints).
pub fn to_lines_dto(mut lines: Vec<ParsedLine>) -> Vec<LyricsLineDto> {
    lines.sort_by(|a, b| a.start.total_cmp(&b.start));
    lines
        .into_iter()
        .map(|line| LyricsLineDto {
            start_ms: (line.start * 1000.0).round() as i64,
            text: line.text,
            words: line
                .words
                .into_iter()
                .map(|w| LyricsWordDto {
                    text: w.text,
                    start_ms: (w.start * 1000.0).round() as i64,
                    end_ms: (w.end * 1000.0).round() as i64,
                })
                .collect(),
        })
        .collect()
}

/// Shared HTTP client for every third-party lyrics provider, so the app
/// keeps one connection pool instead of one per source. A browser-like
/// User-Agent is required — some providers (e.g. lrclib.net) sit behind a
/// WAF that 403s reqwest's default UA string.
pub static CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(8))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36")
        .build()
        .unwrap_or_default()
});

/// A track's search-relevant metadata, used to query third-party providers
/// that can't look tracks up by Yandex track id.
#[derive(Debug, Clone)]
pub struct LyricsQuery {
    pub id: String,
    pub title: String,
    pub artist: String,
    /// Duration in whole seconds, or -1 if unknown.
    pub duration: i32,
    pub album: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProviderId {
    Yandex,
    LrcLib,
    BetterLyrics,
    YouLyPlus,
}

impl ProviderId {
    /// All providers, in the priority order they're actually queried in
    /// (word-sync-capable first). Used to list them for the enable/disable
    /// setting — the order itself isn't user-editable.
    pub const ALL: [ProviderId; 4] = [
        ProviderId::BetterLyrics,
        ProviderId::YouLyPlus,
        ProviderId::Yandex,
        ProviderId::LrcLib,
    ];

    pub fn key(&self) -> &'static str {
        match self {
            ProviderId::Yandex => "yandex",
            ProviderId::LrcLib => "lrclib",
            ProviderId::BetterLyrics => "betterlyrics",
            ProviderId::YouLyPlus => "youlyplus",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            ProviderId::Yandex => "Яндекс Музыка",
            ProviderId::LrcLib => "LrcLib",
            ProviderId::BetterLyrics => "BetterLyrics",
            ProviderId::YouLyPlus => "YouLyPlus",
        }
    }

    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.key() == key)
    }

    /// True if the provider can return word-level (karaoke) timing at all.
    /// Line-sync-only providers are never worth racing for word sync.
    /// LrcLib counts too: some of its entries carry Enhanced LRC
    /// (`<mm:ss.xx>`-tagged) synced lyrics with per-word timing.
    pub fn supports_word_sync(&self) -> bool {
        matches!(
            self,
            ProviderId::BetterLyrics | ProviderId::YouLyPlus | ProviderId::LrcLib
        )
    }
}

/// Queries a single third-party provider (everything except [`ProviderId::Yandex`],
/// which needs the authenticated `ApiService` and is handled by the caller).
pub async fn fetch_from_provider(provider: ProviderId, query: &LyricsQuery) -> Option<Vec<ParsedLine>> {
    let album = query.album.as_deref();
    match provider {
        ProviderId::Yandex => None,
        ProviderId::LrcLib => {
            providers::lrclib::get_lyrics(&query.title, &query.artist, query.duration, album).await
        }
        ProviderId::BetterLyrics => {
            providers::betterlyrics::get_lyrics(&query.title, &query.artist, query.duration, album)
                .await
        }
        ProviderId::YouLyPlus => {
            providers::youlyplus::get_lyrics(
                &query.title,
                &query.artist,
                query.duration,
                album,
                Some(&query.id),
            )
            .await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(text: &str, words: Vec<ParsedWord>) -> ParsedLine {
        ParsedLine { start: 0.0, text: text.to_string(), words }
    }

    fn word(text: &str) -> ParsedWord {
        ParsedWord { text: text.to_string(), start: 0.0, end: 1.0 }
    }

    #[test]
    fn detects_word_sync_when_any_line_has_words() {
        let lines = vec![line("hello world", vec![word("hello"), word("world")])];
        assert!(has_word_sync(&lines));
    }

    #[test]
    fn plain_lines_have_no_word_sync() {
        let lines = vec![line("hello world", Vec::new()), line("second line", Vec::new())];
        assert!(!has_word_sync(&lines));
    }

    #[test]
    fn to_lines_dto_sorts_by_start_and_converts_to_milliseconds() {
        let lines = vec![
            ParsedLine { start: 2.0, text: "second".to_string(), words: Vec::new() },
            ParsedLine {
                start: 1.0,
                text: "first".to_string(),
                words: vec![ParsedWord { text: "first".to_string(), start: 1.0, end: 1.5 }],
            },
        ];
        let dto = to_lines_dto(lines);
        assert_eq!(dto[0].text, "first");
        assert_eq!(dto[0].start_ms, 1000);
        assert_eq!(dto[0].words[0].end_ms, 1500);
        assert_eq!(dto[1].text, "second");
        assert_eq!(dto[1].start_ms, 2000);
    }

    #[test]
    fn provider_key_round_trips_through_from_key() {
        for provider in ProviderId::ALL {
            assert_eq!(ProviderId::from_key(provider.key()), Some(provider));
        }
    }

    #[test]
    fn from_key_rejects_unknown_keys() {
        assert_eq!(ProviderId::from_key("not-a-real-provider"), None);
    }

    #[test]
    fn only_yandex_lacks_word_sync_support() {
        for provider in ProviderId::ALL {
            let expected = provider != ProviderId::Yandex;
            assert_eq!(provider.supports_word_sync(), expected, "{provider:?}");
        }
    }
}
