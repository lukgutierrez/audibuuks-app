import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../domain/models/book_item.dart';
import '../../domain/models/chapter_item.dart';
import '../repositories/library_repository.dart';
import 'book_translation_service.dart';
import 'native_channel_service.dart';
import 'tts_synthesis_service.dart';

/// Singleton global de AudioPlayer requerido por `just_audio_background`.
final AudioPlayer globalAudioPlayer = AudioPlayer();

/// Instancia global del motor persistente de reproducción y Temporizador de Sueño (Sleep Timer).
final AudioPlayerService audioPlayerService = AudioPlayerService();

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  AudioPlayerService._internal() {
    _initBackgroundListeners();
  }

  final LibraryRepository _repository = LibraryRepository();
  final TtsSynthesisService _ttsService = TtsSynthesisService();

  BookItem? currentBook;
  ChapterItem? currentChapter;
  List<String> currentSegments = [];
  int currentSegmentIndex = 0;

  String selectedVoiceKey = 'es-MX-JorgeNeural';
  String selectedVoiceName = 'Jorge HD (México 🇲🇽 • Cálido)';
  double playbackSpeed = 1.0;
  double ambientVolume = 0.25;
  String selectedAmbientTrackId = NativeChannelService.currentTrackId;

  bool isPlaying = false;
  bool isSynthesizing = false;
  bool userRequestedPause = false;
  bool isPlayerScreenMounted = false;

  int _bgSynthesisGen = 0;
  int _bgPrefetchGen = 0;
  bool _isHandlingBgCompletion = false;
  int _lastSavedSecond = -1;

  // --- Estado del Temporizador de Sueño (Sleep Timer) ---
  Timer? _sleepTimer;
  int? _sleepRemainingSeconds;
  bool _sleepAtEndOfChapter = false;

  int? get sleepRemainingSeconds => _sleepRemainingSeconds;
  bool get sleepAtEndOfChapter => _sleepAtEndOfChapter;
  bool get isSleepTimerActive => _sleepRemainingSeconds != null || _sleepAtEndOfChapter;

  String get sleepTimerBadgeText {
    if (_sleepAtEndOfChapter) return 'Fin de cap.';
    final sec = _sleepRemainingSeconds;
    if (sec == null) return 'Off';
    final mins = sec ~/ 60;
    final remSec = sec % 60;
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return '${h}h ${m.toString().padLeft(2, '0')}m';
    }
    return '${mins.toString().padLeft(2, '0')}:${remSec.toString().padLeft(2, '0')}';
  }

  void _initBackgroundListeners() {
    globalAudioPlayer.playerStateStream.listen((state) {
      isPlaying = state.playing && !userRequestedPause;
      notifyListeners();

      // Si PlayerScreen está cerrado, el servicio toma el control de avanzar entre párrafos y capítulos
      if (!isPlayerScreenMounted) {
        if (userRequestedPause) {
          NativeChannelService.pauseLoFi();
          return;
        }
        if (state.playing && !isSynthesizing && ambientVolume > 0) {
          NativeChannelService.setLoFiVolume(ambientVolume);
          NativeChannelService.playLoFi();
        } else if (!state.playing) {
          NativeChannelService.pauseLoFi();
        }

        if (state.processingState == ProcessingState.completed &&
            !_isHandlingBgCompletion &&
            !isSynthesizing) {
          _onBackgroundSegmentCompleted();
        }
      }
    });

    globalAudioPlayer.positionStream.listen((pos) {
      if (!isPlayerScreenMounted && currentBook != null && currentChapter != null) {
        final sec = pos.inSeconds;
        if (sec != _lastSavedSecond && sec % 3 == 0) {
          _lastSavedSecond = sec;
          currentBook!.lastPositionMs = pos.inMilliseconds;
          _repository.saveBookProgressFast(currentBook!);
        }
      }
    });
  }

  /// Verifica si el reproductor ya tiene cargado y activo exactamente este libro, capítulo y párrafo.
  /// Permite que al tocar el MiniPlayerBar se abra PlayerScreen en 0ms sin reiniciar ni cortar la voz.
  bool isSameActiveTarget(BookItem book, ChapterItem chapter, int segmentIndex) {
    return currentBook?.id == book.id &&
        currentChapter?.id == chapter.id &&
        currentSegmentIndex == segmentIndex &&
        globalAudioPlayer.audioSource != null;
  }

  /// Sincroniza el estado desde PlayerScreen hacia el servicio global.
  void syncState({
    required BookItem book,
    required ChapterItem chapter,
    required List<String> segments,
    required int segmentIndex,
    required String voiceKey,
    required String voiceName,
    required double speed,
    required double ambientVol,
    required String ambientTrackId,
    required bool pausedByUser,
  }) {
    currentBook = book;
    currentChapter = chapter;
    currentSegments = segments;
    currentSegmentIndex = segmentIndex;
    selectedVoiceKey = voiceKey;
    selectedVoiceName = voiceName;
    playbackSpeed = speed;
    ambientVolume = ambientVol;
    selectedAmbientTrackId = ambientTrackId;
    userRequestedPause = pausedByUser;

    final chIdx = book.chapters.indexWhere((c) => c.id == chapter.id);
    if (chIdx != -1) {
      book.lastChapterIndex = chIdx;
      book.lastSegmentIndex = segmentIndex;
      book.totalSegmentsInLastChapter = max(1, segments.length);
    }
    notifyListeners();
  }

  void setPlayerScreenMounted(bool mounted) {
    isPlayerScreenMounted = mounted;
    if (mounted) {
      // Invalidar cualquier operación de fondo para ceder el control limpio a PlayerScreen
      _bgSynthesisGen++;
      _bgPrefetchGen++;
      _isHandlingBgCompletion = false;
    } else if (!userRequestedPause && currentBook != null && currentChapter != null) {
      // Si se cerró PlayerScreen mientras reproducía, asegurar pre-descarga en segundo plano
      _startBackgroundPrefetch(
        currentBook!,
        currentChapter!,
        currentSegmentIndex + 1,
        selectedVoiceKey,
      );
    }
  }

  void togglePlayPauseFromMiniPlayer() {
    if (userRequestedPause || !globalAudioPlayer.playing) {
      userRequestedPause = false;
      globalAudioPlayer.setVolume(1.0);
      unawaited(globalAudioPlayer.play().catchError((_) {}));
      if (ambientVolume > 0) {
        NativeChannelService.setLoFiVolume(ambientVolume);
        NativeChannelService.playLoFi();
      }
    } else {
      userRequestedPause = true;
      _bgSynthesisGen++;
      _bgPrefetchGen++;
      NativeChannelService.pauseLoFi();
      unawaited(globalAudioPlayer.pause().catchError((_) {}));
      if (currentBook != null) {
        currentBook!.lastPositionMs = globalAudioPlayer.position.inMilliseconds;
        _repository.saveBookProgressFast(currentBook!);
      }
    }
    notifyListeners();
  }

  // ===========================================================================
  // TEMPORIZADOR DE SUEÑO (SLEEP TIMER) CON FADE-OUT PROGRESIVO
  // ===========================================================================

  void startSleepTimerMinutes(int minutes) {
    _sleepTimer?.cancel();
    _sleepAtEndOfChapter = false;
    _sleepRemainingSeconds = minutes * 60;
    globalAudioPlayer.setVolume(1.0);
    if (ambientVolume > 0 && isPlaying) {
      NativeChannelService.setLoFiVolume(ambientVolume);
    }
    notifyListeners();

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final rem = _sleepRemainingSeconds;
      if (rem == null) {
        timer.cancel();
        return;
      }

      // Solo descontar segundos cuando no está en pausa manual
      if (userRequestedPause) return;

      final nextRem = rem - 1;
      if (nextRem <= 0) {
        timer.cancel();
        _triggerSleepStop();
        return;
      }

      _sleepRemainingSeconds = nextRem;

      // Fade-out suave durante los últimos 10 segundos para no despertar al usuario de golpe
      if (nextRem <= 10) {
        final double fadeFactor = (nextRem / 10.0).clamp(0.08, 1.0);
        globalAudioPlayer.setVolume(fadeFactor);
        if (ambientVolume > 0) {
          NativeChannelService.setLoFiVolume(ambientVolume * fadeFactor);
        }
      }

      notifyListeners();
    });
  }

  void addSleepTimerMinutes(int extraMinutes) {
    if (_sleepAtEndOfChapter) {
      startSleepTimerMinutes(extraMinutes);
      return;
    }
    final current = _sleepRemainingSeconds ?? 0;
    _sleepRemainingSeconds = current + (extraMinutes * 60);
    globalAudioPlayer.setVolume(1.0);
    if (ambientVolume > 0 && isPlaying) {
      NativeChannelService.setLoFiVolume(ambientVolume);
    }
    notifyListeners();
  }

  void startSleepAtEndOfChapter() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepRemainingSeconds = null;
    _sleepAtEndOfChapter = true;
    globalAudioPlayer.setVolume(1.0);
    if (ambientVolume > 0 && isPlaying) {
      NativeChannelService.setLoFiVolume(ambientVolume);
    }
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepRemainingSeconds = null;
    _sleepAtEndOfChapter = false;
    globalAudioPlayer.setVolume(1.0);
    if (ambientVolume > 0 && isPlaying) {
      NativeChannelService.setLoFiVolume(ambientVolume);
    }
    notifyListeners();
  }

  /// Consume la condición de "Dormir al terminar capítulo" si estaba activa.
  /// Devuelve `true` si debe detenerse la reproducción en este fin de capítulo.
  bool consumeEndOfChapterSleepIfActive() {
    if (!_sleepAtEndOfChapter) return false;
    _triggerSleepStop();
    return true;
  }

  void _triggerSleepStop() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepRemainingSeconds = null;
    _sleepAtEndOfChapter = false;
    userRequestedPause = true;
    isPlaying = false;
    isSynthesizing = false;
    _bgSynthesisGen++;
    _bgPrefetchGen++;

    NativeChannelService.pauseLoFi();
    unawaited(globalAudioPlayer.pause().catchError((_) {}));

    // Restaurar el volumen nominal a 1.0 luego de pausar para la próxima sesión
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      globalAudioPlayer.setVolume(1.0);
      if (ambientVolume > 0) {
        NativeChannelService.setLoFiVolume(ambientVolume);
      }
    });

    if (currentBook != null) {
      currentBook!.lastPositionMs = globalAudioPlayer.position.inMilliseconds;
      _repository.saveBookProgressFast(currentBook!);
    }
    notifyListeners();
  }

  // ===========================================================================
  // ORQUESTACIÓN EN SEGUNDO PLANO (CUANDO PLAYERSCREEN ESTÁ MINIMIZADO)
  // ===========================================================================

  Future<void> _onBackgroundSegmentCompleted() async {
    if (isPlayerScreenMounted ||
        isSynthesizing ||
        _isHandlingBgCompletion ||
        userRequestedPause ||
        currentBook == null ||
        currentChapter == null) {
      return;
    }

    _isHandlingBgCompletion = true;
    final book = currentBook!;
    final chapter = currentChapter!;

    if (currentSegmentIndex + 1 < currentSegments.length) {
      await _playBackgroundSegment(
        book: book,
        chapter: chapter,
        segments: currentSegments,
        index: currentSegmentIndex + 1,
      );
    } else {
      // Fin del capítulo actual: verificar si el Sleep Timer estaba en modo "Fin del capítulo"
      if (consumeEndOfChapterSleepIfActive()) {
        _isHandlingBgCompletion = false;
        return;
      }

      final idx = book.chapters.indexWhere((c) => c.id == chapter.id);
      if (idx != -1 && idx + 1 < book.chapters.length) {
        ChapterItem nextChapter = book.chapters[idx + 1];

        if (book.activeAudioLanguage == 'es' &&
            (nextChapter.originalLanguageSegments == null ||
                nextChapter.originalLanguageSegments!.isEmpty) &&
            book.detectedLanguage == 'en') {
          try {
            nextChapter = await BookTranslationService.translateSingleChapter(nextChapter);
            book.chapters[idx + 1] = nextChapter;
            unawaited(_repository.updateSingleBookInStorage(book));
          } catch (_) {}
        }

        final nextSegs = nextChapter.getSegmentsForLanguage(book.activeAudioLanguage);
        currentChapter = nextChapter;
        currentSegments = nextSegs;
        currentSegmentIndex = 0;
        book.lastChapterIndex = idx + 1;
        book.lastSegmentIndex = 0;
        book.lastPositionMs = 0;
        book.totalSegmentsInLastChapter = max(1, nextSegs.length);
        unawaited(_repository.saveBookProgressFast(book));
        notifyListeners();

        await _playBackgroundSegment(
          book: book,
          chapter: nextChapter,
          segments: nextSegs,
          index: 0,
        );
      } else {
        _isHandlingBgCompletion = false;
        NativeChannelService.pauseLoFi();
      }
    }
  }

  Future<void> _playBackgroundSegment({
    required BookItem book,
    required ChapterItem chapter,
    required List<String> segments,
    required int index,
  }) async {
    if (isPlayerScreenMounted || index < 0 || index >= segments.length) {
      _isHandlingBgCompletion = false;
      return;
    }

    final int gen = ++_bgSynthesisGen;
    ++_bgPrefetchGen;
    currentSegmentIndex = index;
    final chIdx = book.chapters.indexWhere((c) => c.id == chapter.id);
    if (chIdx != -1) {
      book.lastChapterIndex = chIdx;
    }
    book.lastSegmentIndex = index;
    book.lastPositionMs = 0;
    book.totalSegmentsInLastChapter = max(1, segments.length);
    unawaited(_repository.saveBookProgressFast(book));
    notifyListeners();

    final segText = segments[index];
    File? audioFile;

    while (!isPlayerScreenMounted && gen == _bgSynthesisGen && !userRequestedPause) {
      try {
        isSynthesizing = true;
        audioFile = await _ttsService.synthesizeSegment(
          bookId: book.id,
          chapter: chapter,
          segIdx: index,
          text: segText,
          voiceKey: selectedVoiceKey,
        );
        break;
      } catch (_) {
        if (isPlayerScreenMounted || gen != _bgSynthesisGen || userRequestedPause) {
          isSynthesizing = false;
          _isHandlingBgCompletion = false;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2000));
      }
    }

    if (audioFile == null ||
        isPlayerScreenMounted ||
        gen != _bgSynthesisGen ||
        userRequestedPause) {
      isSynthesizing = false;
      _isHandlingBgCompletion = false;
      return;
    }

    Uri? artUri;
    try {
      if (book.coverImagePath != null && await File(book.coverImagePath!).exists()) {
        artUri = Uri.file(book.coverImagePath!);
      } else if (book.coverUrl != null) {
        artUri = Uri.parse(book.coverUrl!);
      }
    } catch (_) {}

    for (int attempt = 0; attempt < 3; attempt++) {
      if (isPlayerScreenMounted || gen != _bgSynthesisGen || userRequestedPause) {
        isSynthesizing = false;
        _isHandlingBgCompletion = false;
        return;
      }
      try {
        await globalAudioPlayer.setAudioSource(
          AudioSource.uri(
            Uri.file(audioFile.path),
            tag: MediaItem(
              id: '${book.id}_${chapter.id}_$index',
              album: book.title,
              title: '${chapter.title} (${index + 1}/${segments.length})',
              artist: book.author,
              artUri: artUri,
            ),
          ),
        );
        await globalAudioPlayer.setSpeed(playbackSpeed);
        try {
          await globalAudioPlayer.setPitch(1.0);
        } catch (_) {}

        isSynthesizing = false;
        _isHandlingBgCompletion = false;
        notifyListeners();

        if (!userRequestedPause && !isPlayerScreenMounted) {
          unawaited(globalAudioPlayer.play().catchError((_) {}));
          if (ambientVolume > 0) {
            NativeChannelService.setLoFiVolume(ambientVolume);
            NativeChannelService.playLoFi();
          }
          _startBackgroundPrefetch(book, chapter, index + 1, selectedVoiceKey);
        }
        break;
      } catch (_) {
        if (attempt == 2) {
          isSynthesizing = false;
          _isHandlingBgCompletion = false;
          notifyListeners();
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
    }
  }

  Future<void> _startBackgroundPrefetch(
    BookItem book,
    ChapterItem chapter,
    int startIdx,
    String voiceKey,
  ) async {
    final prefetchId = ++_bgPrefetchGen;
    final segs = chapter.getSegmentsForLanguage(book.activeAudioLanguage);

    for (int i = startIdx; i < min(segs.length, startIdx + 8); i++) {
      if (isPlayerScreenMounted ||
          prefetchId != _bgPrefetchGen ||
          currentChapter?.id != chapter.id ||
          userRequestedPause) {
        return;
      }
      try {
        await _ttsService.synthesizeSegment(
          bookId: book.id,
          chapter: chapter,
          segIdx: i,
          text: segs[i],
          voiceKey: voiceKey,
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }
}
