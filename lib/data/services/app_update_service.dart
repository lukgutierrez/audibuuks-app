import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_book_downloader_service.dart';
import 'native_channel_service.dart';

class AppUpdateInfo {
  final String tagName;
  final String latestVersion;
  final int? latestBuild;
  final String currentVersion;
  final int currentBuild;
  final String releaseTitle;
  final String releaseNotes;
  final String apkDownloadUrl;
  final String apkFileName;
  final int apkSizeBytes;
  final String releasePageUrl;

  const AppUpdateInfo({
    required this.tagName,
    required this.latestVersion,
    required this.latestBuild,
    required this.currentVersion,
    required this.currentBuild,
    required this.releaseTitle,
    required this.releaseNotes,
    required this.apkDownloadUrl,
    required this.apkFileName,
    required this.apkSizeBytes,
    required this.releasePageUrl,
  });

  String get formattedSize {
    if (apkSizeBytes <= 0) return '';
    return '${(apkSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get displayVersion =>
      latestBuild != null ? 'v$latestVersion (Build $latestBuild)' : 'v$latestVersion';
}

class ApkDownloadProgress {
  final int bytesReceived;
  final int totalBytes;
  final int percent;
  final String speedLabel;

  const ApkDownloadProgress({
    required this.bytesReceived,
    required this.totalBytes,
    required this.percent,
    required this.speedLabel,
  });
}

/// Servicio nativo de actualizaciones in-app conectado directamente a GitHub Releases.
/// Verifica nuevas versiones, selecciona el APK óptimo para el ABI del teléfono y lo instala vía FileProvider.
class AppUpdateService {
  static const String githubOwner = 'lukgutierrez';
  static const String githubRepo = 'audibuuks-app';
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

  static const String _dismissedTagKey = 'audiomind_dismissed_update_tag';
  static const int _maxApkBytes = 120 * 1024 * 1024; // 120 MB tope de seguridad
  static const int _maxRedirects = 5;

  /// Hosts oficiales de GitHub permitidos para descargar APKs verificados
  static bool isTrustedUpdateHost(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https') return false;
    final host = uri.host.toLowerCase();
    return host == 'github.com' ||
        host == 'api.github.com' ||
        host == 'objects.githubusercontent.com' ||
        host == 'release-assets.githubusercontent.com' ||
        host == 'github-releases.githubusercontent.com' ||
        host.endsWith('.githubusercontent.com');
  }

  /// Extrae `(major, minor, patch, build)` desde un tag o nombre de release (ej: "v1.0.2+2016", "1.0.1", "v1.0.0-build2015")
  static ({List<int> semver, int? build}) parseVersionString(String raw) {
    final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final semMatch = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(cleaned);
    final major = int.tryParse(semMatch?.group(1) ?? '') ?? 0;
    final minor = int.tryParse(semMatch?.group(2) ?? '') ?? 0;
    final patch = int.tryParse(semMatch?.group(3) ?? '') ?? 0;

    int? build;
    final buildMatch = RegExp(r'(?:\+|build[_\-\s]*)(\d+)', caseSensitive: false).firstMatch(cleaned);
    if (buildMatch != null) {
      build = int.tryParse(buildMatch.group(1) ?? '');
    }
    return (semver: [major, minor, patch], build: build);
  }

  /// Compara si la versión remota publicada en GitHub es estrictamente superior a la instalada
  static bool isNewerVersion({
    required String remoteVersionSource,
    required String currentVersion,
    required int currentBuild,
  }) {
    final remote = parseVersionString(remoteVersionSource);
    final local = parseVersionString(currentVersion);

    for (int i = 0; i < 3; i++) {
      if (remote.semver[i] > local.semver[i]) return true;
      if (remote.semver[i] < local.semver[i]) return false;
    }

    // Misma versión semántica (ej. 1.0.0 vs 1.0.0): comparar por build si está presente
    if (remote.build != null && currentBuild > 0) {
      return remote.build! > currentBuild;
    }
    return false;
  }

