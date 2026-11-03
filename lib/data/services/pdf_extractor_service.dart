import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../domain/models/chapter_item.dart';

class PdfIsolatePayload {
  final Uint8List pdfBytes;
  final SendPort sendPort;
  PdfIsolatePayload(this.pdfBytes, this.sendPort);
}

class PdfExtractorService {
  static Future<List<ChapterItem>> extractChaptersInBackground({
    required Uint8List pdfBytes,
    required void Function(int current, int total, int percent) onProgress,
  }) async {
    final receivePort = ReceivePort();
    final completer = Completer<List<ChapterItem>>();

    receivePort.listen((message) {
      if (message is Map) {
        final type = message['type'];
        if (type == 'progress') {
          final int current = message['current'] as int;
          final int total = message['total'] as int;
          final int pct = message['percent'] as int;
          onProgress(current, total, pct);
        } else if (type == 'done') {
          final rawList = message['chapters'] as List;
          final chapters = rawList
              .map((c) => ChapterItem.fromJson(Map<String, dynamic>.from(c as Map)))
              .toList();
          receivePort.close();
          if (!completer.isCompleted) completer.complete(chapters);
        } else if (type == 'error') {
          receivePort.close();
          if (!completer.isCompleted) {
            completer.completeError(Exception(message['message']));
          }
        }
      }
    });

    await Isolate.spawn(
      pdfExtractionIsolateEntry,
      PdfIsolatePayload(pdfBytes, receivePort.sendPort),
    );

    return completer.future;
  }

  static bool _isTableOfContentsPage(String rawPageText) {
    final dotClusters = RegExp(r'\.{4,}|…{2,}').allMatches(rawPageText).length;
    final lower = rawPageText.toLowerCase();
    if (dotClusters >= 4) return true;
    if ((lower.contains('índice') || lower.contains('indice') || lower.contains('contenido')) &&
        dotClusters >= 2) {
      return true;
    }
    return false;
  }

