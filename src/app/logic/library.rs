use crate::api::models::{SimplePlaylistDto, SimpleTrackDto};
use crate::app::AppContext;
use crate::frb_generated::StreamSink;
use foldhash::HashMapExt;

pub async fn toggle_like(ctx: &AppContext, track_id: String) {
    let is_liked = {
        let state = ctx.state.read().await;
        state.liked.is_liked(&track_id)
    };

    // Мгновенное локальное обновление (Оптимистичный UI)
    {
        let mut state = ctx.state.write().await;
        state.liked.set_like_status(&track_id, !is_liked);

        // Обновляем БД сразу для поиска и оффлайн-доступа
        let db = ctx.db.lock();
        if is_liked {
            let _ = db.remove_liked_track(&track_id);
        } else {
            let _ = db.add_liked_track(&track_id);
        }

        ctx.signals.library_changed.send_replace(());
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
        ctx.signals.library_changed.send_replace(());
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
    let mut changed_rx = ctx.signals.library_changed_rx.clone();

    loop {
        // Отправляем пустой список как сигнал сброса для фронтенда,
        // чтобы избежать дубликатов при обновлении.
        if sink.add(vec![]).is_err() {
            return;
        }

        let (liked_ids, disliked_ids_set) = ctx.state.read().await.liked.ordered_snapshot();

        // 1. Обработка поиска (используем БД)
        if let Some(ref q) = query
            && !q.trim().is_empty()
        {
            if let Ok(found_ids) = ctx.db.lock().search_liked_tracks(q)
                && !found_ids.is_empty()
            {
                // Для поиска используем метаданные из БД
                if let Ok(metadata) = ctx.db.lock().get_track_metadata(&found_ids) {
                    let mut dtos = Vec::new();
                    for (id, title, version, artists_names, album, album_id, cover_url, duration_ms) in
                        metadata
                    {
                        let artists: Vec<crate::api::models::TrackArtistDto> = artists_names
                            .into_iter()
                            .map(|name: String| crate::api::models::TrackArtistDto {
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

                        if dtos.len() == 50 && sink.add(std::mem::take(&mut dtos)).is_err() {
                            return;
                        }
                    }
                    if !dtos.is_empty() {
                        let _ = sink.add(dtos);
                    }
                }
            } else {
                let _ = sink.add(vec![]);
            }
        } else {
            // 2. Основной список (Local-First)
            if liked_ids.is_empty() {
                // Если локально пусто, возможно еще не синхронизировались
                let _ = ctx.audio_tx.send(crate::audio::commands::AudioMessage::SyncLiked).await;
            }

            // Пытаемся достать метаданные из БД для всех лайкнутых ID
            let mut metadata_map = foldhash::HashMap::new();
            if let Ok(metadata) = ctx.db.lock().get_track_metadata(&liked_ids) {
                for m in metadata {
                    metadata_map.insert(m.0.clone(), m);
                }
            }

            // Проверяем, для каких треков нет метаданных
            let missing_ids: Vec<String> = liked_ids
                .iter()
                .filter(|id| !metadata_map.contains_key(*id))
                .cloned()
                .collect();

            if !missing_ids.is_empty() {
                // Дотягиваем недостающие метаданные из API (батчами по 50)
                for chunk in missing_ids.chunks(50) {
                    if let Ok(tracks) = ctx.api.fetch_tracks(chunk.to_vec()).await {
                        for t in tracks {
                            let artists: Vec<String> =
                                t.artists.iter().filter_map(|a| a.name.clone()).collect();
                            let album = t.albums.first().and_then(|a| a.title.clone());
                            let album_id =
                                t.albums.first().and_then(|a| a.id).map(|id| id.to_string());
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

                            // Добавляем в текущую карту для мгновенного отображения
                            let duration_ms = t.duration.map(|d| d.as_millis() as u64).unwrap_or(0);
                            metadata_map.insert(
                                t.id.clone(),
                                (
                                    t.id.clone(),
                                    t.title.clone().unwrap_or_default(),
                                    t.version.clone(),
                                    artists,
                                    album,
                                    album_id,
                                    cover_url,
                                    duration_ms,
                                ),
                            );
                        }
                    }
                }
            }

            // Формируем финальный список DTO в правильном порядке
            let mut dtos = Vec::with_capacity(liked_ids.len());
            for id in &liked_ids {
                if let Some((
                    id,
                    title,
                    version,
                    artists_names,
                    album,
                    album_id,
                    cover_url,
                    duration_ms,
                )) = metadata_map.get(id)
                {
                    let artists: Vec<crate::api::models::TrackArtistDto> = artists_names
                        .iter()
                        .map(|name: &String| crate::api::models::TrackArtistDto {
                            id: "".to_string(),
                            name: name.clone(),
                        })
                        .collect();

                    dtos.push(SimpleTrackDto {
                        id: id.clone(),
                        title: title.clone(),
                        version: version.clone(),
                        artists,
                        album: album.clone(),
                        album_id: album_id.clone(),
                        cover_url: cover_url.clone(),
                        duration_ms: *duration_ms as u32,
                        is_liked: true,
                        is_disliked: disliked_ids_set.contains(id),
                    });

                    if dtos.len() == 50 {
                        if sink.add(std::mem::take(&mut dtos)).is_err() {
                            return;
                        }
                    }
                }
            }
            if !dtos.is_empty() {
                let _ = sink.add(dtos);
            }
        }

        // Ждем изменений в сигналах
        if changed_rx.changed().await.is_err() {
            break;
        }
    }
}
