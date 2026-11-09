use serde::Deserialize;

use crate::lyrics::{CLIENT, ParsedLine, ParsedWord};

const BASE_URL: &str = "https://api.lrcmux.dev";

/// lrcmux asks every client to name itself (https://lrcmux.dev/llms.txt),
/// unlike the other providers.
const USER_AGENT: &str = "YAYMA";

#[derive(Debug, Deserialize)]
struct LyricsResponse {
    #[serde(default)]
    meta: Meta,
    /// Nullable in the schema, e.g. for instrumentals.
    #[serde(default)]
    lines: Option<Vec<ApiLine>>,
}

#[derive(Debug, Default, Deserialize)]
struct Meta {
    #[serde(default)]
    instrumental: bool,
}

#[derive(Debug, Deserialize)]
struct ApiLine {
    /// Empty for a break between stanzas.
    #[serde(default)]
    text: String,
    #[serde(default)]
    start: Option<i64>,
    #[serde(default)]
    words: Option<Vec<ApiWord>>,
}

#[derive(Debug, Deserialize)]
struct ApiWord {
    #[serde(default)]
    text: String,
    #[serde(default)]
    start: Option<i64>,
    #[serde(default)]
    end: Option<i64>,
}

/// Converts lrcmux's JSON (milliseconds) into the shared `ParsedLine`
/// representation. Untimed and blank lines are dropped — the UI can only
/// place timed lines on the timeline, and stanza breaks carry no text.
fn convert(response: LyricsResponse) -> Option<Vec<ParsedLine>> {
    if response.meta.instrumental {
        return None;
    }

    let mut lines = Vec::new();
    for line in response.lines.unwrap_or_default() {
        let Some(line_start) = line.start else {
            continue;
        };

        let mut words = Vec::new();
        for word in line.words.unwrap_or_default() {
            let text = word.text.trim();
            let Some(start) = word.start else {
                continue;
            };
            if text.is_empty() {
                continue;
            }
            let end = word.end.filter(|&end| end >= start).unwrap_or(start);
            words.push(ParsedWord {
                text: text.to_string(),
                start: start as f64 / 1000.0,
                end: end as f64 / 1000.0,
            });
        }

        let text = if line.text.trim().is_empty() {
            words
                .iter()
                .map(|w| w.text.as_str())
                .collect::<Vec<_>>()
                .join(" ")
        } else {
            line.text.trim().to_string()
        };
        if text.is_empty() {
            continue;
        }

        lines.push(ParsedLine {
            start: line_start as f64 / 1000.0,
            text,
            words,
        });
    }

    if lines.is_empty() { None } else { Some(lines) }
}

pub async fn get_lyrics(
    title: &str,
    artist: &str,
    duration: i32,
    album: Option<&str>,
) -> Option<Vec<ParsedLine>> {
    let mut req = CLIENT
        .get(format!("{BASE_URL}/get"))
        .header("User-Agent", USER_AGENT)
        .query(&[("artist", artist), ("title", title)]);
    if duration > 0 {
        req = req.query(&[("duration", duration.to_string())]);
    }
    if let Some(album) = album
        && !album.trim().is_empty()
    {
        req = req.query(&[("album", album)]);
    }

    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let parsed: LyricsResponse = resp.json().await.ok()?;
    convert(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str, start: i64, end: i64) -> ApiWord {
        ApiWord {
            text: text.to_string(),
            start: Some(start),
            end: Some(end),
        }
    }

    #[test]
    fn convert_uses_line_text_and_word_timings() {
        let response = LyricsResponse {
            meta: Meta::default(),
            lines: Some(vec![ApiLine {
                text: "hello world".to_string(),
                start: Some(1000),
                words: Some(vec![word("hello ", 1000, 1400), word("world", 1500, 2000)]),
            }]),
        };
        let lines = convert(response).unwrap();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].start, 1.0);
        assert_eq!(lines[0].text, "hello world");
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].text, "hello");
        assert_eq!(lines[0].words[0].end, 1.4);
    }

    #[test]
    fn convert_builds_text_from_words_when_line_text_is_empty() {
        let response = LyricsResponse {
            meta: Meta::default(),
            lines: Some(vec![ApiLine {
                text: String::new(),
                start: Some(0),
                words: Some(vec![word("hello", 0, 500), word("world", 500, 1000)]),
            }]),
        };
        let lines = convert(response).unwrap();
        assert_eq!(lines[0].text, "hello world");
    }

    #[test]
    fn convert_keeps_line_sync_where_words_are_null() {
        let response = LyricsResponse {
            meta: Meta::default(),
            lines: Some(vec![ApiLine {
                text: "unsynced words".to_string(),
                start: Some(2000),
                words: None,
            }]),
        };
        let lines = convert(response).unwrap();
        assert_eq!(lines[0].text, "unsynced words");
        assert!(lines[0].words.is_empty());
    }

    #[test]
    fn convert_drops_untimed_and_blank_lines() {
        let response = LyricsResponse {
            meta: Meta::default(),
            lines: Some(vec![
                ApiLine {
                    text: "no timestamp".to_string(),
                    start: None,
                    words: None,
                },
                ApiLine {
                    // Stanza break.
                    text: String::new(),
                    start: Some(0),
                    words: None,
                },
            ]),
        };
        assert_eq!(convert(response), None);
    }

    #[test]
    fn convert_returns_none_for_instrumental_or_null_lines() {
        let instrumental = LyricsResponse {
            meta: Meta { instrumental: true },
            lines: Some(vec![ApiLine {
                text: "na".to_string(),
                start: Some(0),
                words: None,
            }]),
        };
        assert_eq!(convert(instrumental), None);
        assert_eq!(
            convert(LyricsResponse {
                meta: Meta::default(),
                lines: None,
            }),
            None
        );
    }
}
