import 'dart:convert';
import 'dart:io';

import '../log/logger.dart';

class UfbtHttpException implements Exception {
  const UfbtHttpException(this.statusCode, this.reasonPhrase);

  final int statusCode;
  final String reasonPhrase;

  @override
  String toString() => 'HTTP Error $statusCode: $reasonPhrase';
}

class UfbtFileFetcher {
  UfbtFileFetcher({required this.logger, HttpClient? client})
    : _client = client ?? HttpClient();

  static const String userAgent = 'uFBT SDKLoader/0.2';

  final UfbtLogger logger;
  final HttpClient _client;

  void close() => _client.close(force: true);

  Future<String> readAsString(String url) async {
    final response = await _open(url);
    return response.transform(utf8.decoder).join();
  }

  Future<File> fetchFile(
    String url,
    Directory downloadDir, {
    String progressTitle = '',
    bool usePartFile = false,
  }) async {
    logger.debug('Fetching $url');

    final fileName = _fileNameFromUrl(url);
    downloadDir.createSync(recursive: true);

    final target = File(
      '${downloadDir.path}${Platform.pathSeparator}$fileName',
    );
    final sink = usePartFile ? File('${target.path}.part') : target;

    final response = await _open(url);
    final total = response.contentLength;
    final task = logger.progress(
      progressTitle,
      total: total > 0 ? total : null,
    );

    final output = sink.openWrite();
    var readAnyChunk = false;
    try {
      // **`addStream`, not `add` in a loop over the response.** `add` returns
      // nothing, so the write side has no answer to hand it: dart:io reports
      // the failure by completing the sink's `done` instead - which it does
      // only while nothing is bound to the sink, and an `add` loop never is.
      // Nothing here listened to `done`, so a full disk reached the caller's
      // zone as an uncaught asynchronous error, and the loop carried on
      // feeding a sink whose reader dart:io had already cancelled: an `add`
      // after that cancel neither throws nor delivers. `flush()` then waited
      // on a completer the same error path had abandoned, so the call never
      // returned either. Measured against a chunked body: five silent adds,
      // one uncaught error, no completion.
      //
      // `addStream` binds, so the consumer's error comes back on the future
      // it returns - awaited here, so the same disk reaches the `catch` below
      // and from there the caller. Sentry QUNLEASHED-2E.
      await output.addStream(
        response.map((chunk) {
          readAnyChunk = true;
          // `advance` rather than a count of our own: [UfbtProgressTask]
          // keeps the running total, and assigns it before the throttle
          // decides whether to emit, so it is accurate whether or not this
          // chunk produces an event.
          task.advance(chunk.length);
          return chunk;
        }),
      );
      await output.close();
      // Inside the `try`, because a rename is a filesystem call like the
      // writes before it - a target a virus scanner still holds open is
      // enough to fail it. Outside, it threw past a task that had already
      // reported `finished`, which [UfbtProgressTask] then refuses to move
      // off, and past the cleanup below, so the partial file stayed.
      if (usePartFile) {
        if (target.existsSync()) target.deleteSync();
        sink.renameSync(target.path);
      }
    } catch (e) {
      // **The response, when nothing ever read it.** dart:io subscribes to
      // the source only once the file is open, so a target that cannot be
      // opened leaves the response with no listener at all and its socket
      // never released. Cancelled rather than drained: on a disk that filled
      // part way through an SDK zip, draining would pull the rest of it over
      // the wire for nothing.
      //
      // [readAnyChunk] is also false for a body that failed before its
      // first chunk - which dart:io did subscribe to and did tear down, so
      // the `listen` throws for a stream already listened to and there is
      // nothing to release anyway.
      try {
        if (!readAnyChunk) await response.listen(null).cancel();
      } catch (releaseError) {
        logger.debug('Could not release the response for $url: $releaseError');
      }
      // Closed to leave `done` observed, not to release a handle: on every
      // path that reaches here dart:io has closed the file it opened or never
      // opened one. So this is certain to throw - the open's own error when
      // the open was what failed, `File closed` otherwise - and unguarded it
      // would replace the error being reported and skip the two steps after
      // it.
      try {
        await output.close();
      } catch (closeError) {
        logger.debug('Could not close ${sink.path}: $closeError');
      }
      // **The partial file goes**, whichever side failed: a truncated body
      // and a truncated write leave the same unusable prefix, and nothing
      // resumes a download - `usePartFile` is about not leaving a half file
      // under the name a reader expects, not about continuing one. It matters
      // most on the failure this was written for, where that prefix is what
      // the disk is full of.
      try {
        if (sink.existsSync()) sink.deleteSync();
      } catch (deleteError) {
        // `warning`, not `debug` like the two steps above it: those are
        // handle hygiene, while a prefix that survives is the input to the
        // next run. Under the real name it is worse than noise - the
        // toolchain deployer gates its download on `archiveFile.existsSync()`
        // and would hand a truncated archive to the unpacker. The same event
        // is a warning in `DirectorySwap`.
        logger.warning('Could not remove ${sink.path}: $deleteError');
      }
      task.fail(message: '$e');
      rethrow;
    }
    task.finish();
    return target;
  }

  Future<HttpClientResponse> _open(String url) async {
    final request = await _client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw UfbtHttpException(response.statusCode, response.reasonPhrase);
    }
    return response;
  }

  static String _fileNameFromUrl(String url) {
    final segments = Uri.parse(url).pathSegments;
    return segments.isEmpty ? '' : Uri.decodeComponent(segments.last);
  }
}
