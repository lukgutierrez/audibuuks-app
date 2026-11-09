import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class CloudDownloadProgress {
  final int bytesReceived;
  final int totalBytes;
  final int percent;
  final String status;

  CloudDownloadProgress({
    required this.bytesReceived,
    required this.totalBytes,
    required this.percent,
    required this.status,
  });
}

class CloudBookDownloaderService {
  /// Extrae el File ID de una URL de Google Drive compartida.
  /// Soporta:
  /// - https://drive.google.com/file/d/1ABC123xyz.../view?usp=sharing
  /// - https://drive.google.com/open?id=1ABC123xyz...
  /// - https://drive.google.com/uc?id=1ABC123xyz...
  /// - https://docs.google.com/document/d/1ABC123xyz...
  static String? extractGoogleDriveId(String url) {
    final trimmed = url.trim();
    if (!trimmed.contains('drive.google.com') && !trimmed.contains('docs.google.com')) {
      return null;
    }

    // Patrón /d/<id>
    final matchD = RegExp(r'\/d\/([a-zA-Z0-9_-]+)').firstMatch(trimmed);
    if (matchD != null && matchD.groupCount >= 1) {
      return matchD.group(1);
    }

    // Patrón ?id=<id>
    final matchId = RegExp(r'[?&]id=([a-zA-Z0-9_-]+)').firstMatch(trimmed);
    if (matchId != null && matchId.groupCount >= 1) {
      return matchId.group(1);
    }

    return null;
  }

  /// Construye la URL de descarga directa para Google Drive o normaliza URLs directas
  static String buildDownloadUrl(String rawUrl) {
    final driveId = extractGoogleDriveId(rawUrl);
    if (driveId != null) {
      // URL de descarga directa de Google Drive
      return 'https://drive.google.com/uc?export=download&id=$driveId';
    }
    return rawUrl.trim();
  }

  /// Descarga un archivo desde un enlace (Drive o HTTP directo) reportando progreso
  static Future<File> downloadFileWithProgress({
    required String rawUrl,
    required String targetFileName,
    required void Function(CloudDownloadProgress progress) onProgress,
  }) async {
    final downloadUrl = buildDownloadUrl(rawUrl);
    final uri = Uri.parse(downloadUrl);

    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

      final response = await client.send(request);

      if (response.statusCode >= 300 && response.statusCode < 400) {
        // Redirección (común en Google Drive hacia servidores de descarga)
        final redirectLocation = response.headers['location'];
        if (redirectLocation != null) {
          return await downloadFileWithProgress(
            rawUrl: redirectLocation,
            targetFileName: targetFileName,
            onProgress: onProgress,
          );
        }
      }

      if (response.statusCode != 200) {
        throw Exception(
          'Error al conectar con el servidor (Código ${response.statusCode}). Verificá que el archivo tenga acceso "Cualquier persona con el enlace".',
        );
      }

      // Detectar nombre real desde Content-Disposition si existe
      String finalName = targetFileName;
      final contentDisposition = response.headers['content-disposition'];
      if (contentDisposition != null) {
        final nameMatch = RegExp(r'filename\*?=(?:UTF-8'')?["'']?([^"''\r\n;]+)["'']?', caseSensitive: false)
            .firstMatch(contentDisposition);
        if (nameMatch != null && nameMatch.group(1) != null) {
          final extractedName = Uri.decodeFull(nameMatch.group(1)!.trim());
          if (extractedName.toLowerCase().endsWith('.pdf') || extractedName.toLowerCase().endsWith('.epub')) {
            finalName = extractedName;
          }
        }
      }

      final docDir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${docDir.path}/cloud_downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }

      final localFile = File('${downloadsDir.path}/${DateTime.now().millisecondsSinceEpoch}_$finalName');
      final totalLength = response.contentLength ?? -1;
      int received = 0;

      final sink = localFile.openWrite();

      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);

        final percent = totalLength > 0 ? ((received / totalLength) * 100).round().clamp(1, 99) : 0;
        final mbReceived = (received / (1024 * 1024)).toStringAsFixed(1);
        final mbTotal = totalLength > 0 ? (totalLength / (1024 * 1024)).toStringAsFixed(1) : '?';

        onProgress(
          CloudDownloadProgress(
            bytesReceived: received,
            totalBytes: totalLength,
            percent: percent,
            status: totalLength > 0
                ? '$mbReceived MB de $mbTotal MB ($percent%)'
                : '$mbReceived MB descargados...',
          ),
        );
      }

      await sink.flush();
      await sink.close();

      return localFile;
    } finally {
      client.close();
    }
  }
}
