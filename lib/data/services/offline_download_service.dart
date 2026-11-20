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

/// Administrador centralizado de descargas Offline de alta velocidad (pool deslizante de 5 hilos)
/// con soporte en segundo plano (pantalla bloqueada) y notificación nativa optimizada.
class OfflineDownloadService extends ChangeNotifier {
  static final OfflineDownloadService _instance = OfflineDownloadService._internal();
  factory OfflineDownloadService() => _instance;
  OfflineDownloadService._internal();

  static const int _maxConcurrentWorkers = 5;

  final TtsSynthesisService _ttsService = TtsSynthesisService();
  final Map<String, ChapterDownloadProgress> _chapterProgress = {};
  final Map<String, bool> _completedChapterCache = {};
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

  String _completedCacheKey(String bookId, int chapterId, String voiceKey, String lang) =>
      '${bookId}_ch_${chapterId}_${voiceKey}_$lang';

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

  /// Devuelve instantáneamente los IDs de capítulos 100% descargados usando un único escaneo de carpeta.
  Future<Set<int>> getDownloadedChapterIds({
    required BookItem book,
    required String voiceKey,
  }) async {
    final Set<int> completedIds = {};
    final cachedKeys = await _ttsService.getCachedKeysForBook(book.id);
    final lang = book.activeAudioLanguage;

    for (final ch in book.chapters) {
      final segs = ch.getSegmentsForLanguage(lang);
      if (segs.isEmpty) continue;

      bool allCached = true;
      for (int i = 0; i < segs.length; i++) {
        final segKey = _ttsService.segmentKeyId(book.id, ch, i, voiceKey, text: segs[i]);
        if (!cachedKeys.contains(segKey)) {
          allCached = false;
          break;
        }
      }

      final cacheKey = _completedCacheKey(book.id, ch.id, voiceKey, lang);
      _completedChapterCache[cacheKey] = allCached;

      if (allCached) {
        completedIds.add(ch.id);
        final pKey = _progressKey(book.id, ch.id);
        if (_chapterProgress[pKey]?.status != DownloadStatus.downloading) {
          _chapterProgress[pKey] = ChapterDownloadProgress(
            chapterId: ch.id,
            totalSegments: segs.length,
            downloadedSegments: segs.length,
            status: DownloadStatus.completed,
          );
        }
      }
    }
    return completedIds;
  }

  /// Verifica si todos los segmentos de un capítulo están descargados físicamente en el teléfono
  Future<bool> isChapterFullyDownloaded({
    required String bookId,
    required ChapterItem chapter,
    required String voiceKey,
    String? language,
  }) async {
    final lang = language ?? (voiceKey.startsWith('en-') ? 'en' : 'es');
    final cacheKey = _completedCacheKey(bookId, chapter.id, voiceKey, lang);
    if (_completedChapterCache[cacheKey] == true) {
      return true;
    }

    final key = _progressKey(bookId, chapter.id);
    if (_chapterProgress[key]?.status == DownloadStatus.completed) {
      _completedChapterCache[cacheKey] = true;
      return true;
    }

    final segs = chapter.getSegmentsForLanguage(lang);
    if (segs.isEmpty) return false;

    final cachedKeys = await _ttsService.getCachedKeysForBook(bookId);
    for (int i = 0; i < segs.length; i++) {
      final segKey = _ttsService.segmentKeyId(bookId, chapter, i, voiceKey, text: segs[i]);
      if (!cachedKeys.contains(segKey)) {
        final fallbackCached = await _ttsService.isSegmentCached(
          bookId: bookId,
          chapter: chapter,
          segIdx: i,
          voiceKey: voiceKey,
          text: segs[i],
        );
        if (!fallbackCached) {
          _completedChapterCache[cacheKey] = false;
          return false;
        }
      }
    }

    _completedChapterCache[cacheKey] = true;
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
    final ids = await getDownloadedChapterIds(book: book, voiceKey: voiceKey);
    return ids.length;
  }

