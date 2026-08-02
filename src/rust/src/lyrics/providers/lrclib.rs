use serde::Deserialize;

use super::{clean_artist, clean_title, string_similarity};
use crate::lyrics::{CLIENT, ParsedLine, lrc};

#[derive(Debug, Deserialize)]
struct Track {
    #[serde(rename = "trackName")]
    track_name: String,
    #[serde(rename = "artistName")]
    artist_name: String,
    duration: f64,
    #[serde(rename = "plainLyrics")]
    plain_lyrics: Option<String>,
    #[serde(rename = "syncedLyrics")]
    synced_lyrics: Option<String>,
}

async fn search(
    query: Option<&str>,
    track_name: Option<&str>,
    artist_name: Option<&str>,
    album_name: Option<&str>,
) -> Vec<Track> {
    let mut req = CLIENT.get("https://lrclib.net/api/search");
    if let Some(q) = query {
        req = req.query(&[("q", q)]);
    }
    if let Some(t) = track_name {
        req = req.query(&[("track_name", t)]);
    }
    if let Some(a) = artist_name {
        req = req.query(&[("artist_name", a)]);
    }
    if let Some(a) = album_name {
        req = req.query(&[("album_name", a)]);
    }

    let Ok(resp) = req.send().await else {
        return Vec::new();
    };
    let Ok(text) = resp.text().await else {
        return Vec::new();
    };
    let Ok(serde_json::Value::Array(entries)) = serde_json::from_str(&text) else {
        return Vec::new();
    };
    // Deserialize each entry individually so one malformed row (known to
    // happen with LrcLib's community-submitted data) doesn't discard every
    // otherwise-valid match in the response.
    entries
        .into_iter()
        .filter_map(|v| serde_json::from_value::<Track>(v).ok())
        .collect()
}

async fn query_lyrics(artist: &str, title: &str, album: Option<&str>) -> Vec<Track> {
    let cleaned_title = clean_title(title);
    let cleaned_artist = clean_artist(artist);
    let has_lyrics = |t: &Track| t.synced_lyrics.is_some() || t.plain_lyrics.is_some();
    let combined = format!("{cleaned_artist} {cleaned_title}");
    let trimmed_title = title.trim();
    let trimmed_artist = artist.trim();

    // Progressively looser fallbacks, tried in priority order until one yields lyrics.
    let mut attempts = vec![
        (None, Some(cleaned_title.as_str()), Some(cleaned_artist.as_str()), album),
        (None, Some(cleaned_title.as_str()), None, None),
        (Some(combined.as_str()), None, None, None),
        (Some(cleaned_title.as_str()), None, None, None),
    ];
    if cleaned_title != trimmed_title {
        attempts.push((None, Some(trimmed_title), Some(trimmed_artist), None));
    }

    for (query, track_name, artist_name, album_name) in attempts {
        let mut results = search(query, track_name, artist_name, album_name).await;
        results.retain(has_lyrics);
        if !results.is_empty() {
            return results;
        }
    }

    Vec::new()
}

/// True if `t`'s synced lyrics carry Enhanced-LRC per-word timing. Popular
/// tracks often have several community submissions on LrcLib — some plain
/// LRC, some Enhanced — so this needs its own check rather than treating
/// any `synced_lyrics` as equally good.
fn has_word_sync(t: &Track) -> bool {
    t.synced_lyrics.as_deref().is_some_and(lrc::has_inline_words)
}

fn best_matching(tracks: &[Track], duration: i32, title: &str, artist: &str) -> Option<usize> {
    if tracks.is_empty() {
        return None;
    }

    if duration == -1 {
        let normalized_title = title.trim().to_lowercase();
        let normalized_artist = artist.trim().to_lowercase();
        // Rank by title/artist similarity, with a bonus for having synced
        // lyrics (bigger if it's word-synced) so it wins ties against an
        // equally-similar plain-lyrics-only match.
        let score = |t: &Track| {
            let base = (string_similarity(&normalized_title, &t.track_name)
                + string_similarity(&normalized_artist, &t.artist_name))
                / 2.0;
            if has_word_sync(t) {
                base + 0.02
            } else if t.synced_lyrics.is_some() {
                base + 0.01
            } else {
                base
            }
        };
        return tracks
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| score(a).total_cmp(&score(b)))
            .map(|(i, _)| i);
    }

    let within_tolerance = |t: &&Track| (t.duration as i32 - duration).abs() <= 5;

    // Prefer word-synced lyrics within +-5s, then any synced lyrics, then
    // fall back to any track within +-5s.
    let word_synced_best = tracks
        .iter()
        .enumerate()
        .filter(|(_, t)| has_word_sync(t))
        .min_by_key(|(_, t)| (t.duration as i32 - duration).abs())
        .filter(|(_, t)| within_tolerance(t))
        .map(|(i, _)| i);

    let synced_best = || {
        tracks
            .iter()
            .enumerate()
            .filter(|(_, t)| t.synced_lyrics.is_some())
            .min_by_key(|(_, t)| (t.duration as i32 - duration).abs())
            .filter(|(_, t)| within_tolerance(t))
            .map(|(i, _)| i)
    };

    word_synced_best.or_else(synced_best).or_else(|| {
        tracks
            .iter()
            .enumerate()
            .min_by_key(|(_, t)| (t.duration as i32 - duration).abs())
            .filter(|(_, t)| within_tolerance(t))
            .map(|(i, _)| i)
    })
}


