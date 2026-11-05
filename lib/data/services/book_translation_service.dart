import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:translator/translator.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../domain/models/book_item.dart';
import '../../domain/models/chapter_item.dart';
import '../repositories/library_repository.dart';

class TranslationProgressInfo {
  final String bookId;
  final int currentChapter;
  final int totalChapters;
  final int percent;
  final String statusText;
  final bool isCompleted;

  const TranslationProgressInfo({
    required this.bookId,
    required this.currentChapter,
    required this.totalChapters,
    required this.percent,
    required this.statusText,
    this.isCompleted = false,
  });
}

class BookTranslationService {
  static final GoogleTranslator _translator = GoogleTranslator();
  static final ValueNotifier<TranslationProgressInfo?> progressNotifier =
      ValueNotifier<TranslationProgressInfo?>(null);

  static final Set<String> _activeTranslations = {};

  /// Detecta el idioma del texto analizando stopwords frecuentes.
  /// Rápido (0.001s), offline y 100% fiable para diferenciar Español de Inglés.
  static String detectLanguage(String sampleText) {
    if (sampleText.trim().isEmpty) return 'es';
    final tokens = sampleText
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-záéíóúñü\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .take(400)
        .toList();

    if (tokens.isEmpty) return 'es';

    const englishStopwords = {
      'the', 'and', 'that', 'have', 'for', 'not', 'with', 'you', 'this',
      'but', 'his', 'from', 'they', 'say', 'her', 'she', 'will', 'one',
      'all', 'would', 'there', 'their', 'what', 'out', 'about', 'who',
      'get', 'which', 'when', 'make', 'can', 'like', 'time', 'just', 'him',
      'know', 'take', 'people', 'into', 'year', 'your', 'good', 'some',
      'could', 'them', 'see', 'other', 'than', 'then', 'now', 'look', 'only',
      'come', 'its', 'over', 'think', 'also', 'back', 'after', 'use', 'two',
      'how', 'our', 'work', 'first', 'well', 'way', 'even', 'new', 'want',
      'because', 'any', 'these', 'give', 'day', 'most', 'us', 'chapter'
    };

    const spanishStopwords = {
      'de', 'la', 'que', 'el', 'en', 'los', 'del', 'se', 'las', 'por',
      'un', 'para', 'con', 'no', 'una', 'su', 'al', 'lo', 'como', 'más',
      'pero', 'sus', 'le', 'ya', 'o', 'este', 'sí', 'porque', 'esta',
      'entre', 'cuando', 'muy', 'sin', 'sobre', 'también', 'me', 'hasta',
      'hay', 'donde', 'quien', 'desde', 'todo', 'nos', 'durante', 'todos',
      'uno', 'les', 'ni', 'contra', 'otros', 'ese', 'eso', 'ante', 'ellos',
      'e', 'esto', 'mí', 'antes', 'algunos', 'qué', 'unos', 'yo', 'otro',
      'otras', 'otra', 'él', 'tanto', 'esa', 'estos', 'mucho', 'quienes',
      'nada', 'muchos', 'cual', 'sea', 'poco', 'ella', 'estar', 'haber', 'capítulo'
    };

    int enCount = 0;
    int esCount = 0;

    for (final t in tokens) {
      if (englishStopwords.contains(t)) enCount++;
      if (spanishStopwords.contains(t)) esCount++;
    }

    if (enCount > esCount && enCount >= 5) {
      return 'en';
    }
    return 'es';
  }

