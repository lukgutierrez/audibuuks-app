import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../domain/models/book_item.dart';
import '../../domain/models/chapter_item.dart';
import 'native_channel_service.dart';
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
/// con soporte de ejecución en segundo plano (pantalla bloqueada) y notificación nativa de progreso.
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

  bool get hasAnyActiveDownload =>
      _activeDownloadingBookId != null ||
      _chapterProgress.values.any((p) => p.status == DownloadStatus.downloading);

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

  /// Inicia la descarga completa de un capítulo en segundo plano con WakeLock y Notificación Nativa
  Future<void> downloadChapter({
    required String bookId,
    required ChapterItem chapter,
    required String voiceKey,
    String? language,
    bool partOfFullBookDownload = false,
    String? bookTitlePrefix,
  }) async {
    final key = _progressKey(bookId, chapter.id);
    _cancelTokens.remove(key);

    final lang = language ?? (voiceKey.startsWith('en-') ? 'en' : 'es');
    final segs = chapter.getSegmentsForLanguage(lang);
    if (segs.isEmpty) return;

    await NativeChannelService.acquireBackgroundLock();

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

    if (downloaded >= segs.length) {
      if (!partOfFullBookDownload && !hasAnyActiveDownload) {
        await NativeChannelService.releaseBackgroundLock();
      }
      return;
    }

    final String notifTitle = bookTitlePrefix != null
        ? 'Descargando $bookTitlePrefix'
        : 'Descargando ${chapter.title}';

    await NativeChannelService.updateDownloadNotification(
      title: notifTitle,
      subtitle:
          '${chapter.title} • $downloaded de ${segs.length} párrafos (${((downloaded / segs.length) * 100).round()}%)',
      progress: downloaded,
      maxProgress: segs.length,
      ongoing: true,
    );

    const int batchSize = 2;
    for (int i = 0; i < segs.length; i += batchSize) {
      if (_cancelTokens.contains(key) || _cancelTokens.contains(bookId)) {
        _chapterProgress[key] = ChapterDownloadProgress(
          chapterId: chapter.id,
          totalSegments: segs.length,
          downloadedSegments: downloaded,
          status: DownloadStatus.paused,
        );
        notifyListeners();
        if (!partOfFullBookDownload && !hasAnyActiveDownload) {
          await NativeChannelService.cancelDownloadNotification();
        }
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
        bool batchSuccess = false;
        for (int retry = 1; retry <= 6; retry++) {
          if (_cancelTokens.contains(key) || _cancelTokens.contains(bookId)) break;
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
            batchSuccess = true;
            break;
          } catch (_) {
            if (retry < 6) {
              await NativeChannelService.updateDownloadNotification(
                title: notifTitle,
                subtitle: 'Señal débil • Reintentando automáticamente ($retry/6)...',
                progress: downloaded,
                maxProgress: segs.length,
                ongoing: true,
              );
              await Future<void>.delayed(Duration(milliseconds: 1200 * retry));
            }
          }
        }

        if (!batchSuccess) {
          _chapterProgress[key] = ChapterDownloadProgress(
            chapterId: chapter.id,
            totalSegments: segs.length,
            downloadedSegments: downloaded,
            status: DownloadStatus.error,
            errorMessage: 'Error de conexión',
          );
          notifyListeners();
          if (!partOfFullBookDownload) {
            await NativeChannelService.updateDownloadNotification(
              title: 'Descarga en pausa (${chapter.title})',
              subtitle: 'Sin conexión estable. Tocá para reanudar cuando vuelva la señal.',
              progress: downloaded,
              maxProgress: segs.length,
              ongoing: false,
            );
          }
          return;
        }

        downloaded += neededIndices.length;
      }

      final int pct = ((downloaded / segs.length) * 100).clamp(0, 100).round();
      _chapterProgress[key] = ChapterDownloadProgress(
        chapterId: chapter.id,
        totalSegments: segs.length,
        downloadedSegments: downloaded,
        status: DownloadStatus.downloading,
      );
      notifyListeners();

      await NativeChannelService.updateDownloadNotification(
        title: notifTitle,
        subtitle: '${chapter.title} • $downloaded/${segs.length} párrafos ($pct%)',
        progress: downloaded,
        maxProgress: segs.length,
        ongoing: true,
      );
    }

    _chapterProgress[key] = ChapterDownloadProgress(
      chapterId: chapter.id,
      totalSegments: segs.length,
      downloadedSegments: segs.length,
      status: DownloadStatus.completed,
    );
    notifyListeners();

    if (!partOfFullBookDownload) {
      await NativeChannelService.updateDownloadNotification(
        title: 'Descarga completada ✅',
        subtitle: '${chapter.title} ya está listo para escuchar sin internet',
        progress: segs.length,
        maxProgress: segs.length,
        ongoing: false,
      );
    }
  }

  /// Cancela o pausa una descarga activa
  void cancelDownload(String bookId, int chapterId) {
    if (chapterId == -1) {
      _cancelTokens.add(bookId);
      for (final entry in _chapterProgress.keys) {
        if (entry.startsWith('${bookId}_ch_')) {
          _cancelTokens.add(entry);
        }
      }
    } else {
      final key = _progressKey(bookId, chapterId);
      _cancelTokens.add(key);
    }
    NativeChannelService.cancelDownloadNotification();
  }

  /// Descarga el libro completo capítulo a capítulo en segundo plano
  Future<void> downloadEntireBook({
    required BookItem book,
    required String voiceKey,
    void Function(int currentChapter, int totalChapters)? onBookProgress,
  }) async {
    _cancelTokens.remove(book.id);
    _activeDownloadingBookId = book.id;
    _activeBookTotalChapters = book.chapters.length;
    _activeBookCompletedChapters = 0;
    notifyListeners();

    await NativeChannelService.acquireBackgroundLock();

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
          partOfFullBookDownload: true,
          bookTitlePrefix: '${book.title} (Cap. ${i + 1}/${book.chapters.length})',
        );
        _activeBookCompletedChapters = i + 1;
        notifyListeners();
      }

      if (!_cancelTokens.contains(book.id)) {
        await NativeChannelService.updateDownloadNotification(
          title: 'Audiolibro descargado al 100% ✅',
          subtitle: '"${book.title}" está listo para escuchar sin conexión',
          progress: book.chapters.length,
          maxProgress: book.chapters.length,
          ongoing: false,
        );
      }
    } finally {
      _activeDownloadingBookId = null;
      _activeBookTotalChapters = 0;
      _activeBookCompletedChapters = 0;
      _cancelTokens.remove(book.id);
      if (!hasAnyActiveDownload) {
        await NativeChannelService.releaseBackgroundLock();
      }
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
