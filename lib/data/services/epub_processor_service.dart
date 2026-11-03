import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../domain/models/book_item.dart';
import '../../domain/models/chapter_item.dart';
import 'cover_service.dart';
import 'native_channel_service.dart';

/// Motor de extracción y estructuración nativa para libros .EPUB
class EpubProcessorService {
  static Future<BookItem?> processEpubFile({
    required String filePath,
    required String bookId,
    required String originalFileName,
    required void Function(int pct, String status, String detail) onProgress,
  }) async {
    onProgress(5, 'Leyendo archivo EPUB...', originalFileName);
    final res = await NativeChannelService.extractEpub(filePath);
    if (res == null) {
      throw Exception('No se pudo procesar la estructura interna del EPUB.');
    }

    onProgress(25, 'Extrayendo portada e índice...', 'Buscando portada original en alta definición');
    final Uint8List? coverBytes = res['coverBytes'] as Uint8List?;
    String? coverPath;
    if (coverBytes != null && coverBytes.isNotEmpty) {
      final docDir = await getApplicationDocumentsDirectory();
      final coversDir = Directory('${docDir.path}/covers');
      if (!await coversDir.exists()) await coversDir.create(recursive: true);
      final coverFile = File('${coversDir.path}/$bookId.jpg');
      await coverFile.writeAsBytes(coverBytes, flush: true);
      coverPath = coverFile.path;
    }

    final List<dynamic> rawChapters = (res['chaptersHtml'] as List<dynamic>?) ?? [];
    if (rawChapters.isEmpty) {
      throw Exception('El libro EPUB no contiene capítulos legibles.');
    }

    onProgress(45, 'Limpiando capítulos y formateando texto...', '0 / ${rawChapters.length}');
    final List<ChapterItem> chapters = [];
    int chId = 1;

    for (int i = 0; i < rawChapters.length; i++) {
      final String html = rawChapters[i].toString();
      final pct = 45 + ((i / rawChapters.length) * 45).round();
      onProgress(pct, 'Procesando capítulos...', 'Capítulo ${i + 1} de ${rawChapters.length}');

      String chapterTitle = _extractTitleFromHtml(html);
      String cleanText = _convertHtmlToCleanText(html);

      if (TextSanitizer.isLegalCopyrightPage(cleanText) || cleanText.trim().length < 50) {
        continue;
      }

      if (chapterTitle.isEmpty) {
        chapterTitle = 'Capítulo ${chId.toString().padLeft(2, '0')}';
      } else if (!RegExp(r'^\d+').hasMatch(chapterTitle)) {
        chapterTitle = '${chId.toString().padLeft(2, '0')}. $chapterTitle';
      }

      final words = cleanText.split(RegExp(r'\s+')).length;
      final mins = max(1, (words / 140).round());

      if (words > 12000) {
        final paragraphs = cleanText.split('\n\n');
        List<String> partBuffer = [];
        int partWords = 0;
        int subPart = 1;

        for (final p in paragraphs) {
          final pWords = p.split(RegExp(r'\s+')).length;
          partBuffer.add(p);
          partWords += pWords;
          if (partWords >= 5000) {
            final partText = partBuffer.join('\n\n');
            final pMins = max(1, (partWords / 140).round());
            chapters.add(
              ChapterItem(
                id: chId++,
                title: '$chapterTitle (Parte $subPart)',
                subtitle: '$pMins min de narración',
                durationText: '$pMins min',
                textContent: partText,
              ),
            );
            partBuffer = [];
            partWords = 0;
            subPart++;
          }
        }
        if (partBuffer.isNotEmpty) {
          final partText = partBuffer.join('\n\n');
          final pMins = max(1, (partWords / 140).round());
          chapters.add(
            ChapterItem(
              id: chId++,
              title: subPart > 1 ? '$chapterTitle (Parte $subPart)' : chapterTitle,
              subtitle: '$pMins min de narración',
              durationText: '$pMins min',
              textContent: partText,
            ),
          );
        }
      } else {
        chapters.add(
          ChapterItem(
            id: chId++,
            title: chapterTitle,
            subtitle: '$mins min de narración',
            durationText: '$mins min',
            textContent: cleanText,
          ),
        );
      }
    }

    if (chapters.isEmpty) {
      throw Exception('No se encontró contenido narrativo en el libro EPUB.');
    }

    onProgress(95, 'Finalizando preparación de libro...', '${chapters.length} capítulos listos');

    String fileNameNoExt = originalFileName;
    if (fileNameNoExt.toLowerCase().endsWith('.epub')) {
      fileNameNoExt = fileNameNoExt.substring(0, fileNameNoExt.length - 5);
    }
    final cleanTitle = CoverService.cleanSearchTitle(fileNameNoExt);
    final int totalMins = chapters.fold<int>(0, (sum, c) => sum + (c.estimatedTotalSeconds ~/ 60));
    final String totalTimeFormatted = totalMins >= 60
        ? '${totalMins ~/ 60} h ${totalMins % 60} min'
        : '$totalMins min';

    String? coverUrl;
    if (coverPath == null) {
      coverUrl = await CoverService.fetchOnlineCoverUrl(cleanTitle);
    }

    return BookItem(
      id: bookId,
      title: cleanTitle,
      author: 'Libro EPUB Completo',
      coverTag: '📖',
      totalTime: totalTimeFormatted,
      chapters: chapters,
      coverImagePath: coverPath,
      coverUrl: coverUrl,
      originalFilePath: filePath,
      fileType: 'epub',
    );
  }

  static String _extractTitleFromHtml(String html) {
    final h1Match =
        RegExp(r'<h[1-3][^>]*>(.*?)</h[1-3]>', caseSensitive: false, dotAll: true).firstMatch(html);
    if (h1Match != null) {
      final t = _stripTagsAndEntities(h1Match.group(1) ?? '');
      if (t.trim().isNotEmpty && t.trim().length < 80) return t.trim();
    }
    final titleMatch =
        RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
    if (titleMatch != null) {
      final t = _stripTagsAndEntities(titleMatch.group(1) ?? '');
      if (t.trim().isNotEmpty && !t.toLowerCase().contains('.xhtml') && t.trim().length < 80) {
        return t.trim();
      }
    }
    return '';
  }

  static String _convertHtmlToCleanText(String html) {
    var s = html
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(?:p|div|h[1-6]|li|blockquote)>', caseSensitive: false), '\n\n');

    s = _stripTagsAndEntities(s);
    return TextSanitizer.sanitizeExtractedText(s);
  }

  static String _stripTagsAndEntities(String text) {
    var s = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '...')
        .replaceAll('&iexcl;', '¡')
        .replaceAll('&iquest;', '¿')
        .replaceAll('&aacute;', 'á')
        .replaceAll('&eacute;', 'é')
        .replaceAll('&iacute;', 'í')
        .replaceAll('&oacute;', 'ó')
        .replaceAll('&uacute;', 'ú')
        .replaceAll('&ntilde;', 'ñ')
        .replaceAll('&Aacute;', 'Á')
        .replaceAll('&Eacute;', 'É')
        .replaceAll('&Iacute;', 'Í')
        .replaceAll('&Oacute;', 'Ó')
        .replaceAll('&Uacute;', 'Ú')
        .replaceAll('&Ntilde;', 'Ñ');

    s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      try {
        final code = int.parse(m.group(1)!, radix: 16);
        return String.fromCharCode(code);
      } catch (_) {
        return '';
      }
    });

    s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      try {
        final code = int.parse(m.group(1)!);
        return String.fromCharCode(code);
      } catch (_) {
        return '';
      }
    });

    return s;
  }
}
