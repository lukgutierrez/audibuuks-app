import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../domain/models/book_item.dart';
import '../../domain/models/chapter_item.dart';
import 'tts_synthesis_service.dart';

enum DownloadStatus { idle, downloading, paused, completed, error }

class ChapterDownloadProgress {
  final int chapterId;
  final int totalSegments;
  final int downloadedSegments;
  final DownloadStatus status;
  final String? errorMessage;

  ChapterDownloadProgress({
    required this.chapterId,
    required this.totalSegments,
    required this.downloadedSegments,
    required this.status,
    this.errorMessage,
  });

  double get progressRatio =>
      totalSegments > 0 ? (downloadedSegments / totalSegments).clamp(0.0, 1.0) : 0.0;
}

/// Administrador centralizado de descargas Offline para capítulos y libros completos
class OfflineDownloadService extends ChangeNotifier {
  static final OfflineDownloadService _instance = OfflineDownloadService._internal();
  factory OfflineDownloadService() => _instance;
  OfflineDownloadService._internal();

  final TtsSynthesisService _ttsService = TtsSynthesisService();
  final Map<String, ChapterDownloadProgress> _chapterProgress = {};
  final Set<String> _cancelTokens = {};
  String? _activeDownloadingBookId;
  int _activeBookTotalChapters = 0;
  int _activeBookCompletedChapters = 0;

  bool isBookDownloading(String bookId) => _activeDownloadingBookId == bookId;

  ({int completed, int total, double ratio})? getBookDownloadProgress(String bookId) {
    if (_activeDownloadingBookId != bookId || _activeBookTotalChapters == 0) return null;
    return (
      completed: _activeBookCompletedChapters,
      total: _activeBookTotalChapters,
      ratio: (_activeBookCompletedChapters / _activeBookTotalChapters).clamp(0.0, 1.0),
    );
  }

  String _progressKey(String bookId, int chapterId) => '${bookId}_ch_$chapterId';

  ChapterDownloadProgress? getProgress(String bookId, int chapterId) {
    return _chapterProgress[_progressKey(bookId, chapterId)];
  }

  bool isChapterDownloading(String bookId, int chapterId) {
    final p = getProgress(bookId, chapterId);
    return p?.status == DownloadStatus.downloading;
  }

  /// Verifica si todos los segmentos de un capítulo están descargados físicamente en el teléfono
  Future<bool> isChapterFullyDownloaded({
    required String bookId,
    required ChapterItem chapter,
    required String voiceKey,
    String? language,
  }) async {
    final key = _progressKey(bookId, chapter.id);
    if (_chapterProgress[key]?.status == DownloadStatus.completed) {
      return true;
    }

    final lang = language ?? (voiceKey.startsWith('en-') ? 'en' : 'es');
    final segs = chapter.getSegmentsForLanguage(lang);
    if (segs.isEmpty) return false;

    for (int i = 0; i < segs.length; i++) {
      final cached = await _ttsService.isSegmentCached(
        bookId: bookId,
        chapter: chapter,
        segIdx: i,
        voiceKey: voiceKey,
        text: segs[i],
      );
      if (!cached) return false;
    }

    _chapterProgress[key] = ChapterDownloadProgress(
      chapterId: chapter.id,
      totalSegments: segs.length,
      downloadedSegments: segs.length,
      status: DownloadStatus.completed,
    );
    return true;
  }

  /// Verifica cuántos capítulos de un libro están completamente descargados
  Future<int> getDownloadedChaptersCount({
    required BookItem book,
    required String voiceKey,
  }) async {
    int count = 0;
    for (final ch in book.chapters) {
      if (await isChapterFullyDownloaded(
        bookId: book.id,
        chapter: ch,
        voiceKey: voiceKey,
        language: book.activeAudioLanguage,
      )) {
        count++;
      }
    }
    return count;
  }

