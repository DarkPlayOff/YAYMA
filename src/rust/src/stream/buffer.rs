use bytes::Bytes;
use std::collections::VecDeque;

#[derive(Debug)]
pub struct BufferState {
    data: VecDeque<Bytes>,
    start_pos: u64,
    total_bytes: u64,
    pub(crate) eof: bool,
    pending: Option<(u64, u64)>,
    max_buffered_from_start: u64,
    buffering_base: u64,
    current_bytes_len: usize,
    buffer_size: usize,
    prefetch_trigger: usize,
}

impl BufferState {
    pub fn new(total_bytes: u64, buffer_size: usize, prefetch_trigger: usize) -> Self {
        Self {
            data: VecDeque::new(),
            start_pos: 0,
            total_bytes,
            eof: false,
            pending: None,
            max_buffered_from_start: 0,
            buffering_base: 0,
            current_bytes_len: 0,
            buffer_size,
            prefetch_trigger,
        }
    }

    pub fn contains(&self, pos: u64) -> bool {
        pos >= self.start_pos && pos < self.start_pos + self.current_bytes_len as u64
    }

    pub fn available_from(&self, pos: u64) -> usize {
        if !self.contains(pos) {
            return 0;
        }
        let off = (pos - self.start_pos) as usize;
        self.current_bytes_len - off
    }

    pub fn read_at(&mut self, pos: u64, buf: &mut [u8]) -> usize {
        if !self.contains(pos) {
            return 0;
        }
        let avail = self.available_from(pos);
        let len = buf.len().min(avail);
        let mut off = (pos - self.start_pos) as usize;
        let mut copied = 0;

        for chunk in &self.data {
            if copied == len {
                break;
            }
            if off >= chunk.len() {
                off -= chunk.len();
                continue;
            }
            let can_copy = chunk.len() - off;
            let to_copy = can_copy.min(len - copied);
            buf[copied..copied + to_copy].copy_from_slice(&chunk[off..off + to_copy]);
            copied += to_copy;
            off = 0;
        }
        copied
    }

    pub fn append(&mut self, new: Bytes, start: u64) -> bool {
        if new.is_empty() {
            return false;
        }

        if let Some((s, e)) = self.pending
            && start >= s && start < e
        {
            self.pending = None;
        }

        if start < self.start_pos {
            return false;
        }

        if self.data.is_empty() {
            if start != self.start_pos {
                return false;
            }
        } else {
            let exp_end = self.start_pos + self.current_bytes_len as u64;
            if start != exp_end {
                self.data.clear();
                self.current_bytes_len = 0;
                self.start_pos = start;
                self.eof = false;
            }
        }

        let overflow = (self.current_bytes_len + new.len()).saturating_sub(self.buffer_size);
        if overflow > 0 {
            let mut remaining_to_drop = overflow;
            while remaining_to_drop > 0 {
                if let Some(front_chunk) = self.data.front_mut() {
                    if front_chunk.len() <= remaining_to_drop {
                        let dropped = self.data.pop_front().unwrap();
                        self.current_bytes_len -= dropped.len();
                        self.start_pos += dropped.len() as u64;
                        remaining_to_drop -= dropped.len();
                    } else {
                        let advanced = front_chunk.slice(remaining_to_drop..);
                        *front_chunk = advanced;
                        self.current_bytes_len -= remaining_to_drop;
                        self.start_pos += remaining_to_drop as u64;
                        remaining_to_drop = 0;
                    }
                } else {
                    break;
                }
            }
        }

        if start + new.len() as u64 >= self.total_bytes {
            self.eof = true;
        }

        self.current_bytes_len += new.len();
        self.data.push_back(new);

        let new_end = self.start_pos + self.current_bytes_len as u64;
        if self.start_pos >= self.buffering_base
            && self.start_pos <= self.max_buffered_from_start + 1
        {
            self.max_buffered_from_start = self.max_buffered_from_start.max(new_end);
        }

        true
    }

    pub fn clear(&mut self, start: u64) {
        self.data.clear();
        self.current_bytes_len = 0;
        self.start_pos = start;
        self.pending = None;
        self.eof = false;
        if start <= self.max_buffered_from_start {
            self.buffering_base = start;
            self.max_buffered_from_start = start;
        }
    }

    pub fn discard_before(&mut self, pos: u64) {
        // Keep 256 KB of history to prevent immediate network re-fetches for tiny backwards reads
        let keep_history = 256 * 1024;
        let safe_pos = pos.saturating_sub(keep_history);

        if safe_pos <= self.start_pos {
            return;
        }
        let drop_amount = ((safe_pos - self.start_pos) as usize).min(self.current_bytes_len);
        if drop_amount == 0 {
            return;
        }
        
        let mut remaining_to_drop = drop_amount;
        while remaining_to_drop > 0 {
            if let Some(front_chunk) = self.data.front_mut() {
                if front_chunk.len() <= remaining_to_drop {
                    let dropped = self.data.pop_front().unwrap();
                    self.current_bytes_len -= dropped.len();
                    self.start_pos += dropped.len() as u64;
                    remaining_to_drop -= dropped.len();
                } else {
                    let advanced = front_chunk.slice(remaining_to_drop..);
                    *front_chunk = advanced;
                    self.current_bytes_len -= remaining_to_drop;
                    self.start_pos += remaining_to_drop as u64;
                    remaining_to_drop = 0;
                }
            } else {
                break;
            }
        }

        let current_end = self.start_pos + self.current_bytes_len as u64;
        self.max_buffered_from_start = self.max_buffered_from_start.max(current_end);
    }

    pub fn end_pos(&self) -> u64 {
        self.start_pos + self.current_bytes_len as u64
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
