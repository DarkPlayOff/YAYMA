use serde::Deserialize;

use crate::lyrics::CLIENT;
use crate::lyrics::ParsedLine;
use crate::lyrics::ttml;

const BASE_URL: &str = "https://lyrics-api.boidu.dev";

#[derive(Debug, Deserialize)]
struct TtmlResponse {
    ttml: String,
}

async fn fetch_ttml(
    artist: &str,
    title: &str,
    duration: i32,
    album: Option<&str>,
) -> Option<String> {
    let mut req = CLIENT
        .get(format!("{BASE_URL}/getLyrics"))
        .query(&[("s", title), ("a", artist)]);
    if duration > 0 {
        req = req.query(&[("d", duration.to_string())]);
    }
    if let Some(album) = album {
        if !album.trim().is_empty() {
            req = req.query(&[("al", album)]);
        }
    }

    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.json::<TtmlResponse>().await.ok().map(|r| r.ttml)
}

pub async fn get_lyrics(
    title: &str,
    artist: &str,
    duration: i32,
    album: Option<&str>,
) -> Option<Vec<ParsedLine>> {
    let raw_ttml = fetch_ttml(artist, title, duration, album).await?;
    let parsed = ttml::parse_ttml(&raw_ttml);
    if parsed.is_empty() {
        None
    } else {
        Some(parsed)
    }
}
