import 'dart:async';
import 'dart:io';
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
  }) async {
    final segs = chapter.segments;
    if (segs.isEmpty) return false;

    for (int i = 0; i < segs.length; i++) {
      final cached = await _ttsService.isSegmentCached(
        bookId: bookId,
        chapter: chapter,
        segIdx: i,
        voiceKey: voiceKey,
      );
      if (!cached) return false;
    }
    return true;
  }

  /// Verifica cuántos capítulos de un libro están completamente descargados
  Future<int> getDownloadedChaptersCount({
    required BookItem book,
    required String voiceKey,
  }) async {
    int count = 0;
    for (final ch in book.chapters) {
      if (await isChapterFullyDownloaded(bookId: book.id, chapter: ch, voiceKey: voiceKey)) {
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
  }) async {
    final key = _progressKey(bookId, chapter.id);
    _cancelTokens.remove(key);

    final segs = chapter.segments;
    if (segs.isEmpty) return;

    // Calcular cuántos ya están descargados para reanudar desde donde quedó
    int downloaded = 0;
    for (int i = 0; i < segs.length; i++) {
      if (await _ttsService.isSegmentCached(
        bookId: bookId,
        chapter: chapter,
        segIdx: i,
        voiceKey: voiceKey,
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
    for (int i = 0; i < book.chapters.length; i++) {
      final ch = book.chapters[i];
      onBookProgress?.call(i + 1, book.chapters.length);
      await downloadChapter(
        bookId: book.id,
        chapter: ch,
        voiceKey: voiceKey,
      );
    }
  }

  /// Elimina los archivos descargados de un capítulo para liberar espacio
  Future<void> deleteChapterDownload({
    required String bookId,
    required ChapterItem chapter,
    required String voiceKey,
  }) async {
    final key = _progressKey(bookId, chapter.id);
    cancelDownload(bookId, chapter.id);

    final segs = chapter.segments;
    for (int i = 0; i < segs.length; i++) {
      final segKey = _ttsService.segmentKeyId(bookId, chapter, i, voiceKey);
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
