use futures::future::select_ok;
use serde::Deserialize;

use crate::lyrics::{CLIENT, ParsedLine, ParsedWord, lrc};

const SERVERS: &[&str] = &[
    "https://lyricsplus.prjktla.my.id",
    "https://lyricsplus.atomix.one",
    "https://lyricsplus.binimum.org",
    "https://lyricsplus.prjktla.workers.dev",
    "https://lyricsplus-seven.vercel.app",
    "https://lyrics-plus-backend.vercel.app",
];

#[derive(Debug, Deserialize)]
struct LyricsResponse {
    #[serde(rename = "syncedLyrics")]
    synced_lyrics: Option<String>,
    #[serde(rename = "plainLyrics")]
    plain_lyrics: Option<String>,
    lyrics: Option<Vec<LyricsItem>>,
}

#[derive(Debug, Deserialize)]
struct LyricsItem {
    text: Option<String>,
    time: Option<i64>,
    syllabus: Option<Vec<Syllable>>,
}

#[derive(Debug, Deserialize)]
struct Syllable {
    text: Option<String>,
    time: Option<i64>,
}

/// Converts the provider's own JSON line/syllable format into the shared
/// `ParsedLine` representation.
fn convert_items(items: &[LyricsItem]) -> Option<Vec<ParsedLine>> {
    if items.is_empty() {
        return None;
    }

    let mut lines = Vec::new();
    for item in items {
        let start = item.time.unwrap_or(0) as f64 / 1000.0;

        if let Some(syllabus) = item.syllabus.as_ref().filter(|s| !s.is_empty()) {
            let mut words = Vec::new();
            for (i, syl) in syllabus.iter().enumerate() {
                let text = syl.text.as_deref().unwrap_or("").trim();
                if text.is_empty() {
                    continue;
                }
                let word_start = syl.time.unwrap_or(0) as f64 / 1000.0;
                let word_end = syllabus
                    .get(i + 1)
                    .map(|next| next.time.unwrap_or(0) as f64 / 1000.0)
                    .unwrap_or(word_start + 2.0);
                words.push(ParsedWord { text: text.to_string(), start: word_start, end: word_end });
            }
            let text = words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ");
            lines.push(ParsedLine { start, text, words });
        } else {
            let text = item.text.clone().unwrap_or_default();
            if !text.trim().is_empty() {
                lines.push(ParsedLine { start, text, words: Vec::new() });
            }
        }
    }

    if lines.is_empty() { None } else { Some(lines) }
}

async fn fetch_from_server(
    base_url: &str,
    title: &str,
    artist: &str,
    duration: i32,
    album: Option<&str>,
    id: Option<&str>,
) -> Option<Vec<ParsedLine>> {
    let url = format!("{}/v2/lyrics/get", base_url.trim_end_matches('/'));

    let mut req = CLIENT.get(url).query(&[
        ("title", title),
        ("artist", artist),
        ("duration", &duration.to_string()),
    ]);
    if let Some(album) = album {
        req = req.query(&[("album", album)]);
    }
    if let Some(id) = id {
        req = req.query(&[("id", id)]);
    }

    let resp = req.send().await.ok()?;
    let parsed: LyricsResponse = resp.json().await.ok()?;

    if let Some(synced) = parsed.synced_lyrics.filter(|s| !s.trim().is_empty()) {
        let lines = lrc::parse(&synced);
        if !lines.is_empty() {
            return Some(lines);
        }
    }
    if let Some(lines) = parsed.lyrics.as_deref().and_then(convert_items) {
        return Some(lines);
    }
    parsed
        .plain_lyrics
        .filter(|s| !s.trim().is_empty())
        .map(|s| lrc::parse(&s))
        .filter(|lines| !lines.is_empty())
}

pub async fn get_lyrics(
    title: &str,
    artist: &str,
    duration: i32,
    album: Option<&str>,
    id: Option<&str>,
) -> Option<Vec<ParsedLine>> {
    let futures: Vec<_> = SERVERS
        .iter()
        .map(|server| {
            Box::pin(async move {
                fetch_from_server(server, title, artist, duration, album, id)
                    .await
                    .ok_or(())
            })
        })
        .collect();

    select_ok(futures).await.ok().map(|(lines, _)| lines)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn syllable(text: &str, time: i64) -> Syllable {
        Syllable { text: Some(text.to_string()), time: Some(time) }
    }

    #[test]
    fn convert_items_plain_line_without_syllables() {
        let items = vec![LyricsItem {
            text: Some("hello world".to_string()),
            time: Some(1_000),
            syllabus: None,
        }];
        let lines = convert_items(&items).unwrap();
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].start, 1.0);
        assert_eq!(lines[0].text, "hello world");
        assert!(lines[0].words.is_empty());
    }

    #[test]
    fn convert_items_builds_words_from_syllables() {
        let items = vec![LyricsItem {
            text: None,
            time: Some(0),
            syllabus: Some(vec![syllable("hel", 0), syllable("lo", 300)]),
        }];
        let lines = convert_items(&items).unwrap();
        assert_eq!(lines[0].text, "hel lo");
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].start, 0.0);
        assert_eq!(lines[0].words[0].end, 0.3);
        // Last syllable has no closing tag, so its end is estimated.
        assert_eq!(lines[0].words[1].end, 2.3);
    }

    #[test]
    fn convert_items_returns_none_for_empty_items() {
        assert_eq!(convert_items(&[]), None);
    }
}