pub async fn get_lyrics(
    title: &str,
    artist: &str,
    duration: i32,
    album: Option<&str>,
) -> Option<Vec<ParsedLine>> {
    let tracks = query_lyrics(artist, title, album).await;
    let index = best_matching(&tracks, duration, title, artist)?;
    let track = &tracks[index];
    let raw = track.synced_lyrics.clone().or_else(|| track.plain_lyrics.clone())?;
    let lines = lrc::parse(&raw);
    if lines.is_empty() { None } else { Some(lines) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(name: &str, artist: &str, duration: f64, synced: bool, plain: bool) -> Track {
        Track {
            track_name: name.to_string(),
            artist_name: artist.to_string(),
            duration,
            plain_lyrics: plain.then(|| "plain".to_string()),
            synced_lyrics: synced.then(|| "[00:01.00]synced".to_string()),
        }
    }

    fn word_synced_track(name: &str, artist: &str, duration: f64) -> Track {
        Track {
            track_name: name.to_string(),
            artist_name: artist.to_string(),
            duration,
            plain_lyrics: None,
            synced_lyrics: Some("[00:01.00]<00:01.00>hello <00:01.40>world".to_string()),
        }
    }

    #[test]
    fn returns_none_for_empty_tracks() {
        assert_eq!(best_matching(&[], 200, "Title", "Artist"), None);
    }

    #[test]
    fn prefers_synced_lyrics_within_duration_tolerance() {
        let tracks = [
            track("Title", "Artist", 200.0, false, true),
            track("Title", "Artist", 201.0, true, true),
        ];
        assert_eq!(best_matching(&tracks, 200, "Title", "Artist"), Some(1));
    }

    #[test]
    fn falls_back_to_any_track_within_tolerance_when_none_synced() {
        let tracks = [track("Title", "Artist", 203.0, false, true)];
        assert_eq!(best_matching(&tracks, 200, "Title", "Artist"), Some(0));
    }

    #[test]
    fn returns_none_when_no_track_is_within_duration_tolerance() {
        let tracks = [track("Title", "Artist", 400.0, true, true)];
        assert_eq!(best_matching(&tracks, 200, "Title", "Artist"), None);
    }

    #[test]
    fn unknown_duration_picks_best_title_artist_similarity_match() {
        let tracks = [
            track("Completely Unrelated Song", "Some Other Band", 0.0, false, true),
            track("Exact Title", "Exact Artist", 0.0, false, true),
        ];
        assert_eq!(
            best_matching(&tracks, -1, "Exact Title", "Exact Artist"),
            Some(1)
        );
    }

    #[test]
    fn unknown_duration_breaks_similarity_ties_toward_synced_lyrics() {
        let tracks = [
            track("Exact Title", "Exact Artist", 0.0, false, true),
            track("Exact Title", "Exact Artist", 0.0, true, true),
        ];
        assert_eq!(
            best_matching(&tracks, -1, "Exact Title", "Exact Artist"),
            Some(1)
        );
    }

    #[test]
    fn prefers_word_synced_submission_over_a_closer_plain_synced_one() {
        // Popular tracks often have multiple community submissions; a
        // plain-synced one a second closer in duration shouldn't win over
        // a word-synced one still within tolerance.
        let tracks = [
            track("Title", "Artist", 200.0, true, false),
            word_synced_track("Title", "Artist", 201.0),
        ];
        assert_eq!(best_matching(&tracks, 200, "Title", "Artist"), Some(1));
    }

    #[test]
    fn falls_back_to_plain_synced_when_no_word_synced_submission_in_tolerance() {
        let tracks = [
            track("Title", "Artist", 200.0, true, false),
            word_synced_track("Title", "Artist", 400.0),
        ];
        assert_eq!(best_matching(&tracks, 200, "Title", "Artist"), Some(0));
    }
}
