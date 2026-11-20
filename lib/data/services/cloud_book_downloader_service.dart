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
  static const int maxFileSizeBytes = 150 * 1024 * 1024; // 150 MB máximo de seguridad
  static const int _maxRedirects = 5;
  static const Duration _connectTimeout = Duration(seconds: 25);

  /// Extrae el File ID de una URL de Google Drive compartida.
  /// Soporta:
  /// - https://drive.google.com/file/d/1ABC123xyz.../view?usp=sharing
  /// - https://drive.google.com/open?id=1ABC123xyz...
  /// - https://drive.google.com/uc?id=1ABC123xyz...
  /// - https://docs.google.com/document/d/1ABC123xyz...
  static String? extractGoogleDriveId(String url) {
    final trimmed = url.trim();
    if (!trimmed.contains('drive.google.com') &&
        !trimmed.contains('docs.google.com') &&
        !trimmed.contains('drive.usercontent.google.com')) {
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

  /// Construye la URL de descarga directa para Google Drive (con confirm=t para archivos >100MB)
  /// o normaliza URLs directas.
  static String buildDownloadUrl(String rawUrl) {
    final driveId = extractGoogleDriveId(rawUrl);
    if (driveId != null) {
      return 'https://drive.usercontent.google.com/download?id=$driveId&export=download&confirm=t';
    }
    return rawUrl.trim();
  }

  /// Sanitiza cualquier nombre de archivo remoto/externo para impedir Path Traversal (`../`, `/`, `\`).
  static String sanitizeFileName(String rawName, {String fallback = 'libro.pdf'}) {
    final base = rawName.split(RegExp(r'[/\\]')).last.trim();
    var clean = base
        .replaceAll('..', '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._\-\sáéíóúÁÉÍÓÚñÑ]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    if (clean.isEmpty || !RegExp(r'[a-zA-Z0-9áéíóúÁÉÍÓÚñÑ]').hasMatch(clean)) {
      clean = fallback;
    }
    if (clean.length > 110) {
      final dotIdx = clean.lastIndexOf('.');
      if (dotIdx > 0 && clean.length - dotIdx <= 6) {
        final ext = clean.substring(dotIdx);
        clean = '${clean.substring(0, 110 - ext.length)}$ext';
      } else {
        clean = clean.substring(0, 110);
      }
    }
    return clean;
  }

  /// Verifica que la URI sea segura (solo http/https públicos, sin acceso a hosts locales o LAN privada).
  static Uri validateDownloadUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      throw Exception('El enlace ingresado no es una URL válida.');
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      throw Exception('Solo se permiten enlaces HTTP o HTTPS seguros.');
    }

    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host == '::1' ||
        host == '0.0.0.0' ||
        host.endsWith('.local') ||
        host.startsWith('127.') ||
        host.startsWith('10.') ||
        host.startsWith('192.168.') ||
        host.startsWith('169.254.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(host)) {
      throw Exception('Por seguridad no se permiten descargas desde direcciones de red privada.');
    }
    return uri;
  }

  /// Descarga un archivo desde un enlace (Drive o HTTP directo) con validaciones de seguridad y progreso fluido
  static Future<File> downloadFileWithProgress({
    required String rawUrl,
    required String targetFileName,
    required void Function(CloudDownloadProgress progress) onProgress,
    int redirectDepth = 0,
  }) async {
    if (redirectDepth > _maxRedirects) {
      throw Exception('Demasiadas redirecciones al intentar descargar el archivo.');
    }

    final downloadUrl = redirectDepth == 0 ? buildDownloadUrl(rawUrl) : rawUrl.trim();
    final uri = validateDownloadUri(downloadUrl);

    final client = http.Client();
    File? localFile;
    IOSink? sink;
    try {
      final request = http.Request('GET', uri);
      request.followRedirects = false;
      request.headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

      final response = await client.send(request).timeout(
        _connectTimeout,
        onTimeout: () => throw TimeoutException('Tiempo de espera agotado al conectar con el servidor.'),
      );

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final redirectLocation = response.headers['location'];
        if (redirectLocation != null && redirectLocation.isNotEmpty) {
          final resolved = uri.resolve(redirectLocation).toString();
          return await downloadFileWithProgress(
            rawUrl: resolved,
            targetFileName: targetFileName,
            onProgress: onProgress,
            redirectDepth: redirectDepth + 1,
          );
        }
      }

      if (response.statusCode != 200) {
        throw Exception(
          'Error al conectar con el servidor (Código ${response.statusCode}). Verificá que el archivo tenga acceso "Cualquier persona con el enlace".',
        );
      }

      final contentType = (response.headers['content-type'] ?? '').toLowerCase();
      if (contentType.contains('text/html')) {
        throw Exception(
          'El enlace devolvió una página web en lugar de un PDF/EPUB. Verificá que el archivo en Google Drive sea público ("Cualquier persona con el enlace").',
        );
      }

      final totalLength = response.contentLength ?? -1;
      if (totalLength > maxFileSizeBytes) {
        throw Exception('El archivo supera el límite máximo permitido de 150 MB.');
      }

      // Detectar y sanitizar nombre real desde Content-Disposition si existe
      String finalName = sanitizeFileName(targetFileName);
      final contentDisposition = response.headers['content-disposition'];
      if (contentDisposition != null) {
        final nameMatch = RegExp(
          r'''filename\*?=(?:UTF-8'')?["']?([^"'\r\n;]+)["']?''',
          caseSensitive: false,
        ).firstMatch(contentDisposition);
        if (nameMatch != null && nameMatch.group(1) != null) {
          try {
            final extractedName = sanitizeFileName(Uri.decodeFull(nameMatch.group(1)!.trim()));
            if (extractedName.toLowerCase().endsWith('.pdf') ||
                extractedName.toLowerCase().endsWith('.epub')) {
              finalName = extractedName;
            }
          } catch (_) {}
        }
      }

      final docDir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${docDir.path}/cloud_downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }

      localFile = File('${downloadsDir.path}/${DateTime.now().millisecondsSinceEpoch}_$finalName');
      int received = 0;
      final List<int> headerBytes = [];
      DateTime lastProgressEmit = DateTime.fromMillisecondsSinceEpoch(0);
      int lastReportedPercent = -1;

      sink = localFile.openWrite();

      await for (final chunk in response.stream.timeout(
        _connectTimeout,
        onTimeout: (_) => throw TimeoutException('La descarga se detuvo por pérdida de señal.'),
      )) {
        if (headerBytes.length < 8) {
          headerBytes.addAll(chunk.take(8 - headerBytes.length));
        }

        received += chunk.length;
        if (received > maxFileSizeBytes) {
          throw Exception('La descarga superó el límite de seguridad de 150 MB y fue cancelada.');
        }

        sink.add(chunk);

        final percent = totalLength > 0 ? ((received / totalLength) * 100).round().clamp(1, 99) : 0;
        final now = DateTime.now();
        if (now.difference(lastProgressEmit).inMilliseconds >= 120 ||
            percent != lastReportedPercent) {
          lastProgressEmit = now;
          lastReportedPercent = percent;
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
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Validar magic bytes reales (PDF: "%PDF" | EPUB/ZIP: "PK\x03\x04")
      final bool isPdfMagic = headerBytes.length >= 4 &&
          headerBytes[0] == 0x25 &&
          headerBytes[1] == 0x50 &&
          headerBytes[2] == 0x44 &&
          headerBytes[3] == 0x46;
      final bool isZipMagic = headerBytes.length >= 4 &&
          headerBytes[0] == 0x50 &&
          headerBytes[1] == 0x4B &&
          headerBytes[2] == 0x03 &&
          headerBytes[3] == 0x04;

      if (!isPdfMagic && !isZipMagic) {
        throw Exception(
          'El archivo descargado no es un PDF ni un EPUB válido. Verificá el enlace y permisos de acceso.',
        );
      }

      // Corregir extensión automáticamente si el servidor no envió nombre real
      final lowerPath = localFile.path.toLowerCase();
      if (isZipMagic && !lowerPath.endsWith('.epub')) {
        final renamed = File('${localFile.path}.epub');
        localFile = await localFile.rename(renamed.path);
      } else if (isPdfMagic && !lowerPath.endsWith('.pdf')) {
        final renamed = File('${localFile.path}.pdf');
        localFile = await localFile.rename(renamed.path);
      }

      return localFile;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (localFile != null && await localFile.exists()) {
          await localFile.delete();
        }
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }
}