  /// Inicia la descarga completa de un capítulo con pool concurrente de 5 workers (3x-4x más rápido)
  Future<void> downloadChapter({
    required String bookId,
    required ChapterItem chapter,
    required String voiceKey,
    String? language,
    bool partOfFullBookDownload = false,
    String? bookTitlePrefix,
  }) async {
    final key = _progressKey(bookId, chapter.id);
    if (isChapterDownloading(bookId, chapter.id)) return;

    _cancelTokens.remove(key);
    final lang = language ?? (voiceKey.startsWith('en-') ? 'en' : 'es');
    final cacheKey = _completedCacheKey(bookId, chapter.id, voiceKey, lang);
    final segs = chapter.getSegmentsForLanguage(lang);
    if (segs.isEmpty) return;

    await NativeChannelService.acquireBackgroundLock();

    // Escaneo rápido en 1 sola llamada OS para detectar qué párrafos faltan
    final cachedKeys = await _ttsService.getCachedKeysForBook(bookId);
    final List<int> pendingIndices = [];
    for (int i = 0; i < segs.length; i++) {
      final segKey = _ttsService.segmentKeyId(bookId, chapter, i, voiceKey, text: segs[i]);
      if (!cachedKeys.contains(segKey)) {
        pendingIndices.add(i);
      }
    }

    int downloaded = segs.length - pendingIndices.length;

    _chapterProgress[key] = ChapterDownloadProgress(
      chapterId: chapter.id,
      totalSegments: segs.length,
      downloadedSegments: downloaded,
      status: pendingIndices.isEmpty ? DownloadStatus.completed : DownloadStatus.downloading,
    );
    if (pendingIndices.isEmpty) {
      _completedChapterCache[cacheKey] = true;
    }
    notifyListeners();

    if (pendingIndices.isEmpty) {
      if (!partOfFullBookDownload && !hasAnyActiveDownload) {
        await NativeChannelService.releaseBackgroundLock();
      }
      return;
    }

    final String notifTitle = bookTitlePrefix != null
        ? 'Descargando $bookTitlePrefix'
        : 'Descargando ${chapter.title}';

    unawaited(
      NativeChannelService.updateDownloadNotification(
        title: notifTitle,
        subtitle:
            '${chapter.title} • $downloaded/${segs.length} párrafos (${((downloaded / segs.length) * 100).round()}%)',
        progress: downloaded,
        maxProgress: segs.length,
        ongoing: true,
      ),
    );

    int queueCursor = 0;
    int failedCount = 0;
    DateTime lastUiNotify = DateTime.now();
    DateTime lastNotifUpdate = DateTime.now();

    void publishProgress({bool force = false}) {
      final now = DateTime.now();
      _chapterProgress[key] = ChapterDownloadProgress(
        chapterId: chapter.id,
        totalSegments: segs.length,
        downloadedSegments: downloaded,
        status: DownloadStatus.downloading,
      );

      if (force || now.difference(lastUiNotify).inMilliseconds >= 180) {
        lastUiNotify = now;
        notifyListeners();
      }

      if (force || now.difference(lastNotifUpdate).inMilliseconds >= 650) {
        lastNotifUpdate = now;
        final int pct = ((downloaded / segs.length) * 100).clamp(0, 100).round();
        unawaited(
          NativeChannelService.updateDownloadNotification(
            title: notifTitle,
            subtitle: '${chapter.title} • $downloaded/${segs.length} párrafos ($pct%)',
            progress: downloaded,
            maxProgress: segs.length,
            ongoing: true,
          ),
        );
      }
    }

    Future<void> runWorker() async {
      while (true) {
        if (_cancelTokens.contains(key) || _cancelTokens.contains(bookId)) {
          return;
        }
        if (queueCursor >= pendingIndices.length) return;
        final int segIdx = pendingIndices[queueCursor++];

        bool segOk = false;
        const retryDelaysMs = [400, 900, 1800, 3000];
        for (int attempt = 0; attempt <= retryDelaysMs.length; attempt++) {
          if (_cancelTokens.contains(key) || _cancelTokens.contains(bookId)) {
            return;
          }
          try {
            await _ttsService.synthesizeSegment(
              bookId: bookId,
              chapter: chapter,
              segIdx: segIdx,
              text: segs[segIdx],
              voiceKey: voiceKey,
            );
            segOk = true;
            break;
          } catch (_) {
            if (attempt < retryDelaysMs.length) {
              await Future<void>.delayed(Duration(milliseconds: retryDelaysMs[attempt]));
            }
          }
        }

        if (_cancelTokens.contains(key) || _cancelTokens.contains(bookId)) {
          return;
        }

        if (segOk) {
          downloaded++;
          publishProgress();
        } else {
          failedCount++;
        }
      }
    }

    final int workerCount = min(_maxConcurrentWorkers, pendingIndices.length);
    await Future.wait(List.generate(workerCount, (_) => runWorker()));

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

    if (failedCount > 0 || downloaded < segs.length) {
      _completedChapterCache[cacheKey] = false;
      _chapterProgress[key] = ChapterDownloadProgress(
        chapterId: chapter.id,
        totalSegments: segs.length,
        downloadedSegments: downloaded,
        status: DownloadStatus.error,
        errorMessage: 'Faltaron ${segs.length - downloaded} párrafos por señal inestable',
      );
      notifyListeners();
      if (!partOfFullBookDownload) {
        await NativeChannelService.updateDownloadNotification(
          title: 'Descarga incompleta (${chapter.title})',
          subtitle: '$downloaded/${segs.length} guardados • Tocá para reanudar lo que falta.',
          progress: downloaded,
          maxProgress: segs.length,
          ongoing: false,
        );
      }
      return;
    }

    _completedChapterCache[cacheKey] = true;
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
    notifyListeners();
    if (!hasAnyActiveDownload || chapterId == -1) {
      NativeChannelService.cancelDownloadNotification();
    }
  }

