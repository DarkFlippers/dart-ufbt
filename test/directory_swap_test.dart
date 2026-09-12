import 'dart:io';

import 'package:dartufbt/core/directory_swap.dart';
import 'package:test/test.dart';

final String sep = Platform.pathSeparator;

/// A tree with one marker file, so which tree ended up where is visible.
Directory treeAt(Directory dir, String marker) {
  dir.createSync(recursive: true);
  Directory('${dir.path}${sep}bin').createSync(recursive: true);
  File('${dir.path}${sep}bin${sep}arm-gcc').writeAsStringSync(marker);
  return dir;
}

String markerIn(Directory dir) =>
    File('${dir.path}${sep}bin${sep}arm-gcc').readAsStringSync();

void main() {
  late Directory base;
  late Directory target;
  late Directory incoming;

  setUp(() {
    base = Directory.systemTemp.createTempSync('dartufbt_swap');
    target = Directory('${base.path}${sep}current');
    incoming = DirectorySwap.staging(target);
  });

  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  /// Each swap names its own, so tests look them up rather than assume one.
  List<Directory> superseded() => base
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.startsWith('${target.path}.superseded'))
      .toList();

  group('swapping a new tree in', () {
    test('the new tree replaces the old one', () {
      treeAt(target, 'old sdk');
      treeAt(incoming, 'new sdk');

      DirectorySwap.swapIn(target, incoming);

      expect(markerIn(target), 'new sdk');
      expect(incoming.existsSync(), isFalse);
      expect(superseded(), isEmpty, reason: 'the replaced tree is removed');
    });

    test('works when nothing was installed', () {
      treeAt(incoming, 'new sdk');

      DirectorySwap.swapIn(target, incoming);

      expect(markerIn(target), 'new sdk');
    });

    // The wedge the shared name caused: the tree being deleted and the
    // destination of the next swap were the same path, so a delete that
    // stopped part way through blocked every later deploy.
    test('a leftover at the old shared name does not block the swap', () {
      treeAt(target, 'old sdk');
      treeAt(incoming, 'new sdk');
      final stale = treeAt(
        Directory('${target.path}.superseded'),
        'wedged an earlier run',
      );

      DirectorySwap.swapIn(target, incoming);

      expect(markerIn(target), 'new sdk');
      expect(stale.existsSync(), isTrue, reason: 'swept later, not collided');
    });

    test('the installed tree is put back if the new one cannot move in', () {
      treeAt(target, 'old sdk');

      expect(
        () => DirectorySwap.swapIn(target, incoming),
        throwsA(isA<FileSystemException>()),
      );

      expect(markerIn(target), 'old sdk', reason: 'not left with nothing');
    });
  });

  group('recovering an interrupted deploy', () {
    test('an extract that never finished is cleared', () {
      treeAt(target, 'installed');
      treeAt(incoming, 'half extracted');

      DirectorySwap.recoverInterrupted(target);

      expect(incoming.existsSync(), isFalse);
      expect(markerIn(target), 'installed');
    });

    // The one window that loses data: the installed tree has been moved aside
    // and its replacement never landed.
    test('a deploy that died between the two renames puts the tree back', () {
      treeAt(Directory('${target.path}.superseded.1000'), 'installed');

      DirectorySwap.recoverInterrupted(target);

      expect(markerIn(target), 'installed');
      expect(superseded(), isEmpty);
    });

    test('the newest aside tree is the one put back', () {
      treeAt(Directory('${target.path}.superseded.1000'), 'older');
      treeAt(Directory('${target.path}.superseded.2000'), 'the live one');

      DirectorySwap.recoverInterrupted(target);

      expect(markerIn(target), 'the live one');
      expect(superseded(), isEmpty);
    });

    test('a delete that never finished is cleared, the tree left alone', () {
      treeAt(target, 'installed');
      treeAt(Directory('${target.path}.superseded.1000'), 'stale');

      DirectorySwap.recoverInterrupted(target);

      expect(markerIn(target), 'installed');
      expect(superseded(), isEmpty);
    });

    // A restore that cannot land leaves that tree holding the only copy there
    // is. Clearing it then would turn a recoverable interruption into the loss
    // recovery exists to prevent.
    test('a tree that cannot be put back is kept, not cleared', () {
      final aside = treeAt(
        Directory('${target.path}.superseded.1000'),
        'the only copy',
      );
      File(target.path).writeAsStringSync('in the way');
      final warnings = <String>[];

      DirectorySwap.recoverInterrupted(target, onWarning: warnings.add);

      expect(aside.existsSync(), isTrue);
      expect(markerIn(aside), 'the only copy');
      expect(warnings, isNotEmpty, reason: 'and it says so');
    });

    test('does nothing when there is nothing to repair', () {
      treeAt(target, 'installed');

      DirectorySwap.recoverInterrupted(target);

      expect(markerIn(target), 'installed');
    });

    test('is safe when nothing is installed at all', () {
      DirectorySwap.recoverInterrupted(target);

      expect(target.existsSync(), isFalse);
    });
  });
}
