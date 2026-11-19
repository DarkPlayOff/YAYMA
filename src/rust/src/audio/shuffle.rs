use im::Vector;
use yandex_music::model::track::Track;

#[derive(Clone)]
pub struct ShuffleState {
    /// Live mirror of the queue in source order: every mutation made while
    /// shuffled is mirrored here, so `disable` restores the CURRENT tracks
    /// (with additions/removals applied), not a stale enable-time snapshot.
    original_queue: Option<Vector<Track>>,
    /// Shuffled position -> source position in `original_queue`; a live
    /// bijection maintained by the `record_*` mirrors.
    index_map: Vec<usize>,
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

        let mut indices: Vec<usize> = (0..queue.len()).collect();
        let mut queue_vec: Vec<Track> = queue.into_iter().collect();

        if !queue_vec.is_empty() && current_index < queue_vec.len() {
            let current_track = queue_vec.remove(current_index);
            let current_index_val = indices.remove(current_index);

            let mut rest: Vec<(Track, usize)> = queue_vec.into_iter().zip(indices).collect();
            fastrand::shuffle(&mut rest);

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
            let mut combined: Vec<(Track, usize)> =
                queue_vec.into_iter().zip(indices).collect();
            fastrand::shuffle(&mut combined);

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
            .copied()
            .unwrap_or(0);

        self.index_map.clear();
        self.is_active = false;
        Some((original_queue, restored_index))
    }

    /// Mirror a visible-queue insertion at `at`: the track lands right after
    /// the source position of its visible predecessor, so a "play next"
    /// insertion still plays right after the current track once shuffle is
    /// turned off.
    pub fn record_inserted(&mut self, track: Track, at: usize) {
        if !self.is_active || at > self.index_map.len() {
            return;
        }
        let Some(original) = self.original_queue.as_mut() else {
            return;
        };
        let source_at = if at == 0 { 0 } else { self.index_map[at - 1] + 1 };
        for entry in &mut self.index_map {
            if *entry >= source_at {
                *entry += 1;
            }
        }
        original.insert(source_at, track);
        self.index_map.insert(at, source_at);
    }

    /// Mirror a visible-queue removal at `at`: the track leaves the source
    /// order too and later source positions shift down.
    pub fn record_removed(&mut self, at: usize) {
        if !self.is_active || at >= self.index_map.len() {
            return;
        }
        let source = self.index_map.remove(at);
        let Some(original) = self.original_queue.as_mut() else {
            return;
        };
        if source >= original.len() {
            return;
        }
        original.remove(source);
        for entry in &mut self.index_map {
            if *entry > source {
                *entry -= 1;
            }
        }
    }

    /// Keeps the original-queue mapping valid across a position swap inside
    /// the shuffled order: the entry at `from` moves to `to`.
    pub fn record_reorder(&mut self, from: usize, to: usize) {
        if !self.is_active || from == to || from >= self.index_map.len() {
            return;
        }
        let entry = self.index_map.remove(from);
        if to <= self.index_map.len() {
            self.index_map.insert(to, entry);
        } else {
            self.index_map.push(entry);
        }
    }

    /// Mirror tracks appended at the visible end (lazy playlist top-up):
    /// they continue the source list, so they land at the source end too.
    pub fn record_appended(&mut self, tracks: &[Track]) {
        if !self.is_active {
            return;
        }
        let Some(original) = self.original_queue.as_mut() else {
            return;
        };
        for track in tracks {
            original.push_back(track.clone());
            self.index_map.push(original.len() - 1);
        }
    }

    /// Re-rolls the shuffled order anchored on the track currently at
    /// `anchor`: the anchor becomes position 0 and the rest is reshuffled.
    /// The original-queue mapping is rebuilt so `disable` keeps working.
    pub fn reroll_anchored(
        &mut self,
        shuffled_queue: Vector<Track>,
        anchor: usize,
    ) -> (Vector<Track>, usize) {
        debug_assert!(self.is_active, "reroll called while not shuffled");

        let mut tracks: Vec<Track> = shuffled_queue.into_iter().collect();
        if tracks.is_empty() {
            return (Vector::new(), 0);
        }
        let anchor = anchor.min(tracks.len() - 1);
        let current = tracks.remove(anchor);
        let mut map = std::mem::take(&mut self.index_map);
        let current_entry = if anchor < map.len() {
            map.remove(anchor)
        } else {
            0
        };

        let mut rest: Vec<(Track, usize)> = tracks.into_iter().zip(map).collect();
        fastrand::shuffle(&mut rest);

        let mut new_tracks = Vec::with_capacity(rest.len() + 1);
        let mut new_map = Vec::with_capacity(rest.len() + 1);
        new_tracks.push(current);
        new_map.push(current_entry);
        for (t, m) in rest {
            new_tracks.push(t);
            new_map.push(m);
        }
        self.index_map = new_map;
        (Vector::from(new_tracks), 0)
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
        let (shuffled, new_index) = s.enable(q, 2);
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
        s.record_inserted(test_track("x"), 1);
        let (_, restored_index) = s.disable(0).expect("disable must work");
        assert_eq!(restored_index, 0);
    }

    #[test]
    fn disable_keeps_tracks_added_and_removed_while_shuffled() {
        let mut s = ShuffleState::inactive();
        let q = queue(&["a", "b", "c", "d"]);
        let (mut shuffled, _) = s.enable(q, 0);
        // "Play next": the insertion goes right after the playing track.
        shuffled.insert(1, test_track("x"));
        s.record_inserted(test_track("x"), 1);
        // Remove another upcoming row (whatever track it holds).
        let removed = shuffled[2].id.clone();
        shuffled.remove(2);
        s.record_removed(2);

        let (restored, restored_index) = s.disable(0).expect("disable must work");
        let restored_ids = ids(&restored);
        assert_eq!(restored_ids.len(), 4);
        assert!(!restored_ids.contains(&removed));
        // "x" still plays right after the current track ...
        assert_eq!(restored_ids[0], "a");
        assert_eq!(restored_ids[1], "x");
        // ... and the survivors keep their source order.
        let mut expected_tail: Vec<String> = vec!["b".into(), "c".into(), "d".into()];
        expected_tail.retain(|id| *id != removed);
        assert_eq!(restored_ids[2..], expected_tail);
        assert_eq!(restored_index, 0);
    }

    #[test]
    fn appended_tracks_extend_the_source_tail() {
        let mut s = ShuffleState::inactive();
        let q = queue(&["a", "b"]);
        let (mut shuffled, _) = s.enable(q, 0);
        let appended = vec![test_track("m"), test_track("n")];
        for t in &appended {
            shuffled.push_back(t.clone());
        }
        s.record_appended(&appended);
        let (restored, restored_index) = s.disable(0).expect("disable must work");
        assert_eq!(ids(&restored), vec!["a", "b", "m", "n"]);
        assert_eq!(restored_index, 0);
    }
}
