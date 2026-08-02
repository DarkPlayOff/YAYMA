use crate::lyrics::{ParsedLine, ParsedWord};
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;

#[derive(Debug, Clone)]
struct SpanInfo {
    text: String,
    start: f64,
    end: f64,
    trailing_space: bool,
}

struct SpanFrame {
    role: Option<String>,
    begin: Option<String>,
    end: Option<String>,
    text: String,
    spans: Vec<SpanInfo>,
}

struct PFrame {
    begin: String,
    main_spans: Vec<SpanInfo>,
    bg_lines: Vec<ParsedLine>,
}

fn get_attr(e: &BytesStart, name: &str) -> Option<String> {
    for attr in e.attributes().flatten() {
        let key = String::from_utf8_lossy(attr.key.as_ref()).to_string();
        if key == name || key.ends_with(&format!(":{name}")) {
            return attr.unescape_value().ok().map(|v| v.to_string());
        }
    }
    None
}

fn local_name(e: &BytesStart) -> String {
    String::from_utf8_lossy(e.name().local_name().as_ref()).to_lowercase()
}

fn parse_time(time_str: &str) -> f64 {
    if time_str.contains(':') {
        let parts: Vec<&str> = time_str.split(':').collect();
        match parts.len() {
            2 => {
                let minutes: f64 = parts[0].parse().unwrap_or(0.0);
                let seconds: f64 = parts[1].parse().unwrap_or(0.0);
                minutes * 60.0 + seconds
            }
            3 => {
                let hours: f64 = parts[0].parse().unwrap_or(0.0);
                let minutes: f64 = parts[1].parse().unwrap_or(0.0);
                let seconds: f64 = parts[2].parse().unwrap_or(0.0);
                hours * 3600.0 + minutes * 60.0 + seconds
            }
            _ => time_str.parse().unwrap_or(0.0),
        }
    } else {
        time_str.trim_end_matches('s').parse().unwrap_or(0.0)
    }
}

fn merge_spans_into_words(span_infos: &[SpanInfo]) -> Vec<ParsedWord> {
    let mut words = Vec::new();
    if span_infos.is_empty() {
        return words;
    }

    let flush = |words: &mut Vec<ParsedWord>, text: &str, start: f64, end: f64| {
        if !text.is_empty() {
            words.push(ParsedWord {
                text: text.trim().to_string(),
                start,
                end,
            });
        }
    };

    let mut current_text = span_infos[0].text.clone();
    let mut current_start = span_infos[0].start;
    let mut current_end = span_infos[0].end;

    for (prev, span) in span_infos.iter().zip(span_infos.iter().skip(1)) {
        if prev.trailing_space {
            flush(&mut words, &current_text, current_start, current_end);
            current_text = span.text.clone();
            current_start = span.start;
            current_end = span.end;
        } else {
            current_text.push_str(&span.text);
            current_end = span.end;
        }
    }

    flush(&mut words, &current_text, current_start, current_end);

    words
}

fn finish_span(frame: SpanFrame) -> Option<SpanInfo> {
    let role = frame.role.as_deref();
    if role == Some("x-translation") || role == Some("x-roman") {
        return None;
    }
    let text = frame.text.trim().to_string();
    let (Some(begin), Some(end)) = (frame.begin, frame.end) else {
        return None;
    };
    if text.is_empty() {
        return None;
    }
    Some(SpanInfo {
        text,
        start: parse_time(&begin),
        end: parse_time(&end),
        trailing_space: false,
    })
}