  static String? _detectChapterHeadingOnPage(String pageText) {
    final lines = pageText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(6)
        .toList();
    if (lines.isEmpty) return null;

    final headingRegex = RegExp(
      r'^(?:CAP[ÍI]TULO\s+\d+|CAP[ÍI]TULO\s+[IVXLCDM]+|PARTE\s+\d+|PARTE\s+[IVXLCDM]+|PRIMERA\s+PARTE|SEGUNDA\s+PARTE|TERCERA\s+PARTE|CUARTA\s+PARTE|REGLA\s*#?\s*\d+|SECRETO\s*#?\s*\d+|D[ÍI]A\s+\d+|INTRODUCCI[ÓO]N|PR[ÓO]LOGO|PREFACIO|SINOPSIS|CONCLUSI[ÓO]N|EP[ÍI]LOGO)\b.*$',
      caseSensitive: false,
    );

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.contains('....')) continue;
      if (headingRegex.hasMatch(line) && line.length < 90) {
        if (i + 1 < lines.length &&
            lines[i + 1].length < 75 &&
            !lines[i + 1].endsWith('.')) {
          return '$line: ${lines[i + 1]}';
        }
        return line;
      }
    }
    return null;
  }

  static void pdfExtractionIsolateEntry(PdfIsolatePayload payload) {
    try {
      final pdfDocument = PdfDocument(inputBytes: payload.pdfBytes);
      final totalPages = pdfDocument.pages.count;

      payload.sendPort.send({
        'type': 'progress',
        'current': 0,
        'total': totalPages,
        'percent': 2,
      });

      final extractor = PdfTextExtractor(pdfDocument);
      final List<String> pageTexts = List.filled(totalPages, '');
      final List<String?> detectedHeadings = List.filled(totalPages, null);

      int reportInterval = max(1, totalPages ~/ 25);
      for (int p = 0; p < totalPages; p++) {
        final raw = extractor.extractText(startPageIndex: p, endPageIndex: p);
        if (!_isTableOfContentsPage(raw) && !TextSanitizer.isLegalCopyrightPage(raw)) {
          final cleaned = TextSanitizer.sanitizeExtractedText(raw);
          pageTexts[p] = cleaned;
          detectedHeadings[p] = _detectChapterHeadingOnPage(raw);
        }

        if (p % reportInterval == 0 || p == totalPages - 1) {
          final int pct = (((p + 1) / totalPages) * 90).round().clamp(3, 92);
          payload.sendPort.send({
            'type': 'progress',
            'current': p + 1,
            'total': totalPages,
            'percent': pct,
          });
        }
      }

      pdfDocument.dispose();

      final List<int> headingPages = [];
      for (int p = 0; p < totalPages; p++) {
        if (detectedHeadings[p] != null && pageTexts[p].length > 80) {
          if (headingPages.isEmpty || (p - headingPages.last) >= 2) {
            headingPages.add(p);
          }
        }
      }

      final List<Map<String, dynamic>> chapters = [];

      if (headingPages.length >= 2) {
        if (headingPages.first > 0) {
          final preText = pageTexts
              .sublist(0, headingPages.first)
              .where((t) => t.isNotEmpty)
              .join('\n\n')
              .trim();
          if (preText.length > 120) {
            final words = preText.split(RegExp(r'\s+')).length;
            final mins = max(1, (words / 140).round());
            chapters.add({
              'id': 1,
              'title': '01. Apertura y Presentación',
              'subtitle': 'Págs. 1-${headingPages.first}',
              'durationText': '$mins min',
              'textContent': preText,
            });
          }
        }

        for (int k = 0; k < headingPages.length; k++) {
          final int startP = headingPages[k];
          final int endP =
              (k + 1 < headingPages.length) ? headingPages[k + 1] - 1 : totalPages - 1;
          final String headingTitle = detectedHeadings[startP]!;
          final String combinedText = pageTexts
              .sublist(startP, endP + 1)
              .where((t) => t.isNotEmpty)
              .join('\n\n')
              .trim();

          if (combinedText.isNotEmpty) {
            final int pageSpan = endP - startP + 1;
            if (pageSpan > 24) {
              int partNum = 1;
              for (int sp = startP; sp <= endP; sp += 12) {
                final int se = min(sp + 11, endP);
                final partText = pageTexts
                    .sublist(sp, se + 1)
                    .where((t) => t.isNotEmpty)
                    .join('\n\n')
                    .trim();
                if (partText.isNotEmpty) {
                  final words = partText.split(RegExp(r'\s+')).length;
                  final mins = max(1, (words / 140).round());
                  final id = chapters.length + 1;
                  chapters.add({
                    'id': id,
                    'title':
                        '${id.toString().padLeft(2, '0')}. $headingTitle (Parte $partNum)',
                    'subtitle': 'Págs. ${sp + 1}-${se + 1}',
                    'durationText': '$mins min',
                    'textContent': partText,
                  });
                  partNum++;
                }
              }
            } else {
              final words = combinedText.split(RegExp(r'\s+')).length;
              final mins = max(1, (words / 140).round());
              final id = chapters.length + 1;
              chapters.add({
                'id': id,
                'title': '${id.toString().padLeft(2, '0')}. $headingTitle',
                'subtitle': 'Págs. ${startP + 1}-${endP + 1}',
                'durationText': '$mins min',
                'textContent': combinedText,
              });
            }
          }
        }
      } else {
        int step = (totalPages > 300)
            ? 10
            : (totalPages > 100)
                ? 8
                : (totalPages > 25 ? 5 : 2);
        if (step < 1) step = 1;

        for (int i = 0; i < totalPages; i += step) {
          final int end = min(i + step - 1, totalPages - 1);
          final blockText = pageTexts
              .sublist(i, end + 1)
              .where((t) => t.isNotEmpty)
              .join('\n\n')
              .trim();

          if (blockText.isNotEmpty) {
            final wordsCount = blockText.split(RegExp(r'\s+')).length;
            final estMinutes = max(1, (wordsCount / 140).round());
            final id = chapters.length + 1;

            chapters.add({
              'id': id,
              'title': 'Sección $id',
              'subtitle': 'Págs. ${i + 1}-${end + 1}',
              'durationText': '$estMinutes min',
              'textContent': blockText,
            });
          }
        }
      }

      payload.sendPort.send({
        'type': 'progress',
        'current': totalPages,
        'total': totalPages,
        'percent': 100,
      });

      payload.sendPort.send({
        'type': 'done',
        'total': totalPages,
        'chapters': chapters,
      });
    } catch (e) {
      payload.sendPort.send({
        'type': 'error',
        'message': e.toString(),
      });
    }
  }
}
