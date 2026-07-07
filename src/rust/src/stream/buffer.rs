use bytes::Bytes;
use std::collections::VecDeque;

#[derive(Debug)]
struct Segment {
    start_pos: u64,
    data: VecDeque<Bytes>,
    len: usize,
}

impl Segment {
    fn new(start_pos: u64) -> Self {
        Self {
            start_pos,
            data: VecDeque::new(),
            len: 0,
        }
    }

    fn contains(&self, pos: u64) -> bool {
        pos >= self.start_pos && pos < self.start_pos + self.len as u64
    }

    fn available_from(&self, pos: u64) -> usize {
        if !self.contains(pos) {
            return 0;
        }
        let off = (pos - self.start_pos) as usize;
        self.len - off
    }

    fn end_pos(&self) -> u64 {
        self.start_pos + self.len as u64
    }

    fn read_at(&self, pos: u64, buf: &mut [u8]) -> usize {
        if !self.contains(pos) {
            return 0;
        }
        let avail = self.available_from(pos);
        let read_len = buf.len().min(avail);
        let mut off = (pos - self.start_pos) as usize;
        let mut copied = 0;

        for chunk in &self.data {
            if copied == read_len {
                break;
            }
            if off >= chunk.len() {
                off -= chunk.len();
                continue;
            }
            let can_copy = chunk.len() - off;
            let to_copy = can_copy.min(read_len - copied);
            buf[copied..copied + to_copy].copy_from_slice(&chunk[off..off + to_copy]);
            copied += to_copy;
            off = 0;
        }
        copied
    }

    fn append(&mut self, new: Bytes) {
        self.len += new.len();
        self.data.push_back(new);
    }
}

#[derive(Debug)]
pub struct BufferState {
    segments: Vec<Segment>,
    total_bytes: u64,
    pub(crate) eof: bool,
    pub(crate) pending: Option<(u64, u64)>,
    max_buffered_from_start: u64,
    buffering_base: u64,
    buffer_size: usize,
    prefetch_trigger: usize,
}

impl BufferState {
    pub fn new(total_bytes: u64, buffer_size: usize, prefetch_trigger: usize) -> Self {
        Self {
            segments: Vec::new(),
            total_bytes,
            eof: false,
            pending: None,
            max_buffered_from_start: 0,
            buffering_base: 0,
            buffer_size,
            prefetch_trigger,
        }
    }

    pub fn contains(&self, pos: u64) -> bool {
        self.segments.iter().any(|s| s.contains(pos))
    }

    pub fn available_from(&self, pos: u64) -> usize {
        self.segments
            .iter()
            .find(|s| s.contains(pos))
            .map(|s| s.available_from(pos))
            .unwrap_or(0)
    }

    pub fn read_at(&mut self, pos: u64, buf: &mut [u8]) -> usize {
        self.segments
            .iter()
            .find(|s| s.contains(pos))
            .map(|s| s.read_at(pos, buf))
            .unwrap_or(0)
    }

    pub fn append(&mut self, new: Bytes, start: u64) -> bool {
        if new.is_empty() {
            return false;
        }

        if let Some((s, e)) = self.pending
            && start >= s
            && start < e
        {
            self.pending = None;
        }

        if start + new.len() as u64 >= self.total_bytes {
            self.eof = true;
        }

        let mut attached = false;
        for seg in &mut self.segments {
            if start == seg.end_pos() {
                seg.append(new.clone());
                attached = true;
                break;
            } else if start + new.len() as u64 == seg.start_pos {
                seg.data.push_front(new.clone());
                seg.start_pos -= new.len() as u64;
                seg.len += new.len();
                attached = true;
                break;
            }
        }

        if !attached {
            let mut new_seg = Segment::new(start);
            new_seg.append(new);
            self.segments.push(new_seg);
        }

        self.merge_segments();
        self.enforce_buffer_limit();

        if let Some(s) = self
            .segments
            .iter()
            .find(|s| s.contains(self.buffering_base) || s.start_pos == self.buffering_base)
        {
            self.max_buffered_from_start = self.max_buffered_from_start.max(s.end_pos());
        }

        true
    }

    fn merge_segments(&mut self) {
        self.segments.sort_by_key(|s| s.start_pos);

        let mut i = 0;
        while i + 1 < self.segments.len() {
            let end_current = self.segments[i].end_pos();
            let start_next = self.segments[i + 1].start_pos;

            if start_next <= end_current {
                if start_next < end_current {
                    let overlap = (end_current - start_next) as usize;
                    if overlap >= self.segments[i + 1].len {
                        self.segments.remove(i + 1);
                        continue;
                    }

                    let mut next_seg = self.segments.remove(i + 1);
                    let mut remaining_to_drop = overlap;
                    while remaining_to_drop > 0 {
                        if let Some(front_chunk) = next_seg.data.front_mut() {
                            if front_chunk.len() <= remaining_to_drop {
                                let dropped = next_seg.data.pop_front().unwrap();
                                next_seg.len -= dropped.len();
                                next_seg.start_pos += dropped.len() as u64;
                                remaining_to_drop -= dropped.len();
                            } else {
                                let advanced = front_chunk.slice(remaining_to_drop..);
                                *front_chunk = advanced;
                                next_seg.len -= remaining_to_drop;
                                next_seg.start_pos += remaining_to_drop as u64;
                                remaining_to_drop = 0;
                            }
                        } else {
                            break;
                        }
                    }
                    if next_seg.len > 0 {
                        self.segments.insert(i + 1, next_seg);
                    }
                    continue;
                }

                let mut next_seg = self.segments.remove(i + 1);
                self.segments[i].len += next_seg.len;
                self.segments[i].data.append(&mut next_seg.data);
            } else {
                i += 1;
            }
        }
    }

