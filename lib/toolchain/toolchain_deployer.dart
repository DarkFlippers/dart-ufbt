import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

import '../core/directory_swap.dart';
import '../core/ufbt_paths.dart';
import '../log/logger.dart';
import '../net/file_fetcher.dart';

class UfbtToolchainInfo {
  const UfbtToolchainInfo({
    required this.archDir,
    required this.version,
    required this.url,
    required this.installedVersion,
    required this.isDeployed,
  });

  final String archDir;
  final String version;
  final String url;
  final String? installedVersion;
  final bool isDeployed;

  bool get isUpToDate => isDeployed && installedVersion == version;
}

class UfbtToolchainDeployer {
  UfbtToolchainDeployer({
    required this.logger,
    required this.paths,
    required this.fetcher,
  });

  static const String fallbackVersion = '39';
  static const String urlRoot =
      'https://update.flipperzero.one/builds/toolchain';

  final UfbtLogger logger;
  final UfbtPaths paths;
  final UfbtFileFetcher fetcher;

  String get archDirName => UfbtPaths.hostArchDir;

  String get toolchainVersion {
    final override = Platform.environment['FBT_TOOLCHAIN_VERSION'];
    if (override != null && override.isNotEmpty) return override;

    final script = Platform.isWindows ? paths.fbtenvCmd : paths.fbtenvScript;
    if (script.existsSync()) {
      final pattern = Platform.isWindows
          ? RegExp(r'FLIPPER_TOOLCHAIN_VERSION=(\d+)')
          : RegExp(r'FBT_TOOLCHAIN_VERSION=[^\n]*?"(\d+)"');
      final match = pattern.firstMatch(script.readAsStringSync());
      if (match != null) return match.group(1)!;
    }
    return fallbackVersion;
  }

  String toolchainUrl(String version) {
    final suffix = Platform.isWindows ? 'zip' : 'tar.gz';
    return '$urlRoot/gcc-arm-none-eabi-12.3-$archDirName-flipper-$version'
        '.$suffix';
  }

  Directory get _archiveDir =>
      Platform.isWindows ? paths.currentSdkDir : paths.toolchainDir;

  UfbtToolchainInfo status() {
    final version = toolchainVersion;
    final archDir = paths.toolchainArchDir(archDirName);
    final versionFile = File(UfbtPaths.join(archDir.path, 'VERSION'));
    return UfbtToolchainInfo(
      archDir: archDir.path,
      version: version,
      url: toolchainUrl(version),
      installedVersion: versionFile.existsSync()
          ? versionFile.readAsStringSync().trim()
          : null,
      isDeployed: archDir.existsSync(),
    );
  }

  Future<bool> deploy({bool force = false}) async {
    final info = status();

    if (!force && info.isDeployed && info.installedVersion != null) {
      if (info.isUpToDate) return true;
      if (!Platform.isWindows) {
        logger.raw('FBT: starting toolchain upgrade process..');
      }
    }

    return Platform.isWindows ? _deployWindows(info) : _deployUnix(info);
  }

  Future<bool> _deployUnix(UfbtToolchainInfo info) async {
    if (!await _checkTar()) return false;

    final archiveName = info.url.split('/').last;
    final distDirName = archiveName.replaceAll('-${info.version}.tar.gz', '');
    final archiveFile = File(UfbtPaths.join(_archiveDir.path, archiveName));

    logger.raw('Checking if downloaded toolchain tgz exists..', newline: false);
    if (archiveFile.existsSync()) {
      logger.raw('yes');
    } else {
      logger.raw('no');
      logger.raw('Downloading toolchain:');
      try {
        await fetcher.fetchFile(info.url, _archiveDir, usePartFile: true);
      } catch (_) {
        logger.raw('Failed to download ${info.url}');
        return false;
      }
      logger.raw('done');
    }

    final archDir = Directory(info.archDir);
    DirectorySwap.recoverInterrupted(archDir, onWarning: logger.warning);

    logger.raw("Unpacking toolchain to '${paths.toolchainDir.path}':");
    paths.toolchainDir.createSync(recursive: true);
    if (!await _unpackTar(archiveFile)) return false;

    final distDir = Directory(
      UfbtPaths.join(paths.toolchainDir.path, distDirName),
    );
    if (!distDir.existsSync()) return false;
    // Renamed onto the staging name before the swap, so that a run which dies
    // here leaves something recoverInterrupted sweeps. Left under its own
    // name, an unpacked tree of ~1GB is orphaned for good - and since the dist
    // name carries no version, the next unpack would tar into it and merge the
    // previous toolchain's binaries into the new one.
    final staging = DirectorySwap.staging(archDir);
    if (staging.existsSync()) await staging.delete(recursive: true);
    distDir.renameSync(staging.path);

    // Swapped in rather than moved into a hole cleared earlier: the installed
    // toolchain stays whole until the unpack has produced a complete one, so
    // an unpack that fails no longer costs a toolchain that was working.
    await DirectorySwap.swapIn(archDir, staging, onWarning: logger.warning);

    // Unlinked here, not before the unpack. While the tree was deleted up
    // front, a failure in between left nothing for the link to point at; now
    // the tree survives, so dropping the link early would leave a toolchain
    // that status() reports as installed with nothing linking to it, and the
    // up-to-date early return would never repair it.
    final currentLink = paths.toolchainCurrentLink;
    if (_linkExists(currentLink)) currentLink.deleteSync();

    logger.raw("linking toolchain to 'current'..", newline: false);
    logger.raw(await _linkCurrent(archDir) ? 'done' : 'skipped');

    _cleanup();
    return true;
  }

