use crate::api::models::{LyricItemDto, LyricsLineDto};

/// Gaps longer than this become an explicit pause instead of one long line.
const LONG_GAP_MS: i64 = 5_000;
/// How long a line's text stays on screen when it has no word timing.
const LINE_TEXT_MS: i64 = 4_000;
/// Breathing room kept between a line's text and the pause that follows it.
const LINE_BREATH_MS: i64 = 1_000;
/// Synthetic window given to the last line, since nothing says when it ends.
const LAST_LINE_MS: i64 = 10_000;
/// Opening pause starts a second in and stops a second before the first line.
const START_PAUSE_AT_MS: i64 = 1_000;
const START_PAUSE_LEAD_MS: i64 = 2_000;

/// Turns parsed lines into the playback timeline: lines carry the time their
/// text is on screen, long gaps become explicit pause items so the UI can show
/// a countdown, and the trailing silence after the last sung word becomes a
/// pause too when the track duration is known. A `line: None` item is a pause.
pub fn build_timeline(
    lines: Vec<LyricsLineDto>,
    track_duration_ms: Option<i64>,
) -> Vec<LyricItemDto> {
    let mut items = Vec::with_capacity(lines.len() * 2);
    let Some(first) = lines.first() else {
        return items;
    };

    // Opening silence: start the countdown a second in, ending a second before
    // the first line so the pause does not overlap it.
    if first.start_ms > LONG_GAP_MS {
        items.push(LyricItemDto {
            time_ms: START_PAUSE_AT_MS,
            duration_ms: first.start_ms - START_PAUSE_LEAD_MS,
            line: None,
        });
    }

    let mut lines = lines.into_iter().peekable();
    while let Some(line) = lines.next() {
        let start_ms = line.start_ms;
        let is_last = lines.peek().is_none();
        let next_start = lines.peek().map_or(start_ms + LAST_LINE_MS, |next| next.start_ms);
        let duration = next_start - start_ms;

        // The last line only carries its text; any trailing silence is the
        // outro pause below. An in-line pause here would swallow the outro.
        if is_last || duration <= LONG_GAP_MS {
            let text_duration = if is_last {
                line.words
                    .last()
                    .map_or(LINE_TEXT_MS, |word| word.end_ms - start_ms)
                    .clamp(0, duration)
            } else {
                duration
            };
            items.push(LyricItemDto {
                time_ms: start_ms,
                duration_ms: text_duration,
                line: Some(line),
            });
        } else {
            // Word timings can span most of a long gap: end the line when the
            // last word is sung instead of stopping the karaoke cursor after 4 s.
            let sung = line
                .words
                .last()
                .map_or(LINE_TEXT_MS, |word| word.end_ms - start_ms);
            let text_duration = sung.clamp(0, duration);

            items.push(LyricItemDto {
                time_ms: start_ms,
                duration_ms: text_duration,
                line: Some(line),
            });

            let pause_duration = duration - text_duration - LINE_BREATH_MS;
            if pause_duration > 0 {
                items.push(LyricItemDto {
                    time_ms: start_ms + text_duration,
                    duration_ms: pause_duration,
                    line: None,
                });
            }
        }
    }

    let Some(track_duration_ms) = track_duration_ms else {
        return items;
    };
    let Some(last) = items.last() else {
        return items;
    };
    let Some(last_line) = &last.line else {
        return items;
    };
    let line_end = last_line
        .words
        .last()
        .map_or(last.time_ms + LINE_TEXT_MS, |word| word.end_ms);
    let gap = track_duration_ms - line_end;
    if gap > LONG_GAP_MS {
        items.push(LyricItemDto {
            time_ms: line_end,
            duration_ms: gap,
            line: None,
        });
    }

    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::models::LyricsWordDto;

    fn line(start_ms: i64, text: &str) -> LyricsLineDto {
        LyricsLineDto {
            start_ms,
            text: text.to_string(),
            words: Vec::new(),
        }
    }

    fn word(start_ms: i64, end_ms: i64) -> LyricsWordDto {
        LyricsWordDto {
            text: "word".to_string(),
            start_ms,
            end_ms,
        }
    }

    #[test]
    fn empty_input_builds_nothing() {
        assert!(build_timeline(Vec::new(), Some(180_000)).is_empty());
    }

    #[test]
    fn short_lines_get_the_full_gap_as_text_duration() {
        let items = build_timeline(vec![line(0, "a"), line(3_000, "b"), line(6_000, "c")], None);
        assert_eq!(items[0].duration_ms, 3_000);
        assert!(items[0].line.is_some());
        assert_eq!(items[1].time_ms, 3_000);
        assert_eq!(items[1].duration_ms, 3_000);
        assert_eq!(items[1].line.as_ref().unwrap().text, "b");
    }

    #[test]
    fn long_gap_yields_line_with_capped_text_plus_pause() {
        let items = build_timeline(vec![line(0, "a"), line(20_000, "b")], None);
        assert_eq!(items[0].time_ms, 0);
        assert_eq!(items[0].duration_ms, LINE_TEXT_MS);
        assert_eq!(items[1].time_ms, LINE_TEXT_MS);
        assert_eq!(items[1].duration_ms, 20_000 - LINE_TEXT_MS - LINE_BREATH_MS);
        assert!(items[1].line.is_none());
    }

    #[test]
    fn word_timings_extend_the_text_past_the_4s_cap() {
        let mut first = line(0, "a");
        first.words = vec![word(0, 2_000), word(2_000, 8_000)];
        let items = build_timeline(vec![first, line(20_000, "b")], None);
        assert_eq!(items[0].duration_ms, 8_000);
        assert_eq!(items[1].time_ms, 8_000);
        assert_eq!(items[1].duration_ms, 20_000 - 8_000 - LINE_BREATH_MS);
    }

    #[test]
    fn leading_silence_gets_a_start_pause() {
        let items = build_timeline(vec![line(8_000, "a")], None);
        assert_eq!(items[0].time_ms, START_PAUSE_AT_MS);
        assert_eq!(items[0].duration_ms, 8_000 - START_PAUSE_LEAD_MS);
        assert!(items[0].line.is_none());
        assert_eq!(items[1].time_ms, 8_000);
    }

    #[test]
    fn a_first_line_within_5s_gets_no_start_pause() {
        let items = build_timeline(vec![line(5_000, "a")], None);
        assert!(items[0].line.is_some());
    }

    #[test]
    fn outro_pause_is_appended_only_for_gaps_over_5s() {
        let mut first = line(0, "a");
        first.words = vec![word(0, 9_000)];
        // The text runs up to the start of the synthetic window's last second,
        // so no in-line pause follows and the last item stays a line.
        let items = build_timeline(vec![first], Some(20_000));
        assert_eq!(items.len(), 2);
        assert_eq!(items[1].time_ms, 9_000);
        assert_eq!(items[1].duration_ms, 11_000);
        assert!(items[1].line.is_none());

        let short = build_timeline(vec![line_with_words()], Some(13_000));
        assert_eq!(short.len(), 1, "a 4 s gap must not add an outro");
    }

    #[test]
    fn last_line_keeps_its_text_and_the_outro_counts_to_the_track_end() {
        // Regression: the synthetic last-line window used to push an in-line
        // pause, so the outro block never ran and the countdown stopped early.
        let items = build_timeline(vec![line(0, "a"), line(3_000, "b")], Some(60_000));
        assert_eq!(items.len(), 3);
        assert_eq!(items[2].time_ms, 7_000);
        assert_eq!(items[2].duration_ms, 53_000);
        assert!(items[2].line.is_none());
    }

    fn line_with_words() -> LyricsLineDto {
        let mut line = line(0, "a");
        line.words = vec![word(0, 9_000)];
        line
    }
}
