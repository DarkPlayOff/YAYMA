import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yayma/src/rust/api/updates.dart' as updates;

typedef AppUpdateInfo = updates.AppUpdateInfoDto;

/// Called with a progress value in the `0..1` range, or `null` when the total
/// size is unknown.
typedef DownloadProgressCallback = void Function(double? progress);

/// Result of resolving the APK asset that matches the current device.
class ApkAsset {
  final String name;
  final Uri url;
  final int size;

  const ApkAsset({required this.name, required this.url, required this.size});
}

/// A failure with a message that is safe to show to the user directly.
class UpdateException implements Exception {
  final String message;

  const UpdateException(this.message);

  @override
  String toString() => message;
}

class UpdateService {
  static const _updaterChannel = MethodChannel(
    'io.github.darkplayoff.yayma/updater',
  );

  static Future<AppUpdateInfo?> checkForUpdates() async {
    try {
      return await updates.checkForUpdates();
    } on Object {
      return null;
    }
  }

  /// ABIs supported by the device, most preferred first.
  static Future<List<String>> _supportedAbis() async {
    if (!Platform.isAndroid) return const [];
    try {
      final abis = await _updaterChannel.invokeMethod<List<Object?>>(
        'getSupportedAbis',
      );
      return abis?.whereType<String>().toList() ?? const [];
    } on Object {
      return const [];
    }
  }

  /// Whether the app is allowed to install packages (Android only).
  static Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _updaterChannel.invokeMethod<bool>('canInstallPackages') ??
          false;
    } on Object {
      return false;
    }
  }

  /// Opens the system "install unknown apps" settings for this package so the
  /// user can grant the install permission.
  static Future<void> requestInstallPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _updaterChannel.invokeMethod<void>('requestInstallPermission');
    } on Object {
      // Ignore — some ROMs don't expose this screen.
    }
  }

  /// Launches the system package installer for the downloaded APK.
  static Future<void> installApk(String path) async {
    await _updaterChannel.invokeMethod<void>('installApk', {'path': path});
  }

  /// Removes any APK left over from a previous update download. Called at
  /// startup so a finished/partial download never lingers in the cache.
  static Future<void> cleanupDownloadedApk() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yayma-update.apk');
      if (file.existsSync()) {
        await file.delete();
      }
    } on Object {
      // Best-effort only.
    }
  }

  /// Resolves the release APK that matches this device's ABI. Throws an
  /// [UpdateException] with a user-facing message when it can't be resolved.
  static Future<ApkAsset> resolveApkAsset(AppUpdateInfo info) async {
    final segments = Uri.parse(info.url).pathSegments;
    if (segments.length < 2) {
      throw const UpdateException('Не удалось определить релиз обновления.');
    }
    final repo = '${segments[0]}/${segments[1]}';
    final tagIndex = segments.indexOf('tag');
    final tag = (tagIndex >= 0 && tagIndex + 1 < segments.length)
        ? segments[tagIndex + 1]
        : info.latestVersion;

    final assets = await _fetchReleaseApks(repo, tag);
    if (assets.isEmpty) {
      throw const UpdateException('В релизе не найдено файлов APK.');
    }

    final abis = await _supportedAbis();
    for (final abi in abis) {
      final needle = abi.toLowerCase();
      for (final asset in assets) {
        if (asset.name.toLowerCase().contains(needle)) return asset;
      }
    }
    throw const UpdateException(
      'Не найдено сборки, совместимой с этим устройством.',
    );
  }

  static Future<List<ApkAsset>> _fetchReleaseApks(
    String repo,
    String tag,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repo/releases/tags/$tag'),
      );
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      request.headers.set('User-Agent', 'yayma-app');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw UpdateException(
          response.statusCode == 403
              ? 'GitHub временно ограничил запросы. Попробуйте позже.'
              : 'Не удалось получить данные о релизе (HTTP ${response.statusCode}).',
        );
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return const [];
      final rawAssets = decoded['assets'];
      if (rawAssets is! List) return const [];

      final result = <ApkAsset>[];
      for (final raw in rawAssets) {
        if (raw is! Map<String, dynamic>) continue;
        final name = raw['name'];
        final url = raw['browser_download_url'];
        if (name is! String ||
            url is! String ||
            !name.toLowerCase().endsWith('.apk')) {
          continue;
        }
        result.add(
          ApkAsset(
            name: name,
            url: Uri.parse(url),
            size: raw['size'] is int ? raw['size'] as int : 0,
          ),
        );
      }
      return result;
    } on UpdateException {
      rethrow;
    } on Object {
      throw const UpdateException(
        'Не удалось связаться с GitHub. Проверьте подключение к интернету.',
      );
    } finally {
      client.close();
    }
  }

  /// Downloads [asset] into the temporary directory, reporting progress via
  /// [onProgress]. Throws on failure.
  static Future<File> downloadApk(
    ApkAsset asset, {
    DownloadProgressCallback? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(asset.url);
      request.headers.set('User-Agent', 'yayma-app');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yayma-update.apk');
      if (file.existsSync()) {
        await file.delete();
      }

      final sink = file.openWrite();
      try {
        final total = response.contentLength > 0
            ? response.contentLength
            : asset.size;
        var received = 0;
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(total > 0 ? (received / total).clamp(0, 1) : null);
        }
        await sink.flush();
        await sink.close();
      } on Object {
        await sink.close();
        if (file.existsSync()) {
          try {
            await file.delete();
          } on Object {
            // Best-effort cleanup of the partial download.
          }
        }
        rethrow;
      }
      onProgress?.call(1);
      return file;
    } finally {
      client.close();
    }
  }
}
