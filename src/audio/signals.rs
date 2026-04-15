use std::sync::Arc;

use im::Vector;
use tokio::sync::watch;
use yandex_music::model::track::Track;

use crate::audio::enums::RepeatMode;
use crate::audio::monitor::Monitor;
use crate::util::reactive::Signal;

#[derive(Clone)]
pub struct AudioSignals {
    pub is_playing: Signal<bool>,
    pub is_paused: Signal<bool>,
    pub is_stopped: Signal<bool>,
    pub is_buffering: Signal<bool>,
    pub current_track: Signal<Option<Track>>,
    pub current_track_id: Signal<Option<String>>,
    pub title: Signal<Option<String>>,
    pub artists: Signal<Option<String>>,
    pub position_ms: Signal<u64>,
    pub duration_ms: Signal<u64>,
    pub progress_ratio: Signal<f32>,
    pub buffered_ratio: Signal<f32>,
    pub volume: Signal<u8>,
    pub is_muted: Signal<bool>,
    pub queue: Signal<Vector<Track>>,
    pub history: Signal<Vector<Track>>,
    pub queue_index: Signal<usize>,
    pub queue_length: Signal<usize>,
    pub repeat_mode: Signal<RepeatMode>,
    pub is_shuffled: Signal<bool>,
    pub current_wave_seeds: Signal<Vec<String>>,
    pub amplitude: Signal<f32>,
    pub codec: Signal<Option<String>>,
    pub monitor: Arc<Monitor>,
    // Канал для уведомления об изменении любого из сигналов (кроме прогресса)
    pub changed: watch::Sender<()>,
    pub changed_rx: watch::Receiver<()>,
    // Канал для уведомления об изменениях в библиотеке (лайки, плейлисты)
    pub library_changed: watch::Sender<()>,
    pub library_changed_rx: watch::Receiver<()>,
    // Канал для уведомления об изменении прогресса
    pub progress_changed: watch::Sender<u32>,
    pub progress_rx: watch::Receiver<u32>,
}

impl AudioSignals {
    pub fn new() -> Self {
        let (changed_tx, changed_rx) = watch::channel(());
        let (library_changed_tx, library_changed_rx) = watch::channel(());
        let (progress_tx, progress_rx) = watch::channel(0u32);
        Self {
            is_playing: Signal::new(false),
            is_paused: Signal::new(false),
            is_stopped: Signal::new(true),
            is_buffering: Signal::new(false),
            current_track: Signal::new(None),
            current_track_id: Signal::new(None),
            title: Signal::new(None),
            artists: Signal::new(None),
            position_ms: Signal::new(0),
            duration_ms: Signal::new(0),
            progress_ratio: Signal::new(0.0),
            buffered_ratio: Signal::new(0.0),
            volume: Signal::new(100),
            is_muted: Signal::new(false),
            queue: Signal::new(Vector::new()),
            history: Signal::new(Vector::new()),
            queue_index: Signal::new(0),
            queue_length: Signal::new(0),
            repeat_mode: Signal::new(RepeatMode::None),
            is_shuffled: Signal::new(false),
            current_wave_seeds: Signal::new(Vec::new()),
            amplitude: Signal::new(0.0),
            codec: Signal::new(None),
            monitor: Arc::new(Monitor::new(1024)),
            changed: changed_tx,
            changed_rx,
            library_changed: library_changed_tx,
            library_changed_rx,
            progress_changed: progress_tx,
            progress_rx,
        }
    }

    pub fn set_current_track(&self, track: Option<Track>) {
        if let Some(t) = &track {
            self.title.set(t.title.clone());
            self.artists.set(Some(
                t.artists
                    .iter()
                    .filter_map(|a| a.name.as_ref())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", "),
            ));
            self.current_track_id.set(Some(t.id.clone()));

            if let Some(duration) = t.duration {
                self.duration_ms.set(duration.as_millis() as u64);
            }
            self.is_stopped.set(false);
        } else {
            self.title.set(None);
            self.artists.set(None);
            self.current_track_id.set(None);
            self.duration_ms.set(0);
            self.is_stopped.set(true);
        }
        self.current_track.set(track);
        self.changed.send_replace(());
    }

    pub fn set_playing(&self, playing: bool) {
        self.is_playing.set(playing);
        self.is_paused.set(!playing && !self.is_stopped.get());
        self.changed.send_replace(());
    }

    pub fn update_progress(&self, position_ms: u64, duration_ms: u64) {
        self.position_ms.set(position_ms);
        self.duration_ms.set(duration_ms);

        let ratio = if duration_ms > 0 {
            (position_ms as f32 / duration_ms as f32).clamp(0.0, 1.0)
        } else {
            0.0
        };
        self.progress_ratio.set(ratio);
        // Уведомляем слушателей прогресса
        self.progress_changed.send_replace(position_ms as u32);
    }

    pub fn update_buffered_ratio(&self, ratio: f32) {
        self.buffered_ratio.set(ratio.clamp(0.0, 1.0));
    }

    pub fn update_queue(&self, queue: Vector<Track>, index: usize) {
        let len = queue.len();
        self.queue.set(queue);
        self.queue_index.set(index);
        self.queue_length.set(len);
        self.changed.send_replace(());
    }

    pub fn set_queue(&self, queue: Vector<Track>, history: Vector<Track>, index: usize) {
        self.queue.set(queue.clone());
        self.history.set(history);
        self.queue_index.set(index);
        self.queue_length.set(queue.len());
        self.changed.send_replace(());
    }

    pub fn set_volume(&self, volume: u8, muted: bool) {
        self.volume.set(volume);
        self.is_muted.set(muted);
        self.changed.send_replace(());
    }

    pub fn set_repeat_mode(&self, repeat: RepeatMode) {
        self.repeat_mode.set(repeat);
        self.changed.send_replace(());
    }

    pub fn set_shuffled(&self, shuffled: bool) {
        self.is_shuffled.set(shuffled);
        self.changed.send_replace(());
    }

    pub fn set_history(&self, history: Vector<Track>) {
        self.history.set(history);
        self.changed.send_replace(());
    }

    pub fn set_wave_seeds(&self, seeds: Vec<String>) {
        self.current_wave_seeds.set(seeds);
        self.changed.send_replace(());
    }

    pub fn set_stream_info(&self, codec: Option<String>) {
        self.codec.set(codec);
        self.changed.send_replace(());
    }
}

impl Default for AudioSignals {
    fn default() -> Self {
        Self::new()
    }
}