    fn enforce_buffer_limit(&mut self) {
        let total_len: usize = self.segments.iter().map(|s| s.len).sum();
        if total_len <= self.buffer_size {
            return;
        }

        let ref_pos = self.buffering_base;

        while self.segments.len() > 1 {
            let total_len: usize = self.segments.iter().map(|s| s.len).sum();
            if total_len <= self.buffer_size {
                break;
            }

            let mut target_idx = None;
            let mut max_dist = 0u64;

            for (idx, seg) in self.segments.iter().enumerate() {
                if seg.contains(ref_pos) {
                    continue;
                }
                let dist = if seg.end_pos() <= ref_pos {
                    ref_pos - seg.end_pos()
                } else {
                    seg.start_pos - ref_pos
                };
                if dist > max_dist {
                    max_dist = dist;
                    target_idx = Some(idx);
                }
            }

            if let Some(idx) = target_idx {
                self.segments.remove(idx);
            } else {
                break;
            }
        }

        if !self.segments.is_empty() {
            let total_len: usize = self.segments.iter().map(|s| s.len).sum();
            let overflow = total_len.saturating_sub(self.buffer_size);
            if overflow > 0 {
                let seg = &mut self.segments[0];

                let max_from_start = if ref_pos >= seg.start_pos {
                    (ref_pos - seg.start_pos) as usize
                } else {
                    0
                };

                let to_drop_from_start = overflow.min(max_from_start);
                let to_drop_from_end = overflow.saturating_sub(to_drop_from_start);

                if to_drop_from_start > 0 {
                    let mut remaining_to_drop = to_drop_from_start;
                    while remaining_to_drop > 0 {
                        if let Some(front_chunk) = seg.data.front_mut() {
                            if front_chunk.len() <= remaining_to_drop {
                                let dropped = seg.data.pop_front().unwrap();
                                seg.len -= dropped.len();
                                seg.start_pos += dropped.len() as u64;
                                remaining_to_drop -= dropped.len();
                            } else {
                                let advanced = front_chunk.slice(remaining_to_drop..);
                                *front_chunk = advanced;
                                seg.len -= remaining_to_drop;
                                seg.start_pos += remaining_to_drop as u64;
                                remaining_to_drop = 0;
                            }
                        } else {
                            break;
                        }
                    }
                }

                if to_drop_from_end > 0 {
                    let mut remaining_to_drop = to_drop_from_end;
                    while remaining_to_drop > 0 {
                        if let Some(back_chunk) = seg.data.back_mut() {
                            if back_chunk.len() <= remaining_to_drop {
                                let dropped = seg.data.pop_back().unwrap();
                                seg.len -= dropped.len();
                                remaining_to_drop -= dropped.len();
                            } else {
                                let truncated =
                                    back_chunk.slice(..back_chunk.len() - remaining_to_drop);
                                *back_chunk = truncated;
                                seg.len -= remaining_to_drop;
                                remaining_to_drop = 0;
                            }
                        } else {
                            break;
                        }
                    }
                }
            }
        }
    }

    pub fn clear(&mut self, start: u64) {
        self.pending = None;
        self.eof = false;
        if start <= self.max_buffered_from_start {
            self.buffering_base = start;
            self.max_buffered_from_start = start;
        }
    }

    pub fn discard_before(&mut self, pos: u64) {
        let keep_history = 256 * 1024;
        let safe_pos = pos.saturating_sub(keep_history);
        self.buffering_base = self.buffering_base.max(pos);

        for seg in &mut self.segments {
            if seg.start_pos < safe_pos && seg.end_pos() > safe_pos {
                let drop_amount = (safe_pos - seg.start_pos) as usize;
                let mut remaining_to_drop = drop_amount;
                while remaining_to_drop > 0 {
                    if let Some(front_chunk) = seg.data.front_mut() {
                        if front_chunk.len() <= remaining_to_drop {
                            let dropped = seg.data.pop_front().unwrap();
                            seg.len -= dropped.len();
                            seg.start_pos += dropped.len() as u64;
                            remaining_to_drop -= dropped.len();
                        } else {
                            let advanced = front_chunk.slice(remaining_to_drop..);
                            *front_chunk = advanced;
                            seg.len -= remaining_to_drop;
                            seg.start_pos += remaining_to_drop as u64;
                            remaining_to_drop = 0;
                        }
                    } else {
                        break;
                    }
                }
            }
        }

        if let Some(s) = self
            .segments
            .iter()
            .find(|s| s.contains(self.buffering_base) || s.start_pos == self.buffering_base)
        {
            self.max_buffered_from_start = self.max_buffered_from_start.max(s.end_pos());
        }
    }

    pub fn end_pos(&self, pos: u64) -> u64 {
        self.segments
            .iter()
            .find(|s| s.contains(pos))
            .map(|s| s.end_pos())
            .unwrap_or(pos)
    }

    pub fn max_buffered_from_start(&self) -> u64 {
        self.max_buffered_from_start
    }

    pub fn should_prefetch(&self, pos: u64) -> bool {
        !self.eof && self.pending.is_none() && self.available_from(pos) < self.prefetch_trigger
    }

    pub fn mark_pending(&mut self, start: u64, end: u64) {
        self.pending = Some((start, end));
    }

    pub fn clear_pending(&mut self) {
        self.pending = None;
    }
}
