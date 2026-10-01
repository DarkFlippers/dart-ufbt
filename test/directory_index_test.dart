import 'package:dartufbt/sdk/directory_index.dart';
import 'package:dartufbt/sdk/file_type.dart';
import 'package:test/test.dart';

/// Reading `directory.json`, which this package does not produce.
///
/// The same document is read by a second decoder in a second repository, and
/// a cast here turned any field whose type changed into a decode failure for
/// the whole file - which loses every channel, not one entry. The producer is
/// nobody's to pin, so the reader answers absence and a type change the same
/// way. qUnleashed#137.
Map<String, dynamic> indexWith(Object? timestamp) => {
  'channels': [
    {
      'id': 'release',
      'title': 'Release',
      'versions': [
        {
          'version': '1.0.0',
          'timestamp': timestamp,
          'files': [
            {'url': 'https://x/f.tgz', 'target': 'f7', 'type': 'update_tgz'},
          ],
        },
      ],
    },
  ],
};

void main() {
  group('a timestamp that is not an int', () {
    // Both live feeds send an int today, so the cast worked - and a producer
    // that ever emits 1788532004.0 took every channel with it.
    test('does not cost the whole document', () {
      final index = UfbtDirectoryIndex.fromJson(indexWith(1788532004.0));

      expect(index.findChannel('release'), isNotNull);
    });

    test('is read as the whole number it is', () {
      final index = UfbtDirectoryIndex.fromJson(indexWith(1788532004.0));

      expect(
        index.findChannel('release')!.versions.single.timestamp,
        1788532004,
      );
    });

    test('is still read when it is an int', () {
      final index = UfbtDirectoryIndex.fromJson(indexWith(1788532004));

      expect(
        index.findChannel('release')!.versions.single.timestamp,
        1788532004,
      );
    });

    // Absence and nonsense answer the same way, which is what lets the
    // caller treat "no timestamp" as one case rather than two.
    test('is null when it is absent', () {
      final index = UfbtDirectoryIndex.fromJson(indexWith(null));

      expect(index.findChannel('release')!.versions.single.timestamp, isNull);
    });

    test('is null when it is a string', () {
      final index = UfbtDirectoryIndex.fromJson(indexWith('yesterday'));

      expect(index.findChannel('release')!.versions.single.timestamp, isNull);
    });
  });

  group('a text field that is not text', () {
    test('does not cost the whole document either', () {
      final index = UfbtDirectoryIndex.fromJson({
        'channels': [
          {'id': 42, 'versions': const []},
        ],
      });

      expect(index.channels, hasLength(1));
    });

    // An id that could not be read matches no channel, so the caller's own
    // "Invalid channel" is what the user is told - which is why reading it as
    // empty is safe rather than silent.
    test('leaves a channel nobody can find', () {
      final index = UfbtDirectoryIndex.fromJson({
        'channels': [
          {'id': 42, 'versions': const []},
        ],
      });

      expect(index.findChannel('42'), isNull);
      expect(index.channels.single.id, isEmpty);
    });

    test('does not stop the files of a good entry being read', () {
      final index = UfbtDirectoryIndex.fromJson({
        'channels': [
          {
            'id': 'release',
            'title': 7,
            'versions': [
              {
                'version': '1.0.0',
                'files': [
                  {
                    'url': 'https://x/f.tgz',
                    'target': 'f7',
                    'type': 'update_tgz',
                    'sha256': 9000,
                  },
                ],
              },
            ],
          },
        ],
      });

      final file = index
          .findChannel('release')!
          .versions
          .single
          .findFile(UfbtFileType.updateTgz, 'f7');
      expect(file, isNotNull);
      expect(file!.sha256, isNull, reason: 'unreadable, so absent');
      expect(index.channels.single.title, isNull);
    });
  });
}