  /// Selecciona automáticamente el APK ideal para la arquitectura del celular (arm64-v8a > armeabi-v7a > universal)
  static Map<String, dynamic>? selectBestApkAsset(
    List<dynamic> assets,
    List<String> supportedAbis,
  ) {
    final apks = assets
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.apk'))
        .toList();

    if (apks.isEmpty) return null;

    // 1. Buscar coincidencia exacta con los ABIs soportados del dispositivo en orden de preferencia
    for (final abi in supportedAbis) {
      final abiLower = abi.toLowerCase();
      for (final apk in apks) {
        final name = (apk['name'] as String? ?? '').toLowerCase();
        if (name.contains(abiLower)) {
          return apk;
        }
      }
    }

    // 2. Fallback a APK universal (sin sufijo de ABI específico)
    for (final apk in apks) {
      final name = (apk['name'] as String? ?? '').toLowerCase();
      if (!name.contains('arm64') &&
          !name.contains('armeabi') &&
          !name.contains('x86_64') &&
          !name.contains('x86')) {
        return apk;
      }
    }

    // 3. Último recurso: arm64-v8a o el primer APK disponible
    for (final apk in apks) {
      if ((apk['name'] as String? ?? '').toLowerCase().contains('arm64')) {
        return apk;
      }
    }
    return apks.first;
  }

  /// Limpia APKs antiguos de la caché temporal para liberar espacio
  static Future<void> cleanupOldApks() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final updatesDir = Directory('${tempDir.path}/updates');
      if (await updatesDir.exists()) {
        await for (final entity in updatesDir.list()) {
          if (entity is File && entity.path.toLowerCase().endsWith('.apk')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  static Future<void> dismissUpdateTag(String tagName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedTagKey, tagName);
    } catch (_) {}
  }

  /// Consulta GitHub Releases y devuelve `AppUpdateInfo` si existe una versión más reciente.
  static Future<AppUpdateInfo?> checkForUpdate({
    bool ignoreDismissed = false,
  }) async {
    if (!Platform.isAndroid) return null;

    try {
      final versionInfo = await NativeChannelService.getAppVersionInfo();
      final currentVersion = (versionInfo?['versionName'] as String?) ?? '1.0.0';
      final currentBuild = (versionInfo?['versionCode'] as int?) ?? 0;
      final supportedAbis = ((versionInfo?['supportedAbis'] as List?) ?? ['arm64-v8a'])
          .map((e) => e.toString())
          .toList();

      final response = await http
          .get(
            Uri.parse(latestReleaseApiUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Audibuuks-Android-Updater',
            },
          )
          .timeout(const Duration(seconds: 7));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['draft'] == true || data['prerelease'] == true) return null;

      final tagName = (data['tag_name'] as String? ?? '').trim();
      final releaseTitle = (data['name'] as String? ?? tagName).trim();
      final releaseNotes = (data['body'] as String? ?? '').trim();
      final releasePageUrl =
          (data['html_url'] as String? ?? 'https://github.com/$githubOwner/$githubRepo/releases')
              .trim();
      final assets = (data['assets'] as List?) ?? const [];

      final bestApk = selectBestApkAsset(assets, supportedAbis);
      if (bestApk == null) return null;

      final apkUrl = (bestApk['browser_download_url'] as String? ?? '').trim();
      final apkName = (bestApk['name'] as String? ?? 'Audibuuks_update.apk').trim();
      final apkSize = (bestApk['size'] as int?) ?? 0;

      final apkUri = Uri.tryParse(apkUrl);
      if (apkUri == null || !isTrustedUpdateHost(apkUri)) return null;

      // Buscar versión + build combinando tag, título y nombre del APK
      final versionSource = '$tagName $releaseTitle $apkName';
      final parsedRemote = parseVersionString(versionSource);
      final normalizedVersion =
          '${parsedRemote.semver[0]}.${parsedRemote.semver[1]}.${parsedRemote.semver[2]}';

      final hasNewer = isNewerVersion(
        remoteVersionSource: versionSource,
        currentVersion: currentVersion,
        currentBuild: currentBuild,
      );
      if (!hasNewer) return null;

      if (!ignoreDismissed) {
        final prefs = await SharedPreferences.getInstance();
        final dismissedTag = prefs.getString(_dismissedTagKey);
        if (dismissedTag != null && dismissedTag == tagName) {
          return null;
        }
      }

      return AppUpdateInfo(
        tagName: tagName,
        latestVersion: normalizedVersion,
        latestBuild: parsedRemote.build,
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        releaseTitle: releaseTitle.isEmpty ? 'Audibuuks v$normalizedVersion' : releaseTitle,
        releaseNotes: releaseNotes.isEmpty
            ? 'Mejoras de rendimiento, estabilidad y velocidad de descarga.'
            : releaseNotes,
        apkDownloadUrl: apkUrl,
        apkFileName: CloudBookDownloaderService.sanitizeFileName(
          apkName,
          fallback: 'Audibuuks_update.apk',
        ),
        apkSizeBytes: apkSize,
        releasePageUrl: releasePageUrl,
      );
    } catch (e) {
      debugPrint('Update check notice: $e');
      return null;
    }
  }