fn finish_bg_span(frame: SpanFrame, parent_start: f64) -> Option<ParsedLine> {
    let words = merge_spans_into_words(&frame.spans);
    let line_text = words
        .iter()
        .map(|w| w.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let final_text = if line_text.is_empty() {
        frame.text.trim().to_string()
    } else {
        line_text
    };
    if final_text.is_empty() {
        return None;
    }
    let start = frame
        .begin
        .as_deref()
        .map(parse_time)
        .unwrap_or(parent_start);
    Some(ParsedLine { start, text: final_text, words })
}

pub fn parse_ttml(ttml: &str) -> Vec<ParsedLine> {
    let mut reader = Reader::from_str(ttml);
    reader.config_mut().trim_text(false);

    let mut lines = Vec::new();
    let mut p_frame: Option<PFrame> = None;
    let mut span_stack: Vec<SpanFrame> = Vec::new();
    let mut buf = Vec::new();
    // Whether the last thing closed at the current nesting level was a span
    // (used to detect a trailing whitespace text node = word boundary).
    let mut just_closed_span = false;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Eof) => break,
            Err(_) => break,
            Ok(Event::Start(e)) => {
                let name = local_name(&e);
                if name == "p" {
                    let begin = get_attr(&e, "begin").unwrap_or_default();
                    if begin.is_empty() {
                        p_frame = None;
                    } else {
                        p_frame = Some(PFrame {
                            begin,
                            main_spans: Vec::new(),
                            bg_lines: Vec::new(),
                        });
                    }
                } else if name == "span" {
                    span_stack.push(SpanFrame {
                        role: get_attr(&e, "role"),
                        begin: get_attr(&e, "begin"),
                        end: get_attr(&e, "end"),
                        text: String::new(),
                        spans: Vec::new(),
                    });
                }
                just_closed_span = false;
            }
            Ok(Event::Empty(e)) => {
                let name = local_name(&e);
                if name == "span" {
                    let frame = SpanFrame {
                        role: get_attr(&e, "role"),
                        begin: get_attr(&e, "begin"),
                        end: get_attr(&e, "end"),
                        text: String::new(),
                        spans: Vec::new(),
                    };
                    close_span(frame, &mut span_stack, &mut p_frame);
                    just_closed_span = true;
                    continue;
                }
                just_closed_span = false;
            }
            Ok(Event::Text(t)) => {
                let text = t.decode().unwrap_or_default().to_string();
                if let Some(frame) = span_stack.last_mut() {
                    frame.text.push_str(&text);
                } else if just_closed_span && text.chars().any(|c| c.is_whitespace()) {
                    // Mark the last-closed sibling span as having a trailing
                    // space, so word-merging treats the next span as a new word.
                    if let Some(parent) = span_stack.last_mut() {
                        if let Some(last) = parent.spans.last_mut() {
                            last.trailing_space = true;
                        }
                    } else if let Some(p) = p_frame.as_mut() {
                        if let Some(last) = p.main_spans.last_mut() {
                            last.trailing_space = true;
                        }
                    }
                }
            }
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.name().local_name().as_ref()).to_lowercase();
                if name == "span" {
                    if let Some(frame) = span_stack.pop() {
                        close_span(frame, &mut span_stack, &mut p_frame);
                    }
                    just_closed_span = true;
                    buf.clear();
                    continue;
                } else if name == "p" {
                    if let Some(frame) = p_frame.take() {
                        let start = parse_time(&frame.begin);
                        let words = merge_spans_into_words(&frame.main_spans);
                        let line_text = words
                            .iter()
                            .map(|w| w.text.as_str())
                            .collect::<Vec<_>>()
                            .join(" ");
                        if !line_text.is_empty() {
                            lines.push(ParsedLine { start, text: line_text, words });
                            lines.extend(frame.bg_lines);
                        }
                    }
                }
                just_closed_span = false;
            }
            _ => {}
        }
        buf.clear();
    }

    lines
}

fn close_span(frame: SpanFrame, span_stack: &mut [SpanFrame], p_frame: &mut Option<PFrame>) {
    let role = frame.role.clone();
    if role.as_deref() == Some("x-bg") {
        let parent_start = p_frame
            .as_ref()
            .map(|p| parse_time(&p.begin))
            .unwrap_or(0.0);
        if let Some(bg_line) = finish_bg_span(frame, parent_start) {
            if let Some(p) = p_frame.as_mut() {
                p.bg_lines.push(bg_line);
            }
        }
        return;
    }

    let Some(span_info) = finish_span(frame) else {
        return;
    };

    if let Some(parent) = span_stack.last_mut() {
        parent.spans.push(span_info);
    } else if let Some(p) = p_frame.as_mut() {
        p.main_spans.push(span_info);
    }
}

