import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../domain/models/book_item.dart';
import 'native_channel_service.dart';

class CoverService {
  static String cleanSearchTitle(String rawTitle) {
    var s = rawTitle
        .replaceAll(RegExp(r'\.(pdf|epub)$', caseSensitive: false), '')
        .replaceAll(RegExp(r'_?oceanofpdf\.com_?', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'spanish[_ ]edition', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'libro[_ ]digital', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\(.*?\)'), ' ')
        .replaceAll(RegExp(r'\[.*?\]'), ' ')
        .replaceAll(RegExp(r'[-_ ]*cap(itulo)?[-_ ]*\d+.*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'^\d+[-_ ]+'), '')
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.isEmpty ? rawTitle : s;
  }

  static Future<List<Color>> extractCoverPalette(BookItem book) async {
    try {
      Uint8List? bytes;
      if (book.coverImagePath != null && File(book.coverImagePath!).existsSync()) {
        bytes = await File(book.coverImagePath!).readAsBytes();
      }
      if (bytes != null && bytes.isNotEmpty) {
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 24,
          targetHeight: 24,
        );
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data != null) {
          int r1 = 0, g1 = 0, b1 = 0, count1 = 0;
          int r2 = 0, g2 = 0, b2 = 0, count2 = 0;
          final u8 = data.buffer.asUint8List();
          final half = u8.length ~/ 2;
          for (int i = 0; i < u8.length - 4; i += 4) {
            final r = u8[i];
            final g = u8[i + 1];
            final b = u8[i + 2];
            final lum = (r * 299 + g * 587 + b * 114) ~/ 1000;
            if (lum > 22 && lum < 235) {
              if (i < half) {
                r1 += r;
                g1 += g;
                b1 += b;
                count1++;
              } else {
                r2 += r;
                g2 += g;
                b2 += b;
                count2++;
              }
            }
          }
          if (count1 > 0 && count2 > 0) {
            final c1 = HSLColor.fromColor(
              Color.fromARGB(255, r1 ~/ count1, g1 ~/ count1, b1 ~/ count1),
            );
            final c2 = HSLColor.fromColor(
              Color.fromARGB(255, r2 ~/ count2, g2 ~/ count2, b2 ~/ count2),
            );
            return [
              c1
                  .withSaturation((c1.saturation * 1.4).clamp(0.42, 0.85))
                  .withLightness(0.28)
                  .toColor(),
              c2
                  .withSaturation((c2.saturation * 1.4).clamp(0.38, 0.85))
                  .withLightness(0.18)
                  .toColor(),
            ];
          }
        }
      }
    } catch (_) {}

    final int h = book.title.hashCode.abs();
    final hue1 = (h % 360).toDouble();
    final hue2 = ((h ~/ 7) % 360).toDouble();
    return [
      HSLColor.fromAHSL(1.0, hue1, 0.58, 0.26).toColor(),
      HSLColor.fromAHSL(1.0, hue2, 0.62, 0.18).toColor(),
    ];
  }

  static Future<String?> fetchOnlineCoverUrl(String rawTitle) async {
    try {
      final query = cleanSearchTitle(rawTitle);
      final uri = Uri.parse(
        'https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=ebook&limit=1',
      );
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final art = results.first['artworkUrl100'] as String?;
          if (art != null && art.isNotEmpty) {
            return art.replaceAll('100x100bb', '600x600bb');
          }
        }
      }
    } catch (e) {
      debugPrint('Online cover lookup notice: $e');
    }
    return null;
  }

  static Uint8List? extractEmbeddedJpegFromPdf(Uint8List pdfBytes) {
    final limit = min(pdfBytes.length - 4, 1500000);
    int start = -1;
    for (int i = 0; i < limit; i++) {
      if (pdfBytes[i] == 0xFF && pdfBytes[i + 1] == 0xD8 && pdfBytes[i + 2] == 0xFF) {
        start = i;
        break;
      }
    }
    if (start == -1) return null;

    const endstreamBytes = [101, 110, 100, 115, 116, 114, 101, 97, 109];
    int endStreamPos = -1;
    final searchLimit = min(pdfBytes.length - endstreamBytes.length, start + 1200000);
    for (int i = start + 100; i < searchLimit; i++) {
      bool match = true;
      for (int j = 0; j < endstreamBytes.length; j++) {
        if (pdfBytes[i + j] != endstreamBytes[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        endStreamPos = i;
        break;
      }
    }

    if (endStreamPos != -1 && endStreamPos - start > 4000) {
      int actualEnd = endStreamPos;
      while (actualEnd > start &&
          (pdfBytes[actualEnd - 1] == 0x0A ||
              pdfBytes[actualEnd - 1] == 0x0D ||
              pdfBytes[actualEnd - 1] == 0x20)) {
        actualEnd--;
      }
      return Uint8List.sublistView(pdfBytes, start, actualEnd);
    }
    return null;
  }

  static Future<Map<String, String?>> resolveCoverForPdf({
    required String bookId,
    required String bookTitle,
    required Uint8List pdfBytes,
  }) async {
    final docDir = await getApplicationDocumentsDirectory();
    final coverFile = File('${docDir.path}/cover_$bookId.jpg');

    final embeddedJpeg = extractEmbeddedJpegFromPdf(pdfBytes);
    if (embeddedJpeg != null) {
      await coverFile.writeAsBytes(embeddedJpeg);
      return {'path': coverFile.path, 'url': null};
    }

    try {
      final tempPdf = File('${docDir.path}/temp_$bookId.pdf');
      await tempPdf.writeAsBytes(pdfBytes);
      final renderedBytes = await NativeChannelService.channel.invokeMethod<Uint8List>(
        'renderFirstPage',
        {'path': tempPdf.path},
      );
      if (await tempPdf.exists()) {
        await tempPdf.delete();
      }
      if (renderedBytes != null && renderedBytes.length > 1000) {
        await coverFile.writeAsBytes(renderedBytes);
        return {'path': coverFile.path, 'url': null};
      }
    } catch (e) {
      debugPrint('Native PdfRenderer notice: $e');
    }

    final onlineUrl = await fetchOnlineCoverUrl(bookTitle);
    if (onlineUrl != null) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(onlineUrl));
        final res = await req.close().timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final imgBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
          if (imgBytes.length > 1000) {
            await coverFile.writeAsBytes(imgBytes);
            return {'path': coverFile.path, 'url': onlineUrl};
          }
        }
      } catch (_) {}
    }

    return {'path': null, 'url': onlineUrl};
  }
}