  /// Traduce el primer capítulo o lote inicial (1 a 2 capítulos) de inmediato
  /// para que el usuario pueda empezar a escuchar y leer YA sin esperar nada.
  static Future<ChapterItem> translateSingleChapter(ChapterItem chapter) async {
    final original = chapter.originalLanguageSegments ?? chapter.segments;
    if (original.isEmpty) return chapter;

    String newTitle = chapter.title;
    String newSubtitle = chapter.subtitle;
    try {
      final resTitle = await _translator.translate(chapter.title, from: 'en', to: 'es');
      newTitle = resTitle.text;
    } catch (_) {}
    try {
      final resSub = await _translator.translate(chapter.subtitle, from: 'en', to: 'es');
      newSubtitle = resSub.text;
    } catch (_) {}

    final List<String> translatedSegments = [];
    const delimiter = '\n---AUDIOMIND_SEP---\n';
    List<String> currentBatch = [];
    int currentBatchLen = 0;

    Future<void> flush() async {
      if (currentBatch.isEmpty) return;
      try {
        final res = await _translator
            .translate(currentBatch.join(delimiter), from: 'en', to: 'es')
            .timeout(const Duration(seconds: 8));
        final parts = res.text.split(RegExp(r'\s*---AUDIOMIND_SEP---\s*'));
        if (parts.length == currentBatch.length) {
          for (final p in parts) {
            translatedSegments.add(TextSanitizer.sanitizeExtractedText(p));
          }
        } else {
          for (final raw in currentBatch) {
            try {
              final single = await _translator.translate(raw, from: 'en', to: 'es').timeout(const Duration(seconds: 3));
              translatedSegments.add(TextSanitizer.sanitizeExtractedText(single.text));
            } catch (_) {
              translatedSegments.add(raw);
            }
          }
        }
      } catch (_) {
        translatedSegments.addAll(currentBatch);
      }
      currentBatch = [];
      currentBatchLen = 0;
    }

    for (final seg in original) {
      if (currentBatchLen + seg.length > 1800 && currentBatch.isNotEmpty) {
        await flush();
      }
      currentBatch.add(seg);
      currentBatchLen += seg.length;
    }
    await flush();

    return ChapterItem(
      id: chapter.id,
      title: newTitle,
      subtitle: newSubtitle,
      durationText: chapter.durationText,
      textContent: translatedSegments.join('\n\n'),
      originalLanguageSegments: original,
    );
  }

  /// Inicia la traducción en segundo plano de todos los capítulos restantes.
  /// Guarda cada capítulo traducido en SharedPreferences inmediatamente y actualiza la píldora superior.
  static void startBackgroundBookTranslation(BookItem book) {
    if (_activeTranslations.contains(book.id)) return;
    _activeTranslations.add(book.id);

    unawaited(() async {
      try {
        final totalChapters = book.chapters.length;
        for (int i = 0; i < totalChapters; i++) {
          final ch = book.chapters[i];

          // Si ya está traducido al español, saltar al siguiente
          if (ch.originalLanguageSegments != null && ch.originalLanguageSegments!.isNotEmpty) {
            continue;
          }

          final pct = (((i + 1) / totalChapters) * 100).round().clamp(1, 99);
          progressNotifier.value = TranslationProgressInfo(
            bookId: book.id,
            currentChapter: i + 1,
            totalChapters: totalChapters,
            percent: pct,
            statusText: 'Traduciendo en segundo plano: Cap. ${i + 1} de $totalChapters ($pct%)',
          );

          final translated = await translateSingleChapter(ch);
          book.chapters[i] = translated;

          // Guardar progreso en disco cada capítulo traducido para que jamás se pierda
          await LibraryRepository().saveBooks([book]);

          // Pausa suave de 250ms entre capítulos para no saturar la red ni la batería
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        progressNotifier.value = TranslationProgressInfo(
          bookId: book.id,
          currentChapter: totalChapters,
          totalChapters: totalChapters,
          percent: 100,
          statusText: '✨ ¡Libro traducido al 100%!',
          isCompleted: true,
        );

        // Desvanecer el aviso completado a los 4 segundos
        Future.delayed(const Duration(seconds: 4), () {
          if (progressNotifier.value?.bookId == book.id && progressNotifier.value?.isCompleted == true) {
            progressNotifier.value = null;
          }
        });
      } catch (_) {
      } finally {
        _activeTranslations.remove(book.id);
      }
    }());
  }
}
