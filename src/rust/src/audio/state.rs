use crate::audio::liked::LikedCache;

#[derive(Debug, Clone, Default)]
pub struct SystemState {
    pub liked: LikedCache,
}
