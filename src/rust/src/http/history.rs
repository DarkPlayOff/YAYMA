use super::*;
use crate::util::track::CleanId;
use std::collections::{HashMap, HashSet};
use yandex_music::model::track::Track;

impl ApiService {
    /// `GET /music-history` — the server-side listening history fed by
    /// `POST /plays`. The endpoint ignores paging params and returns the whole
    /// window it keeps, so [offset]/[limit] slice that window: one entry per
    /// play, repeats included. Only ids come from here; the models come from
    /// the regular tracks endpoint, each fetched once and restored in order.
    /// `fullModelsCount` is required: the endpoint answers 400 without it.
    pub async fn fetch_music_history(&self, offset: usize, limit: usize) -> Result<Vec<Track>> {
        let response = send_with_retry(|| {
            self.http_client
                .get(format!("{API_RU}/music-history"))
                .query(&[("fullModelsCount", "0")])
        })
        .await?;
        let body: serde_json::Value = response.json().await?;

        let page: Vec<String> = history_track_ids(&body)
            .into_iter()
            .skip(offset)
            .take(limit)
            .collect();
        let unique = unique_track_ids(&page);
        if unique.is_empty() {
            return Ok(Vec::new());
        }

        let tracks = self.fetch_tracks(unique).await?;
        let by_id: HashMap<String, Track> = tracks
            .into_iter()
            .map(|t| (t.id.to_base_id().to_string(), t))
            .collect();
        Ok(page
            .iter()
            .filter_map(|id| by_id.get(id.to_base_id()).cloned())
            .collect())
    }
}

/// Ids of the tracks to fetch: one per distinct base id, in first-play order.
fn unique_track_ids(played: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    played
        .iter()
        .filter(|id| seen.insert(id.to_base_id().to_string()))
        .cloned()
        .collect()
}

/// Collects track ids from any nested entry of the history payload. Both the
/// current (`historyTabs[].items[].tracks[].data.itemId`) and the older
/// (`tabs[].groups[].items[].id`) shapes are walked.
fn history_track_ids(body: &serde_json::Value) -> Vec<String> {
    let mut ids = Vec::new();
    for tabs_path in ["/result/historyTabs", "/result/tabs"] {
        let Some(tabs) = body.pointer(tabs_path).and_then(|v| v.as_array()) else {
            continue;
        };
        for tab in tabs {
            let groups = tab["items"]
                .as_array()
                .into_iter()
                .flatten()
                .chain(tab["groups"].as_array().into_iter().flatten());
            for group in groups {
                let entries = group["tracks"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .chain(group["items"].as_array().into_iter().flatten());
                for entry in entries {
                    push_history_id(entry, &mut ids);
                }
            }
        }
    }
    ids
}

/// An entry carries its id as `data.itemId`, `id`, or `data.fullModel.id`.
fn push_history_id(entry: &serde_json::Value, out: &mut Vec<String>) {
    let id = entry["data"]
        .get("itemId")
        .or_else(|| entry.get("id"))
        .filter(|id| id.is_object());
    if let Some(track_id) = id.and_then(|id| id.get("trackId")).and_then(|v| v.as_str()) {
        match id.and_then(|id| id.get("albumId")).and_then(|v| v.as_str()) {
            Some(album_id) => out.push(format!("{track_id}:{album_id}")),
            None => out.push(track_id.to_string()),
        }
        return;
    }
    if let Some(id) = entry.pointer("/data/fullModel/id").and_then(|v| v.as_str()) {
        out.push(id.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_current_shape_in_order_and_skips_contexts() {
        let body = json!({
            "result": {
                "historyTabs": [{
                    "date": "2026-11-08",
                    "items": [{
                        "context": {"type": "album", "data": {"itemId": {"id": "1000"}}},
                        "tracks": [
                            {"type": "track", "data": {"itemId": {"trackId": "1", "albumId": "10"}}},
                            {"type": "track", "data": {"itemId": {"trackId": "2", "albumId": "20"}}},
                            {"type": "track", "data": {"fullModel": {"id": "3:30"}}}
                        ]
                    }]
                }]
            }
        });
        assert_eq!(history_track_ids(&body), ["1:10", "2:20", "3:30"]);
    }

    #[test]
    fn reads_legacy_shape() {
        let body = json!({
            "result": {
                "tabs": [{
                    "groups": [{
                        "items": [
                            {"id": {"trackId": "7", "albumId": "70"}, "timestamp": "2026-11-08T10:00:00"},
                            {"id": {"trackId": "8"}, "timestamp": "2026-11-08T09:00:00"}
                        ]
                    }]
                }]
            }
        });
        assert_eq!(history_track_ids(&body), ["7:70", "8"]);
    }

    #[test]
    fn fetches_each_track_once_in_first_play_order() {
        let played = vec![
            "1:10".to_string(),
            "2:20".to_string(),
            "1:10".to_string(),
            "3:30".to_string(),
        ];
        assert_eq!(unique_track_ids(&played), ["1:10", "2:20", "3:30"]);
    }

    #[test]
    fn empty_or_unexpected_payload_has_no_ids() {
        assert!(history_track_ids(&json!({})).is_empty());
        assert!(history_track_ids(&json!({"result": {"historyTabs": []}})).is_empty());
    }
}
