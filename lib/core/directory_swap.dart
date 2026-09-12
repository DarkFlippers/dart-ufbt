import 'dart:io';

/// Replaces a directory tree only once its replacement is complete.
///
/// The shape both deployers need. Extracting over the live tree — or deleting
/// it first and extracting into the space — means anything that goes wrong
/// afterwards leaves the user with neither the old copy nor a working new one,
/// and for the SDK and the toolchain that is a several-hundred-megabyte
/// download to get back to where they started.
///
/// So the new tree is built beside the target and moved into place at the end.
/// Everything here is synchronous, matching the deployers around it.
class DirectorySwap {
  /// Where a replacement is assembled before it is committed.
  static const String incomingSuffix = '.incoming';

  /// Prefix of a tree that has been replaced and is waiting to be removed.
  static const String supersededPrefix = '.superseded';

  /// The staging tree for [target]: beside it, never inside it.
  ///
  /// Beside matters. Staging in the system temp directory reads as tidier and
  /// is the obvious thing to reach for, but it can land on a different mount,
  /// and dart:io's rename does not copy across filesystems — it fails EXDEV
  /// outright. Staging stays on the volume it is going to land on.
  static Directory staging(Directory target) =>
      Directory('${target.path}$incomingSuffix');

  /// Puts [incoming] in place of [target], and removes what it replaced.
  ///
  /// Two renames rather than the one this reads like it should need: no
  /// platform will rename a directory onto a populated one. Windows throws
  /// `PathExistsException` — for an empty destination as well — and POSIX
  /// `rename(2)` replaces only an empty directory, failing `ENOTEMPTY`
  /// otherwise, which is exactly the state a deployed tree is in. So the old
  /// tree is moved aside first, under a name carrying the moment it was set
  /// aside: one shared name would make the tree being deleted and the
  /// destination of the next swap the same path, and a delete that stopped
  /// part way — one locked file is enough — would then wedge every later
  /// deploy against something it could not rename onto.
  ///
  /// Between the two renames there is no tree at [target]. That window is two
  /// metadata operations wide, and it is the one state that loses data, so a
  /// failed second rename puts the old tree back and [recoverInterrupted]
  /// repairs a process that died inside it.
  static void swapIn(
    Directory target,
    Directory incoming, {
    void Function(String message)? onWarning,
  }) {
    final superseded = Directory(
      '${target.path}$supersededPrefix'
      '.${DateTime.now().microsecondsSinceEpoch}',
    );

    final replacing = target.existsSync();
    if (replacing) target.renameSync(superseded.path);
    try {
      incoming.renameSync(target.path);
    } catch (_) {
      if (replacing && !target.existsSync()) {
        try {
          superseded.renameSync(target.path);
        } catch (e) {
          onWarning?.call('could not put ${target.path} back: $e');
        }
      }
      rethrow;
    }

    if (!replacing) return;
    try {
      superseded.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      // Costs disk, not correctness. The tree is named for this swap, so a
      // leftover is something the next recovery sweeps up rather than
      // something the next deploy collides with.
      onWarning?.call('could not remove ${superseded.path}: $e');
    }
  }

  /// Removes [target] along with anything staged or set aside beside it.
  ///
  /// Sidecars first and the target last, which is not interchangeable: the
  /// other order leaves the target absent while an aside tree still stands,
  /// and that is exactly the state [recoverInterrupted] reads as an
  /// interrupted swap. A removal stopped part way through would then be undone
  /// by the next deploy, handing back what the user asked to be rid of.
  static void removeAll(Directory target) {
    for (final tree in [staging(target), ..._supersededTrees(target), target]) {
      if (!tree.existsSync()) continue;
      try {
        tree.deleteSync(recursive: true);
      } on PathNotFoundException {
        continue;
      }
    }
  }

  /// Repairs whatever a process that died mid-swap left beside [target].
  ///
  /// Call before starting a deploy, and before trusting that [target] being
  /// absent means nothing was ever installed.
  static void recoverInterrupted(
    Directory target, {
    void Function(String message)? onWarning,
  }) {
    // Newest first: that one is what the interrupted swap set aside, and
    // anything older is a delete that never finished.
    final aside = _supersededTrees(target);

    Directory? keep;
    if (!target.existsSync() && aside.isNotEmpty) {
      try {
        aside.first.renameSync(target.path);
      } catch (e) {
        // It holds the only copy there is, which is the whole reason the
        // restore was being attempted. Leaving it costs disk and the next run
        // tries again; removing it is the one thing this must never do — and a
        // failed recursive delete is not a no-op either, since one locked file
        // stops it having already removed what it reached first.
        keep = aside.first;
        onWarning?.call('could not put ${target.path} back: $e');
      }
    }

    // A restore consumes the tree it moved, so that one is already gone.
    for (final leftover in [staging(target), ...aside]) {
      if (leftover.path == keep?.path || !leftover.existsSync()) continue;
      try {
        leftover.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        onWarning?.call('could not remove ${leftover.path}: $e');
      }
    }
  }

  /// Every superseded tree beside [target], newest first.
  static List<Directory> _supersededTrees(Directory target) {
    final parent = target.parent;
    if (!parent.existsSync()) return const [];
    final prefix = '${_name(target.path)}$supersededPrefix';
    final found = parent
        .listSync(followLinks: false)
        .whereType<Directory>()
        .where((d) => _name(d.path).startsWith(prefix))
        .toList();
    found.sort((a, b) => b.path.compareTo(a.path));
    return found;
  }

  static String _name(String path) => path.split(Platform.pathSeparator).last;
}
