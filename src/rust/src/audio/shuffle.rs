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

    pub fn record_removed(&mut self, at: usize) {
        if self.is_active && at < self.index_map.len() {
            self.index_map.remove(at);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::track::test_track;

    fn queue(ids: &[&str]) -> Vector<Track> {
        ids.iter().map(|id| test_track(id)).collect()
    }

    fn ids(v: &Vector<Track>) -> Vec<String> {
        v.iter().map(|t| t.id.clone()).collect()
    }

    #[test]
    fn enable_keeps_current_first_and_disable_restores_order() {
        let mut s = ShuffleState::inactive();
        let q = queue(&["a", "b", "c", "d", "e"]);
        let (shuffled, new_index) = s.enable(q.clone(), 2);
        // Current track stays first at index 0.
        assert_eq!(new_index, 0);
        assert_eq!(shuffled[0].id, "c");
        // Same multiset of tracks.
        let mut got = ids(&shuffled);
        got.sort();
        assert_eq!(got, vec!["a", "b", "c", "d", "e"]);

        let (restored, restored_index) =
            s.disable(new_index).expect("disable must return original");
        assert_eq!(ids(&restored), vec!["a", "b", "c", "d", "e"]);
        // "c" was at index 2 originally.
        assert_eq!(restored_index, 2);
    }

    #[test]
    fn remove_keeps_disable_mapping_valid() {
        let mut s = ShuffleState::inactive();
        let q = queue(&["a", "b", "c", "d"]);
        let (mut shuffled, _) = s.enable(q, 0);
        assert_eq!(shuffled[0].id, "a");
        // Remove shuffled position 1 (whatever track it holds).
        shuffled.remove(1);
        s.record_removed(1);
        // disable(0) must still map to original index of "a" == 0.
        let (_, restored_index) = s.disable(0).expect("disable must work");
        assert_eq!(restored_index, 0);
    }

    #[test]
    fn insert_does_not_break_mapping() {
        let mut s = ShuffleState::inactive();
        let q = queue(&["a", "b", "c"]);
        let (mut shuffled, _) = s.enable(q, 0);
        shuffled.insert(1, test_track("x"));
        s.record_inserted(1);
        let (_, restored_index) = s.disable(0).expect("disable must work");
        assert_eq!(restored_index, 0);
    }
}