  /// Descarga el APK oficial desde GitHub Releases en `cache/updates/` reportando progreso y velocidad en vivo.
  static Future<File> downloadUpdateApk({
    required AppUpdateInfo info,
    required void Function(ApkDownloadProgress progress) onProgress,
    required bool Function() isCancelled,
  }) async {
    await cleanupOldApks();

    final tempDir = await getTemporaryDirectory();
    final updatesDir = Directory('${tempDir.path}/updates');
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }

    final safeName = CloudBookDownloaderService.sanitizeFileName(
      info.apkFileName,
      fallback: 'Audibuuks_update.apk',
    );
    final apkFile = File('${updatesDir.path}/$safeName');

    return _downloadWithRedirects(
      url: info.apkDownloadUrl,
      targetFile: apkFile,
      expectedSize: info.apkSizeBytes,
      onProgress: onProgress,
      isCancelled: isCancelled,
      depth: 0,
    );
  }

  static Future<File> _downloadWithRedirects({
    required String url,
    required File targetFile,
    required int expectedSize,
    required void Function(ApkDownloadProgress progress) onProgress,
    required bool Function() isCancelled,
    required int depth,
  }) async {
    if (depth > _maxRedirects) {
      throw Exception('Demasiadas redirecciones al descargar la actualización.');
    }

    final uri = Uri.tryParse(url);
    if (uri == null || !isTrustedUpdateHost(uri)) {
      throw Exception('Origen de descarga no verificado por seguridad.');
    }

    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', uri);
      request.followRedirects = false;
      request.headers['User-Agent'] = 'Audibuuks-Android-Updater';

      final response = await client.send(request).timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('Tiempo de espera agotado al conectar con GitHub.'),
      );

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location != null && location.isNotEmpty) {
          final nextUrl = uri.resolve(location).toString();
          return await _downloadWithRedirects(
            url: nextUrl,
            targetFile: targetFile,
            expectedSize: expectedSize,
            onProgress: onProgress,
            isCancelled: isCancelled,
            depth: depth + 1,
          );
        }
      }

      if (response.statusCode != 200) {
        throw Exception('No se pudo descargar el APK (HTTP ${response.statusCode}).');
      }

      final totalBytes = (response.contentLength != null && response.contentLength! > 0)
          ? response.contentLength!
          : expectedSize;
      if (totalBytes > _maxApkBytes) {
        throw Exception('El APK supera el tamaño máximo seguro permitido.');
      }

      sink = targetFile.openWrite();
      int received = 0;
      final List<int> header = [];
      final startedAt = DateTime.now();
      DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 25),
        onTimeout: (_) => throw TimeoutException('Conexión interrumpida durante la descarga.'),
      )) {
        if (isCancelled()) {
          throw Exception('Descarga cancelada.');
        }

        if (header.length < 4) {
          header.addAll(chunk.take(4 - header.length));
        }

        received += chunk.length;
        if (received > _maxApkBytes) {
          throw Exception('El archivo excedió el límite de seguridad.');
        }

        sink.add(chunk);

        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 120 ||
            (totalBytes > 0 && received >= totalBytes)) {
          lastEmit = now;
          final elapsedSec = math.max(0.2, now.difference(startedAt).inMilliseconds / 1000.0);
          final speedMb = (received / (1024 * 1024)) / elapsedSec;
          final pct = totalBytes > 0 ? ((received / totalBytes) * 100).round().clamp(1, 99) : 0;

          onProgress(
            ApkDownloadProgress(
              bytesReceived: received,
              totalBytes: totalBytes,
              percent: pct,
              speedLabel: '${speedMb.toStringAsFixed(1)} MB/s',
            ),
          );
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Validar firma binaria ZIP/APK ("PK\x03\x04")
      final isApkZip = header.length >= 4 &&
          header[0] == 0x50 &&
          header[1] == 0x4B &&
          header[2] == 0x03 &&
          header[3] == 0x04;
      if (!isApkZip) {
        throw Exception('El archivo descargado no es un paquete APK válido.');
      }

      onProgress(
        ApkDownloadProgress(
          bytesReceived: received,
          totalBytes: totalBytes > 0 ? totalBytes : received,
          percent: 100,
          speedLabel: 'Listo',
        ),
      );

      return targetFile;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await targetFile.exists()) await targetFile.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }
}