  /// Inicia la descarga completa de un capítulo en segundo plano (lotes de a 3 en paralelo)
  Future<void> downloadChapter({
    required String bookId,
    required ChapterItem chapter,
    required String voiceKey,
    String? language,
  }) async {
    final key = _progressKey(bookId, chapter.id);
    _cancelTokens.remove(key);

    final lang = language ?? (voiceKey.startsWith('en-') ? 'en' : 'es');
    final segs = chapter.getSegmentsForLanguage(lang);
    if (segs.isEmpty) return;

    // Calcular cuántos ya están descargados para reanudar desde donde quedó
    int downloaded = 0;
    for (int i = 0; i < segs.length; i++) {
      if (await _ttsService.isSegmentCached(
        bookId: bookId,
        chapter: chapter,
        segIdx: i,
        voiceKey: voiceKey,
        text: segs[i],
      )) {
        downloaded++;
      }
    }

    _chapterProgress[key] = ChapterDownloadProgress(
      chapterId: chapter.id,
      totalSegments: segs.length,
      downloadedSegments: downloaded,
      status: downloaded >= segs.length ? DownloadStatus.completed : DownloadStatus.downloading,
    );
    notifyListeners();

    if (downloaded >= segs.length) return;

    const int batchSize = 3;
    for (int i = 0; i < segs.length; i += batchSize) {
      if (_cancelTokens.contains(key)) {
        _chapterProgress[key] = ChapterDownloadProgress(
          chapterId: chapter.id,
          totalSegments: segs.length,
          downloadedSegments: downloaded,
          status: DownloadStatus.paused,
        );
        notifyListeners();
        return;
      }

      final int end = min(i + batchSize, segs.length);
      final List<int> neededIndices = [];

      for (int k = i; k < end; k++) {
        final isAlready = await _ttsService.isSegmentCached(
          bookId: bookId,
          chapter: chapter,
          segIdx: k,
          voiceKey: voiceKey,
          text: segs[k],
        );
        if (!isAlready) {
          neededIndices.add(k);
        }
      }

      if (neededIndices.isNotEmpty) {
        try {
          await Future.wait(
            neededIndices.map(
              (idx) => _ttsService.synthesizeSegment(
                bookId: bookId,
                chapter: chapter,
                segIdx: idx,
                text: segs[idx],
                voiceKey: voiceKey,
              ),
            ),
          );
          downloaded += neededIndices.length;
        } catch (e) {
          _chapterProgress[key] = ChapterDownloadProgress(
            chapterId: chapter.id,
            totalSegments: segs.length,
            downloadedSegments: downloaded,
            status: DownloadStatus.error,
            errorMessage: 'Error de conexión',
          );
          notifyListeners();
          return;
        }
      }

      _chapterProgress[key] = ChapterDownloadProgress(
        chapterId: chapter.id,
        totalSegments: segs.length,
        downloadedSegments: downloaded,
        status: DownloadStatus.downloading,
      );
      notifyListeners();
    }

    _chapterProgress[key] = ChapterDownloadProgress(
      chapterId: chapter.id,
      totalSegments: segs.length,
      downloadedSegments: segs.length,
      status: DownloadStatus.completed,
    );
    notifyListeners();
  }

  /// Cancela o pausa una descarga activa
  void cancelDownload(String bookId, int chapterId) {
    final key = _progressKey(bookId, chapterId);
    _cancelTokens.add(key);
  }

  /// Descarga el libro completo capítulo a capítulo
  Future<void> downloadEntireBook({
    required BookItem book,
    required String voiceKey,
    void Function(int currentChapter, int totalChapters)? onBookProgress,
  }) async {
    _activeDownloadingBookId = book.id;
    _activeBookTotalChapters = book.chapters.length;
    _activeBookCompletedChapters = 0;
    notifyListeners();

    try {
      for (int i = 0; i < book.chapters.length; i++) {
        if (_cancelTokens.contains(book.id)) {
          break;
        }
        final ch = book.chapters[i];
        onBookProgress?.call(i + 1, book.chapters.length);
        await downloadChapter(
          bookId: book.id,
          chapter: ch,
          voiceKey: voiceKey,
          language: book.activeAudioLanguage,
        );
        _activeBookCompletedChapters = i + 1;
        notifyListeners();
      }
    } finally {
      _activeDownloadingBookId = null;
      _activeBookTotalChapters = 0;
      _activeBookCompletedChapters = 0;
      _cancelTokens.remove(book.id);
      notifyListeners();
    }
  }

  /// Elimina los archivos descargados de un capítulo para liberar espacio
  Future<void> deleteChapterDownload({
    required String bookId,
    required ChapterItem chapter,
    required String voiceKey,
    String? language,
  }) async {
    final key = _progressKey(bookId, chapter.id);
    cancelDownload(bookId, chapter.id);

    final lang = language ?? (voiceKey.startsWith('en-') ? 'en' : 'es');
    final segs = chapter.getSegmentsForLanguage(lang);
    for (int i = 0; i < segs.length; i++) {
      final segKey = _ttsService.segmentKeyId(bookId, chapter, i, voiceKey, text: segs[i]);
      final mp3File = await _ttsService.getSegmentFilePublic(bookId, segKey);
      final wordsFile = await _ttsService.getSegmentWordsFilePublic(bookId, segKey);
      if (await mp3File.exists()) {
        try {
          await mp3File.delete();
        } catch (_) {}
      }
      if (await wordsFile.exists()) {
        try {
          await wordsFile.delete();
        } catch (_) {}
      }
    }

    _chapterProgress.remove(key);
    notifyListeners();
  }
}
