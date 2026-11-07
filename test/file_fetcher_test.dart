import 'dart:io';

import 'package:dartufbt/log/log_event.dart';
import 'package:dartufbt/log/logger.dart';
import 'package:dartufbt/log/progress.dart';
import 'package:dartufbt/net/file_fetcher.dart';
import 'package:test/test.dart';

final String sep = Platform.pathSeparator;

/// Long enough that the response arrives in more than one chunk, short enough
/// that a test waiting on it never has to wait.
final List<int> body = List<int>.generate(64 * 1024, (i) => i % 251);

/// How many pieces the server sends the body in, and how long it waits
/// between them.
///
/// **Load-bearing for 'rejects when the file cannot be opened'.** That failure
/// needs the write to fail while the fetcher is still waiting on the socket,
/// which is what a real download does: served in one piece, the fetcher's
/// loop is over before the first write has been attempted, dart:io can still
/// route the error, and the old code passed every test in this file. Measured
/// - at `bodyChunks = 1` and `chunkGap = Duration.zero` the pre-fix loop is
/// green here.
const int bodyChunks = 8;
const Duration chunkGap = Duration(milliseconds: 15);

/// A request whose path carries this gets a `Content-Length` the server never
/// fills, so the body ends mid-stream: a download that fails on the read side
/// after some of it has already been written.
const String truncatedMarker = 'truncated';

/// What the server sends before it hangs up on a [truncatedMarker] request.
const int truncatedBytes = 1024;

void main() {
  late Directory base;
  late HttpServer server;
  late UfbtLogger logger;
  late UfbtFileFetcher fetcher;
  late List<UfbtProgress> progress;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('dartufbt_fetch');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path.contains(truncatedMarker)) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n',
        );
        socket.add(body.sublist(0, truncatedBytes));
        await socket.flush();
        await socket.close();
        return;
      }
      request.response.contentLength = body.length;
      final step = body.length ~/ bodyChunks;
      for (var at = 0; at < body.length; at += step) {
        request.response.add(
          body.sublist(at, (at + step).clamp(0, body.length)),
        );
        await request.response.flush();
        await Future<void>.delayed(chunkGap);
      }
      await request.response.close();
    });

    logger = UfbtLogger();
    progress = [];
    logger.addSink((event) {
      if (event is UfbtProgressEvent) progress.add(event.progress);
    });
    fetcher = UfbtFileFetcher(logger: logger);
  });

  tearDown(() async {
    fetcher.close();
    await server.close(force: true);
    base.deleteSync(recursive: true);
  });

  String url(String name) =>
      'http://${server.address.address}:${server.port}/$name';

  test('writes what the server sent and reports it finished', () async {
    final file = await fetcher.fetchFile(url('sdk.zip'), base);

    expect(file.path, '${base.path}${sep}sdk.zip');
    expect(file.readAsBytesSync(), body);
    expect(progress.first.total, body.length);
    expect(progress.last.state, UfbtProgressState.finished);

    // **The byte count, which the terminal event cannot show.** `finish()`
    // reports `total` when there is one, so `progress.last.current` is the
    // content length whether or not a single byte was ever counted - and the
    // counting moved into a `map` over the response, which is exactly the
    // wrapper a later edit drops. A last `running` event carrying the whole
    // body is what says it survived: the throttle lets a full fraction
    // through whatever the interval, so that event always fires, while which
    // intermediate ones do is a matter of timing and not asserted.
    expect(
      progress
          .where((p) => p.state == UfbtProgressState.running)
          .map((p) => p.current),
      contains(body.length),
    );
    final counts = progress.map((p) => p.current).toList();
    expect(counts, orderedEquals(counts.toList()..sort()));
  });

  test('renames the part file onto the name a reader expects', () async {
    final file = await fetcher.fetchFile(
      url('sdk.zip'),
      base,
      usePartFile: true,
    );

    expect(file.path, '${base.path}${sep}sdk.zip');
    expect(file.readAsBytesSync(), body);
    expect(File('${base.path}${sep}sdk.zip.part').existsSync(), isFalse);
    expect(progress.last.state, UfbtProgressState.finished);
  });

  group('a download that cannot succeed', () {
    // **The regression test for both halves of the bug.** `IOSink.add` takes
    // no answer back from the file, so dart:io reported the failure by
    // completing the sink's `done` - and a `done` nobody listens to is an
    // uncaught asynchronous error, which is how a full `~/.ufbt` filed a
    // crash report. The loop then kept adding to a sink whose reader was
    // already gone and `flush()` waited forever, so the call never returned
    // either.
    //
    // The timeout is what catches the second half; `package:test` fails a
    // test on an error reaching its zone, so the first needs nothing
    // asserted. Measured against the pre-fix loop: this test fails with the
    // uncaught `PathAccessException` **and** a `TimeoutException`.
    // Sentry QUNLEASHED-2E.
    test('rejects when the file cannot be opened', () async {
      // A directory where the download wants to put its file. The open fails
      // rather than a write, which is the one consumer-side failure a test
      // can ask for on every platform this package's CI runs - a full disk is
      // not arrangeable, so what is left uncovered is a write that fails
      // after a successful open. Both reach this `catch` the same way.
      Directory('${base.path}${sep}sdk.zip').createSync();

      await expectLater(
        fetcher
            .fetchFile(url('sdk.zip'), base)
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<FileSystemException>()),
      );
      expect(progress.last.state, UfbtProgressState.failed);
      // Nothing was read: dart:io waits for the open before it subscribes,
      // which is what the response needs releasing for. Pinned so that an
      // SDK which ever opens lazily does not quietly turn this into a
      // different test.
      expect(progress.last.current, 0);
    });

    test('rejects without reporting finished when the rename fails', () async {
      // A directory under the final name: the part file is written, and
      // then cannot be renamed onto it. The one failure that happens after
      // the download itself succeeded, which is what the rename being inside
      // the same `try` as the writes is for - `fetchFile`'s own comment has
      // the reason.
      Directory('${base.path}${sep}sdk.zip').createSync();

      await expectLater(
        fetcher
            .fetchFile(url('sdk.zip'), base, usePartFile: true)
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<FileSystemException>()),
      );
      expect(progress.last.state, UfbtProgressState.failed);
      expect(File('${base.path}${sep}sdk.zip.part').existsSync(), isFalse);
    });

    // The read side, and the cleanup. This one never touches the chunked
    // path - it is served and hung up on directly - and the old code rejected
    // it promptly, so what these pin is that the body's own error reaches the
    // caller rather than the `File closed` the cleanup close throws, and that
    // the bytes which did land do not survive.
    for (final usePartFile in [true, false]) {
      test('rejects and keeps nothing when the body ends early '
          '(usePartFile: $usePartFile)', () async {
        final name = 'sdk-$truncatedMarker.zip';

        await expectLater(
          fetcher
              .fetchFile(url(name), base, usePartFile: usePartFile)
              .timeout(const Duration(seconds: 10)),
          throwsA(isA<HttpException>()),
        );

        // Written before the failure, so the delete has something to do -
        // without this the test passes just as well on a request that never
        // got as far as creating a file.
        expect(progress.last.current, truncatedBytes);
        expect(progress.last.state, UfbtProgressState.failed);
        expect(File('${base.path}$sep$name').existsSync(), isFalse);
        expect(File('${base.path}$sep$name.part').existsSync(), isFalse);
      });
    }
  });
}
