use im::Vector;
use rand::{rng, seq::SliceRandom};
use yandex_music::model::track::Track;

#[derive(Clone)]
pub struct ShuffleState {
    original_queue: Option<Vector<Track>>,
    index_map: Vec<Option<usize>>,
    is_active: bool,
}

impl ShuffleState {
    pub fn inactive() -> Self {
        Self {
            original_queue: None,
            index_map: Vec::new(),
            is_active: false,
        }
    }

    pub fn reset(&mut self) {
        self.original_queue = None;
        self.index_map.clear();
        self.is_active = false;
    }

    pub fn enable(&mut self, queue: Vector<Track>, current_index: usize) -> (Vector<Track>, usize) {
        debug_assert!(!self.is_active, "enable called while already shuffled");

        self.original_queue = Some(queue.clone());

        let mut indices: Vec<Option<usize>> = (0..queue.len()).map(Some).collect();
        let mut queue_vec: Vec<Track> = queue.into_iter().collect();

        if !queue_vec.is_empty() && current_index < queue_vec.len() {
            let current_track = queue_vec.remove(current_index);
            let current_index_val = indices.remove(current_index);

            let mut rest: Vec<(Track, Option<usize>)> =
                queue_vec.into_iter().zip(indices).collect();
            rest.shuffle(&mut rng());

            let mut new_queue_vec = Vec::with_capacity(rest.len() + 1);
            let mut new_indices = Vec::with_capacity(rest.len() + 1);
            new_queue_vec.push(current_track);
            new_indices.push(current_index_val);
            for (t, i) in rest {
                new_queue_vec.push(t);
                new_indices.push(i);
            }

            self.index_map = new_indices;
            self.is_active = true;
            (Vector::from(new_queue_vec), 0)
        } else {
            let mut combined: Vec<(Track, Option<usize>)> =
                queue_vec.into_iter().zip(indices).collect();
            combined.shuffle(&mut rng());

            let (new_queue_vec, new_indices): (Vec<_>, Vec<_>) = combined.into_iter().unzip();
            self.index_map = new_indices;
            self.is_active = true;
            (Vector::from(new_queue_vec), 0)
        }
    }

    pub fn disable(&mut self, current_shuffled_index: usize) -> Option<(Vector<Track>, usize)> {
        debug_assert!(self.is_active, "disable called while not shuffled");

        let original_queue = self.original_queue.take()?;
        let restored_index = self
            .index_map
            .get(current_shuffled_index)
            .and_then(|i| *i)
            .unwrap_or(0);

        self.index_map.clear();
        self.is_active = false;
        Some((original_queue, restored_index))
    }

    pub fn record_inserted(&mut self, at: usize) {
        if self.is_active && at <= self.index_map.len() {
            self.index_map.insert(at, None);
        }
    }
}
