use im::Vector;
use yandex_music::model::track::Track;

#[derive(Clone)]
pub struct HistoryState {
    pub entries: Vector<Track>,
    pub cursor: usize,
}

impl HistoryState {
    pub fn empty() -> Self {
        Self {
            entries: Vector::new(),
            cursor: 0,
        }
    }

    pub fn reset(&mut self) {
        self.entries = Vector::new();
        self.cursor = 0;
    }

    pub fn push(&mut self, track: Track) {
        if !self.entries.is_empty() && self.cursor < self.entries.len() {
            self.entries.truncate(self.cursor + 1);
        }
        self.entries.push_back(track);
        self.cursor = self.entries.len().saturating_sub(1);
    }

    pub fn as_vector(&self) -> Vector<Track> {
        self.entries.clone()
    }
}
