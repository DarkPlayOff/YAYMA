/// Bare track id.
///
/// Queue and playlist items may carry a source suffix (`id:albumId`), while
/// the like/dislike APIs and the liked caches key on the id alone.
String baseTrackId(String trackId) => trackId.split(':').first;
