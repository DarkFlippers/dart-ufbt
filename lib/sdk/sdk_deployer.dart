import 'dart:io';

import 'package:archive/archive_io.dart';

import '../core/directory_swap.dart';
import '../core/ufbt_paths.dart';
import '../core/ufbt_state.dart';
import '../log/logger.dart';
import '../net/file_fetcher.dart';
import 'deploy_task.dart';
import 'file_type.dart';
import 'sdk_loader.dart';

class UfbtSdkDeployer {
  UfbtSdkDeployer({
    required this.logger,
    required this.paths,
    required this.fetcher,
  });

  final UfbtLogger logger;
  final UfbtPaths paths;
  final UfbtFileFetcher fetcher;

  SdkDeployTask? previousTask() {
    // Before trusting that a missing state file means nothing is installed:
    // between the swap's two renames the SDK, and the state file inside it,
    // are sitting under a set-aside name.
    DirectorySwap.recoverInterrupted(
      paths.currentSdkDir,
      onWarning: logger.warning,
    );
    if (!paths.stateFile.existsSync()) return null;
    final state = UfbtState.read(paths.stateFile)!;
    logger.debug('get_previous_task() loaded state: ${state.values}');
    return SdkDeployTask.fromState(state.values);
  }

  UfbtSdkLoader createLoader(SdkDeployTask task) {
    logger.debug('SdkLoaderFactory::create_for_task task=$task');
    switch (task.mode) {
      case BranchSdkLoader.loaderModeKey:
        return BranchSdkLoader(
          logger: logger,
          fetcher: fetcher,
          downloadDir: paths.downloadDir,
          branch: task.params['branch']!,
          branchRootUrl: task.params['branch_root'],
        );
      case UpdateChannelSdkLoader.loaderModeKey:
        return UpdateChannelSdkLoader(
          logger: logger,
          fetcher: fetcher,
          downloadDir: paths.downloadDir,
          channel: UfbtUpdateChannel.byKey(task.params['channel']!),
          jsonIndexUrl: task.params['json_index'],
        );
      case UrlSdkLoader.loaderModeKey:
        return UrlSdkLoader(
          logger: logger,
          fetcher: fetcher,
          downloadDir: paths.downloadDir,
          url: task.params['url']!,
        );
      case LocalSdkLoader.loaderModeKey:
        return LocalSdkLoader(
          logger: logger,
          fetcher: fetcher,
          downloadDir: paths.downloadDir,
          filePath: task.params['file_path']!,
        );
      default:
        throw UfbtValueError('Invalid mode: ${task.mode}');
    }
  }

  Future<bool> deploy(SdkDeployTask task) async {
    logger.info('Deploying SDK for ${task.hwTarget}');

    final loader = createLoader(task);
    await loader.load();

    final sdkTargetDir = paths.currentSdkDir;
    logger.info('uFBT SDK dir: ${sdkTargetDir.path}');

    // Ahead of the up-to-date check below, which reads the SDK's absence as
    // "nothing installed" - and an interrupted swap looks exactly like that.
    DirectorySwap.recoverInterrupted(sdkTargetDir, onWarning: logger.warning);

    if (!task.force && sdkTargetDir.existsSync()) {
      final state = UfbtState.read(paths.stateFile);
      if (state == null) {
        throw PathNotFoundException(
          paths.stateFile.path,
          const OSError('No such file or directory', 2),
        );
      }
      if (UfbtSdkLoader.alwaysUpdateVersions.contains(state.version)) {
        logger.info('Cannot determine current SDK version, updating');
      } else if (state.version == loader.metadata['version'] &&
          state.hwTarget == task.hwTarget) {
        logger.info('SDK is up-to-date');
        return true;
      }
    }

    final File sdkComponent;
    try {
      sdkComponent = await loader.getSdkComponent(task.hwTarget ?? '');
    } catch (e) {
      logger.error('Failed to fetch SDK for ${task.hwTarget}: $e');
      return false;
    }

    final state = UfbtState({'hw_target': task.hwTarget, ...loader.metadata});

    logger.info('Deploying SDK');
    // Built beside the installed SDK rather than over it, so a download that
    // unpacks badly costs nothing: what is there keeps working until there is
    // a complete replacement to put in its place.
    final incoming = DirectorySwap.staging(sdkTargetDir);
    // Awaited rather than deleteSync, like the swap below: a staging tree
    // left by an interrupted run is a whole SDK, and this runs on the
    // isolate drawing the progress the extract is about to report.
    if (incoming.existsSync()) await incoming.delete(recursive: true);
    await _extractZip(sdkComponent, incoming);

    // Into the staging tree, because the state file lives inside the SDK
    // directory. Writing it there means the swap commits the SDK and the
    // state that describes it in one move - where before, dying between the
    // extract and the write left an SDK whose missing state file deploy()
    // then threw on.
    state.write(File(UfbtPaths.join(incoming.path, UfbtPaths.stateFileName)));
    await DirectorySwap.swapIn(
      sdkTargetDir,
      incoming,
      onWarning: logger.warning,
    );
    logger.info('SDK deployed.');
    return true;
  }

  Future<void> _extractZip(File archiveFile, Directory targetDir) async {
    targetDir.createSync(recursive: true);

    final input = InputFileStream(archiveFile.path);
    final archive = ZipDecoder().decodeStream(input);
    final task = logger.progress('', total: archive.length);

    var done = 0;
    try {
      for (final entry in archive) {
        final entryPath = _safeEntryPath(targetDir, entry.name);
        if (entryPath != null) {
          if (entry.isFile) {
            final output = OutputFileStream(entryPath);
            entry.writeContent(output);
            await output.close();
          } else {
            Directory(entryPath).createSync(recursive: true);
          }
        }
        task.update(current: ++done);
        await Future<void>.delayed(Duration.zero);
      }
    } catch (e) {
      task.fail(message: '$e');
      rethrow;
    } finally {
      await input.close();
    }
    task.finish();
  }

  static String? _safeEntryPath(Directory targetDir, String name) {
    final parts = name.split(RegExp(r'[/\\]'));
    if (parts.any((part) => part == '..' || part == '.')) return null;
    final clean = parts.where((part) => part.isNotEmpty).toList();
    if (clean.isEmpty) return null;
    return [targetDir.path, ...clean].join(Platform.pathSeparator);
  }
}
