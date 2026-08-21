//! Parser for standard and Enhanced (word-tagged) LRC text, as returned
//! as-is by Yandex Music and LrcLib. Neither source emits the app's own
//! `{agent}`/`{bg}` line tags or `<word:start:end|...>` sidecar format
//! (those only ever came from this app's own TTML/YouLyPlus conversion,
//! which now builds `ParsedLine`s directly instead of round-tripping
//! through text), so this parser only needs to handle the two forms real
//! LRC files actually use.

use crate::lyrics::{ParsedLine, ParsedWord};
use regex::Regex;
use std::sync::LazyLock;

static LINE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[(\d+):(\d+\.\d+)\](.*)$").unwrap());
static INLINE_WORD_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<(\d+):(\d+\.\d+)>([^<]*)").unwrap());

fn parse_timestamp(minutes: &str, seconds: &str) -> f64 {
    minutes.parse().unwrap_or(0.0) * 60.0 + seconds.parse().unwrap_or(0.0)
}

/// True if `text` carries Enhanced-LRC inline word tags (`<mm:ss.xx>`).
/// Cheap existence check for picking between candidate lyrics without a
/// full parse.
pub fn has_inline_words(text: &str) -> bool {
    INLINE_WORD_RE.is_match(text)
}

/// Parses `text` into lines. Untimed text (no `[mm:ss.xx]` prefix at all,
/// e.g. a plain-lyrics fallback with no sync data) yields no lines, since
/// there's no timestamp to place it on the timeline.
pub fn parse(text: &str) -> Vec<ParsedLine> {
    let mut lines = Vec::new();

    for raw_line in text.lines() {
        let Some(caps) = LINE_RE.captures(raw_line) else {
            continue;
        };
        let start = parse_timestamp(&caps[1], &caps[2]);
        let rest = caps[3].trim();

        let word_caps: Vec<_> = INLINE_WORD_RE.captures_iter(rest).collect();
        if word_caps.is_empty() {
            lines.push(ParsedLine {
                start,
                text: rest.to_string(),
                words: Vec::new(),
            });
            continue;
        }

        let mut words = Vec::new();
        for (i, caps) in word_caps.iter().enumerate() {
            let word_text = caps[3].trim();
            if word_text.is_empty() {
                continue;
            }
            let word_start = parse_timestamp(&caps[1], &caps[2]);
            let word_end = word_caps
                .get(i + 1)
                .map(|next| parse_timestamp(&next[1], &next[2]))
                .unwrap_or(word_start + 2.0);
            words.push(ParsedWord {
                text: word_text.to_string(),
                start: word_start,
                end: word_end,
            });
        }

        let line_text = words
            .iter()
            .map(|w| w.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        lines.push(ParsedLine {
            start,
            text: line_text,
            words,
        });
    }

    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_lrc_lines() {
        let lines = parse("[00:01.50]hello world\n[00:03.00]second line\n");
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].start, 1.5);
        assert_eq!(lines[0].text, "hello world");
        assert!(lines[0].words.is_empty());
        assert_eq!(lines[1].start, 3.0);
    }

    #[test]
    fn parses_enhanced_lrc_inline_word_tags() {
        let lines = parse("[00:01.00]<00:01.00>hello <00:01.40>world");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "hello world");
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].start, 1.0);
        assert_eq!(lines[0].words[0].end, 1.4);
        // Last word has no closing tag, so its end is estimated.
        assert_eq!(lines[0].words[1].end, 3.4);
    }

    #[test]
    fn drops_untimed_lines() {
        let lines = parse("just plain text\nwith no timestamps\n");
        assert!(lines.is_empty());
    }
}
