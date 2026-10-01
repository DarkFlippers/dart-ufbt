import 'file_type.dart';

/// The text in [raw], or null when there is none to have.
///
/// A cast would read a field that changed type as a decode failure for the
/// whole document - and this decoder reads `directory.json`, where losing the
/// document loses every channel. The producer is not this project's to pin:
/// the same feed is read by two decoders in two repositories, and the other
/// one already answers absence and a type change the same way.
String? _text(Object? raw) => raw is String ? raw : null;

/// The whole number in [raw], or null when there is none to have.
///
/// `timestamp` arrives as an int from both live feeds today, so `as int?`
/// works - and a producer that ever emits `1788532004.0` decodes to double
/// and takes every channel with it. A number is a number.
int? _count(Object? raw) => raw is num ? raw.toInt() : null;

class UfbtIndexFile {
  const UfbtIndexFile({
    required this.url,
    required this.target,
    required this.type,
    required this.sha256,
  });

  final String url;
  final String target;
  final String type;
  final String? sha256;

  static UfbtIndexFile fromJson(Map<String, dynamic> json) {
    return UfbtIndexFile(
      url: _text(json['url']) ?? '',
      target: _text(json['target']) ?? '',
      type: _text(json['type']) ?? '',
      sha256: _text(json['sha256']),
    );
  }
}

class UfbtIndexVersion {
  const UfbtIndexVersion({
    required this.version,
    required this.changelog,
    required this.timestamp,
    required this.files,
  });

  final String version;
  final String? changelog;
  final int? timestamp;
  final List<UfbtIndexFile> files;

  static UfbtIndexVersion fromJson(Map<String, dynamic> json) {
    final files = (json['files'] as List?) ?? const [];
    return UfbtIndexVersion(
      version: _text(json['version']) ?? '',
      changelog: _text(json['changelog']),
      timestamp: _count(json['timestamp']),
      files: files
          .whereType<Map>()
          .map(
            (file) => UfbtIndexFile.fromJson(Map<String, dynamic>.from(file)),
          )
          .toList(growable: false),
    );
  }

  UfbtIndexFile? findFile(UfbtFileType type, String target) {
    for (final file in files) {
      if (file.type == type.id && file.target == target) return file;
    }
    return null;
  }
}

class UfbtIndexChannel {
  const UfbtIndexChannel({
    required this.id,
    required this.title,
    required this.description,
    required this.versions,
  });

  final String id;
  final String? title;
  final String? description;
  final List<UfbtIndexVersion> versions;

  static UfbtIndexChannel fromJson(Map<String, dynamic> json) {
    final versions = (json['versions'] as List?) ?? const [];
    return UfbtIndexChannel(
      id: _text(json['id']) ?? '',
      title: _text(json['title']),
      description: _text(json['description']),
      versions: versions
          .whereType<Map>()
          .map(
            (version) =>
                UfbtIndexVersion.fromJson(Map<String, dynamic>.from(version)),
          )
          .toList(growable: false),
    );
  }
}

class UfbtDirectoryIndex {
  const UfbtDirectoryIndex(this.channels);

  final List<UfbtIndexChannel> channels;

  static UfbtDirectoryIndex fromJson(Map<String, dynamic> json) {
    final channels = (json['channels'] as List?) ?? const [];
    return UfbtDirectoryIndex(
      channels
          .whereType<Map>()
          .map(
            (channel) =>
                UfbtIndexChannel.fromJson(Map<String, dynamic>.from(channel)),
          )
          .toList(growable: false),
    );
  }

  UfbtIndexChannel? findChannel(String id) {
    for (final channel in channels) {
      if (channel.id == id) return channel;
    }
    return null;
  }
}
