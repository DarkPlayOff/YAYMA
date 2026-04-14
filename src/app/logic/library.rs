use crate::api::models::{SimplePlaylistDto, SimpleTrackDto};
use crate::app::AppContext;
use crate::frb_generated::StreamSink;

pub async fn toggle_like(ctx: &AppContext, track_id: String) {
    let is_liked = {
        let state = ctx.state.read().await;
        state.liked.is_liked(&track_id)
    };

    // Мгновенное локальное обновление (Оптимистичный UI)
    {
        let mut state = ctx.state.write().await;
        state.liked.set_like_status(&track_id, !is_liked);
        ctx.signals.changed.send_replace(());
    }

    // Выполняем запрос к API в фоне
    let api = ctx.api.clone();
    let track_id_clone = track_id.clone();
    let audio_tx = ctx.audio_tx.clone();
    tokio::spawn(async move {
        if is_liked {
            let _ = api.remove_like_track(track_id_clone.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveUnlike(
                    track_id_clone,
                ))
                .await;
        } else {
            let _ = api.add_like_track(track_id_clone.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveLike(
                    track_id_clone,
                ))
                .await;
        }
    });

    // Vibe эффект (если лайкаем)
    if !is_liked && let Ok(mut vibe) = ctx.signals.monitor.vibe.try_lock() {
        vibe.trigger_like();
    }
}

pub async fn toggle_dislike(ctx: &AppContext, track_id: String) {
    let is_disliked = {
        let state = ctx.state.read().await;
        state.liked.is_disliked(&track_id)
    };

    // Мгновенное локальное обновление
    {
        let mut state = ctx.state.write().await;
        state.liked.set_dislike_status(&track_id, !is_disliked);
        ctx.signals.changed.send_replace(());
    }

    // Выполняем запрос к API в фоне
    let api = ctx.api.clone();
    let track_id_clone = track_id.clone();
    let audio_tx = ctx.audio_tx.clone();
    tokio::spawn(async move {
        if is_disliked {
            let _ = api.remove_dislike_track(track_id_clone.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveUndislike(
                    track_id_clone,
                ))
                .await;
        } else {
            let _ = api.add_dislike_track(track_id_clone.clone()).await;
            let _ = audio_tx
                .send(crate::audio::commands::AudioMessage::WaveDislike(
                    track_id_clone,
                ))
                .await;
        }
    });
}

pub async fn upload_user_track(
    ctx: &AppContext,
    file_path: String,
    playlist_kind: Option<u32>,
) -> bool {
    let api = &ctx.api;

    let file_name = std::path::Path::new(&file_path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("track.mp3");

    // Используем 1000 (Лайки) как дефолтный плейлист для загрузки
    let kind = playlist_kind.unwrap_or(1000);

    // 1. Получаем инфо для загрузки (целевой URL)
    let upload_url = match api.fetch_ugc_upload_info(kind, file_name).await {
        Ok(url) => url,
        Err(e) => {
            tracing::error!("Failed to get upload info: {:?}", e);
            return false;
        }
    };

    // 2. Загружаем файл
    let track_id = match api.upload_ugc_track(&upload_url, &file_path).await {
        Ok(id) => id,
        Err(e) => {
            tracing::error!("Failed to upload track: {:?}", e);
            return false;
        }
    };

    // 3. Если мы загружали в конкретный плейлист (не Лайки), добавляем его туда явно
    // Т.к. загрузка через loader может не привязывать трек автоматически.
    if let Some(k) = playlist_kind {
        let _ = api.add_track_to_playlist(k, track_id, String::new()).await;
    }

    true
}

pub async fn get_playlists(ctx: &AppContext) -> Vec<SimplePlaylistDto> {
    match ctx.api.fetch_all_playlists().await {
        Ok(playlists) => playlists
            .into_iter()
            .map(SimplePlaylistDto::from_yandex)
            .collect(),
        Err(_) => vec![],
    }
}

pub async fn add_track_to_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    ctx.api
        .add_track_to_playlist(kind, track_id, album_id.unwrap_or_default())
        .await
        .is_ok()
}

pub async fn remove_track_from_playlist(
    ctx: &AppContext,
    kind: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    ctx.api
        .remove_track_from_playlist(kind, track_id, album_id.unwrap_or_default())
        .await
        .is_ok()
}

pub async fn create_playlist(ctx: &AppContext, title: String, is_public: bool) -> bool {
    ctx.api.create_playlist(title, is_public).await.is_ok()
}

