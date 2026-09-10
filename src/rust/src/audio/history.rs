use im::Vector;
use yandex_music::model::track::Track;

/// Cap on retained playback history. Unbounded growth + a full-vector clone
/// into the signal on every track advance leaks memory over long sessions.
/// 100 comfortably covers wave-seed needs (last 20 played).
const MAX_HISTORY_ENTRIES: usize = 100;

#[derive(Clone)]
pub struct HistoryState {
    pub entries: Vector<Track>,
}

impl HistoryState {
    pub fn empty() -> Self {
        Self {
            entries: Vector::new(),
        }
    }

    pub fn reset(&mut self) {
        self.entries = Vector::new();
    }

    pub fn push(&mut self, track: Track) {
        while self.entries.len() >= MAX_HISTORY_ENTRIES {
            self.entries.pop_front();
        }
        self.entries.push_back(track);
    }

    pub fn as_vector(&self) -> Vector<Track> {
        self.entries.clone()
    }
}
