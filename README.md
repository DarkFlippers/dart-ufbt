# dartufbt

[![pub package](https://img.shields.io/pub/v/dartufbt.svg)](https://pub.dev/packages/dartufbt)
[![license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Native Dart port of [uFBT](https://github.com/flipperdevices/flipperzero-ufbt) — deploys the
Flipper Zero SDK and builds `.fap` applications. No Python, no SCons, no shell.

## Features

- **SDK deployment** — release / release-candidate / dev channels, a firmware branch, a direct
  URL or a local archive.
- **Toolchain** — downloads and unpacks the ARM GCC toolchain uFBT expects.
- **FAP builder** — compiles and links `.fap` / `.fal`, resolves API symbols against the SDK,
  embeds icons and file assets, writes FastFAP relocation tables and `.fapmeta`.
- **Structured logging** — events reach sinks as objects, so a GUI can render progress instead
  of scraping stdout.

## Install

```yaml
dependencies:
  dartufbt: ^0.1.0
```

## Usage

```dart
import 'dart:io';
import 'package:dartufbt/dartufbt.dart';

final logger = UfbtLogger(sink: UfbtConsoleSink().call);
final ufbt = UfbtInstaller(logger: logger);

// SDK + toolchain into ~/.ufbt
await ufbt.install(SdkDeployTask.channel(channel: UfbtUpdateChannel.release));

// Every app of application.fam into <appDir>/dist
final result = await FapBuilder(
  logger: logger,
  paths: ufbt.paths,
).build(appDir: Directory('my_app'));

print(result.success ? result.fap!.path : result.error);
```

## SDK sources

```dart
SdkDeployTask.channel(channel: UfbtUpdateChannel.dev);   // update channel
SdkDeployTask.branch(branch: 'my-feature');              // firmware branch
SdkDeployTask.url(url: '...', hwTarget: 'f7');           // direct archive
SdkDeployTask.local(filePath: '...', hwTarget: 'f7');    // local archive
```

`ufbt.status()` reports the deployed target, mode and version; `ufbt.checkForUpdate()` compares
it against the channel head.

## State

Everything lives under `~/.ufbt` — SDK in `current/`, toolchain in `toolchain/`, archives in
`download/`. Override with `UFBT_HOME` and `FBT_TOOLCHAIN_PATH`, from the environment or from a
`.env` file next to the project.

## License

GPL-3.0. See [LICENSE](LICENSE).