pub async fn delete_playlist(ctx: &AppContext, kind: u32) -> bool {
    ctx.api.delete_playlist(kind).await.is_ok()
}

pub async fn rename_playlist(ctx: &AppContext, kind: u32, new_title: String) -> bool {
    ctx.api.rename_playlist(kind, new_title).await.is_ok()
}

pub async fn set_playlist_visibility(ctx: &AppContext, kind: u32, is_public: bool) -> bool {
    ctx.api
        .change_playlist_visibility(kind, is_public)
        .await
        .is_ok()
}

pub async fn move_track_in_playlist(
    ctx: &AppContext,
    kind: u32,
    from_index: u32,
    to_index: u32,
    track_id: String,
    album_id: Option<String>,
) -> bool {
    ctx.api
        .move_track_in_playlist(
            kind,
            from_index as usize,
            to_index as usize,
            track_id,
            album_id.unwrap_or_default(),
        )
        .await
        .is_ok()
}

pub async fn liked_tracks_stream(
    ctx: &AppContext,
    sink: StreamSink<Vec<SimpleTrackDto>>,
    query: Option<String>,
) {
    let (liked_ids, disliked_ids) = ctx.state.read().await.liked.snapshot();

    // Если есть запрос, пробуем искать в БД
    if let Some(ref q) = query
        && !q.trim().is_empty()
        && let Ok(found_ids) = ctx.db.lock().search_liked_tracks(q)
        && !found_ids.is_empty()
        && let Ok(metadata) = ctx.db.lock().get_track_metadata(&found_ids)
    {
        let mut dtos = Vec::new();
        for (id, title, version, artists_names, album, album_id, cover_url, duration_ms) in metadata
        {
            let artists: Vec<crate::api::models::TrackArtistDto> = artists_names
                .into_iter()
                .map(|name| crate::api::models::TrackArtistDto {
                    id: "".to_string(),
                    name,
                })
                .collect();

            dtos.push(SimpleTrackDto {
                id,
                title,
                version,
                artists,
                album,
                album_id,
                cover_url,
                duration_ms: duration_ms as u32,
                is_liked: true,
                is_disliked: false,
            });

            if dtos.len() == 30 && sink.add(std::mem::take(&mut dtos)).is_err() {
                return;
            }
        }
        if !dtos.is_empty() {
            let _ = sink.add(dtos);
        }
        return;
    }

    // Если запроса нет, или в БД пусто, или поиск в БД ничего не нашел — тянем из API
    if let Ok(playlist) = ctx.api.fetch_liked_tracks().await
        && let Some(tracks_enum) = playlist.tracks
    {
        let tracks_vec = crate::util::track::fetch_full_tracks(&ctx.api, tracks_enum).await;

        // Сохраняем в БД для будущего поиска
        for t in &tracks_vec {
            let artists: Vec<String> = t.artists.iter().filter_map(|a| a.name.clone()).collect();
            let album = t.albums.first().and_then(|a| a.title.clone());
            let album_id = t.albums.first().and_then(|a| a.id).map(|id| id.to_string());
            let cover_url = t
                .og_image
                .as_ref()
                .map(|img| format!("https://{}", img.replace("%%", "200x200")));

            let _ = ctx.db.lock().upsert_track_metadata(
                &t.id,
                t.title.as_deref().unwrap_or_default(),
                t.version.as_deref(),
                &artists,
                album.as_deref(),
                album_id.as_deref(),
                cover_url.as_deref(),
                t.duration.map(|d| d.as_millis() as u64).unwrap_or(0),
            );
        }

        let query_lower = query.map(|q| q.to_lowercase());
        let matches_query = |dto: &SimpleTrackDto| {
            if let Some(ref q) = query_lower {
                dto.title.to_lowercase().contains(q)
                    || dto
                        .artists
                        .iter()
                        .any(|a| a.name.to_lowercase().contains(q))
            } else {
                true
            }
        };

        let dtos_iter = tracks_vec
            .into_iter()
            .map(|t| SimpleTrackDto::from_yandex(&t, &liked_ids, &disliked_ids))
            .filter(matches_query);

        let mut current_chunk = Vec::with_capacity(30);
        for dto in dtos_iter {
            current_chunk.push(dto);
            if current_chunk.len() == 30
                && sink
                    .add(std::mem::replace(
                        &mut current_chunk,
                        Vec::with_capacity(30),
                    ))
                    .is_err()
            {
                return;
            }
        }
        if !current_chunk.is_empty() {
            let _ = sink.add(current_chunk);
        }
    }
}