  /// Descarga el libro completo capítulo a capítulo en segundo plano
  Future<void> downloadEntireBook({
    required BookItem book,
    required String voiceKey,
    void Function(int currentChapter, int totalChapters)? onBookProgress,
  }) async {
    if (_activeDownloadingBookId == book.id) return;

    _cancelTokens.remove(book.id);
    _activeDownloadingBookId = book.id;
    _activeBookTotalChapters = book.chapters.length;
    _activeBookCompletedChapters = 0;
    notifyListeners();

    await NativeChannelService.acquireBackgroundLock();

    try {
      int errorChapters = 0;
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
        if (getProgress(book.id, ch.id)?.status == DownloadStatus.error) {
          errorChapters++;
        } else {
          _activeBookCompletedChapters++;
        }
        notifyListeners();
      }

      if (!_cancelTokens.contains(book.id)) {
        await NativeChannelService.updateDownloadNotification(
          title: errorChapters == 0
              ? 'Audiolibro descargado al 100% ✅'
              : 'Descarga finalizada con avisos',
          subtitle: errorChapters == 0
              ? '"${book.title}" está listo para escuchar sin conexión'
              : '$_activeBookCompletedChapters/${book.chapters.length} capítulos completos. Tocá para reintentar los faltantes.',
          progress: _activeBookCompletedChapters,
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
    _completedChapterCache[_completedCacheKey(bookId, chapter.id, voiceKey, lang)] = false;

    final segs = chapter.getSegmentsForLanguage(lang);
    for (int i = 0; i < segs.length; i++) {
      final segKey = _ttsService.segmentKeyId(bookId, chapter, i, voiceKey, text: segs[i]);
      _ttsService.markKeyRemovedFromCache(segKey);
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