  Future<bool> _deployWindows(UfbtToolchainInfo info) async {
    final archiveName = info.url.split('/').last;
    final distDirName = archiveName.replaceAll('-${info.version}.zip', '');
    final archiveFile = File(UfbtPaths.join(_archiveDir.path, archiveName));
    final archDir = Directory(info.archDir);
    DirectorySwap.recoverInterrupted(archDir, onWarning: logger.warning);

    if (!archiveFile.existsSync()) {
      logger.raw('Downloading Windows toolchain..', newline: false);
      try {
        await fetcher.fetchFile(info.url, _archiveDir);
      } catch (e) {
        logger.raw('An error occurred');
        logger.raw('$e');
        return false;
      }
      logger.raw('done!');
    }

    paths.toolchainDir.createSync(recursive: true);

    final distDir = Directory(UfbtPaths.join(_archiveDir.path, distDirName));
    if (distDir.existsSync()) {
      logger.raw('Cleaning up temp toolchain path..');
      await distDir.delete(recursive: true);
    }

    logger.raw('Extracting Windows toolchain..', newline: false);
    if (!await _unpackZip(archiveFile)) return false;

    logger.raw('moving..', newline: false);
    if (!distDir.existsSync()) return false;
    // Onto the staging name first, so an interrupted run leaves something
    // recoverInterrupted knows to sweep. It also brings the tree alongside the
    // toolchain before the swap, since the unpack lands it under the SDK
    // directory rather than beside its destination.
    final staging = DirectorySwap.staging(archDir);
    if (staging.existsSync()) await staging.delete(recursive: true);
    distDir.renameSync(staging.path);

    // Swapped in at the end rather than moved into a hole cleared before the
    // download: an installed toolchain now survives a download or an unpack
    // that fails.
    await DirectorySwap.swapIn(archDir, staging, onWarning: logger.warning);

    final currentLink = paths.toolchainCurrentLink;
    if (_linkExists(currentLink)) {
      logger.raw("Unlinking 'current'..", newline: false);
      currentLink.deleteSync();
      logger.raw('done!');
    }

    logger.raw("linking to 'current'..", newline: false);
    logger.raw(await _linkCurrent(archDir) ? 'done!' : 'skipped');

    logger.raw('Cleaning up temporary files..', newline: false);
    if (archiveFile.existsSync()) archiveFile.deleteSync();
    logger.raw('done!');
    return true;
  }

  /// Points 'current' at the deployed toolchain the way fbtenv does: a
  /// junction on Windows, where a symlink would need admin rights, a symlink
  /// elsewhere. An unlinked toolchain still builds from its arch dir, so a
  /// failure here only warns instead of failing the deploy.
  Future<bool> _linkCurrent(Directory archDir) async {
    final link = paths.toolchainCurrentLink;
    try {
      if (Platform.isWindows) {
        final result = await Process.run('cmd', [
          '/c',
          'mklink',
          '/J',
          link.path,
          archDir.path,
        ]);
        if (result.exitCode != 0) {
          throw ProcessException(
            'mklink',
            ['/J', link.path, archDir.path],
            '${result.stdout}${result.stderr}'.trim(),
            result.exitCode,
          );
        }
      } else {
        link.createSync(archDir.path);
      }
    } catch (e) {
      logger.warning(
        "Could not link '${link.path}': $e. "
        'The toolchain stays usable at ${archDir.path}.',
      );
      return false;
    }
    return true;
  }

  Future<bool> _checkTar() async {
    logger.raw('Checking for tar..', newline: false);
    try {
      final result = await Process.run('tar', ['--version']);
      if (result.exitCode != 0) {
        logger.raw('no');
        return false;
      }
    } catch (_) {
      logger.raw('no');
      return false;
    }
    logger.raw('yes');
    return true;
  }

  Future<bool> _unpackTar(File archiveFile) async {
    final task = logger.progress('');

    final process = await Process.start('tar', [
      '-xvf',
      archiveFile.path,
      '-C',
      paths.toolchainDir.path,
    ]);

    void count(Stream<List<int>> stream) {
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) => task.advance());
    }

    count(process.stdout);
    count(process.stderr);

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      task.fail(message: 'tar exited with $exitCode');
      return false;
    }
    task.finish();
    return true;
  }

  Future<bool> _unpackZip(File archiveFile) async {
    final task = logger.progress('');
    try {
      await extractFileToDisk(archiveFile.path, _archiveDir.path);
    } catch (e) {
      task.fail(message: '$e');
      return false;
    }
    task.finish();
    return true;
  }

  void _cleanup() {
    logger.raw('Cleaning up..', newline: false);
    final preserve = Platform.environment['FBT_PRESERVE_TAR'];
    if (paths.toolchainDir.existsSync()) {
      for (final entry in paths.toolchainDir.listSync()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (name.endsWith('.part')) {
          entry.deleteSync();
        } else if ((preserve == null || preserve.isEmpty) &&
            name.endsWith('.tar.gz')) {
          entry.deleteSync();
        }
      }
    }
    logger.raw('done');
  }

  static bool _linkExists(Link link) => link.existsSync();
}
