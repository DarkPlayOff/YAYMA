import 'package:flutter_test/flutter_test.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';

void main() {
  test('logout drops cached playlist membership', () async {
    // Playlist kinds are per account, so a stale entry would mark a track as
    // already added to another account's playlist with the same kind.
    trackPlaylistMembershipSignal.value = {
      'track-1': {1000},
      'track-2': {1001},
    };

    await disposeLibrary();

    expect(trackPlaylistMembershipSignal.value, isEmpty);
  });
}
