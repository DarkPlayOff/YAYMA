#[derive(Debug, Clone)]
pub enum Event {
    TrackEnded,
    Error(String),
}
