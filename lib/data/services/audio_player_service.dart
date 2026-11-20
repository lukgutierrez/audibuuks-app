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

/// Potenciador nativo de volumen de voz en Android (hardware compressor/limiter sin distorsión).
final AndroidLoudnessEnhancer globalLoudnessEnhancer = AndroidLoudnessEnhancer();

/// Singleton global de AudioPlayer requerido por `just_audio_background`.
final AudioPlayer globalAudioPlayer = AudioPlayer(
  audioPipeline: Platform.isAndroid
      ? AudioPipeline(androidAudioEffects: [globalLoudnessEnhancer])
      : null,
);

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
  int bufferedUpToSegment = 0;

  String selectedVoiceKey = 'es-MX-JorgeNeural';
  String selectedVoiceName = 'Jorge HD (México 🇲🇽 • Cálido)';
  double playbackSpeed = 1.0;
  double ambientVolume = 0.25;
  String selectedAmbientTrackId = NativeChannelService.currentTrackId;

  bool isPlaying = false;
  bool isSynthesizing = false;
  bool userRequestedPause = false;
  bool isPlayerScreenMounted = false;
  bool _wasSynthesizingBeforeForeground = false;

  int _bgSynthesisGen = 0;
  int _bgPrefetchGen = 0;
  bool _isHandlingBgCompletion = false;
  int _lastSavedSecond = -1;
  Timer? _bgWatchdogTimer;

  // --- Estado del Temporizador de Sueño (Sleep Timer) ---
  Timer? _sleepTimer;
  int? _sleepRemainingSeconds;
  bool _sleepAtEndOfChapter = false;

  int? get sleepRemainingSeconds => _sleepRemainingSeconds;
  bool get sleepAtEndOfChapter => _sleepAtEndOfChapter;
  bool get isSleepTimerActive => _sleepRemainingSeconds != null || _sleepAtEndOfChapter;

  bool consumeWasSynthesizingBeforeForeground() {
    final val = _wasSynthesizingBeforeForeground;
    _wasSynthesizingBeforeForeground = false;
    return val;
  }

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
    unawaited(_configureVoiceLoudnessBoost());

    globalAudioPlayer.playerStateStream.listen((state) {
      final bool activelySpeaking = state.playing &&
          state.processingState == ProcessingState.ready &&
          !isSynthesizing &&
          !userRequestedPause;
      isPlaying = state.playing && !userRequestedPause;
      notifyListeners();

      // Si PlayerScreen está cerrado o con pantalla apagada, el servicio toma el control total
      if (!isPlayerScreenMounted) {
        if (userRequestedPause) {
          NativeChannelService.pauseLoFi();
          return;
        }

        // Nunca dejar la música ambiental sonando sola si la voz terminó el segmento o está cargando red
        if (activelySpeaking && ambientVolume > 0) {
          NativeChannelService.setLoFiVolume(ambientVolume);
          NativeChannelService.playLoFi();
        } else {
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

  Future<void> _configureVoiceLoudnessBoost() async {
    try {
      await globalAudioPlayer.setVolume(1.0);
      if (Platform.isAndroid) {
        // Realce limpio de +8.5 dB con limitador hardware de Android para que las voces Edge-TTS
        // suenen claras y potentes sin tener que subir el volumen del celular al 100%.
        await globalLoudnessEnhancer.setEnabled(true);
        await globalLoudnessEnhancer.setTargetGain(8.5);
      }
    } catch (e) {
      debugPrint('Voice loudness boost notice: $e');
    }
  }

  void _startBackgroundWatchdog() {
    _bgWatchdogTimer?.cancel();
    _bgWatchdogTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (isPlayerScreenMounted || userRequestedPause || currentBook == null || currentChapter == null) {
        _bgWatchdogTimer?.cancel();
        _bgWatchdogTimer = null;
        return;
      }
      if (globalAudioPlayer.processingState == ProcessingState.completed &&
          !_isHandlingBgCompletion &&
          !isSynthesizing) {
        _onBackgroundSegmentCompleted();
      }
    });
  }

  void _stopBackgroundWatchdog() {
    _bgWatchdogTimer?.cancel();
    _bgWatchdogTimer = null;
  }

  /// Verifica si el reproductor ya tiene cargado y activo exactamente este libro, capítulo y párrafo.
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
    int? bufferedSegment,
    bool? synthesizing,
  }) {
    currentBook = book;
    currentChapter = chapter;
    currentSegments = segments;
    currentSegmentIndex = segmentIndex;
    if (bufferedSegment != null) {
      bufferedUpToSegment = max(segmentIndex, bufferedSegment);
    }
    if (synthesizing != null) {
      isSynthesizing = synthesizing;
    }
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
      _stopBackgroundWatchdog();
      _wasSynthesizingBeforeForeground = isSynthesizing || _isHandlingBgCompletion;
      _bgSynthesisGen++;
      _bgPrefetchGen++;
      _isHandlingBgCompletion = false;
      isSynthesizing = false;
    } else if (!userRequestedPause && currentBook != null && currentChapter != null) {
      // Adquirir WakeLock de red y CPU para evitar cortes al viajar con la pantalla apagada
      NativeChannelService.acquireBackgroundLock();
      _startBackgroundWatchdog();

      final bool wasMidSynthesis = isSynthesizing;
      final pState = globalAudioPlayer.processingState;

      if (pState == ProcessingState.completed && !_isHandlingBgCompletion) {
        isSynthesizing = false;
        _onBackgroundSegmentCompleted();
      } else if (wasMidSynthesis ||
          (!globalAudioPlayer.playing &&
              (pState == ProcessingState.idle || globalAudioPlayer.audioSource == null))) {
        // Si PlayerScreen estaba sintetizando el segmento al apagar pantalla/minimizar,
        // el servicio toma la posta inmediatamente para que jamás se trabe a mitad de sección.
        isSynthesizing = false;
        _isHandlingBgCompletion = false;
        _playBackgroundSegment(
          book: currentBook!,
          chapter: currentChapter!,
          segments: currentSegments,
          index: currentSegmentIndex,
        );
      } else {
        _startBackgroundPrefetch(
          currentBook!,
          currentChapter!,
          currentSegmentIndex + 1,
          selectedVoiceKey,
        );
      }
    } else {
      _stopBackgroundWatchdog();
    }
  }

  void togglePlayPauseFromMiniPlayer() {
    if (userRequestedPause || !globalAudioPlayer.playing) {
      userRequestedPause = false;
      NativeChannelService.acquireBackgroundLock();
      globalAudioPlayer.setVolume(1.0);

      final pState = globalAudioPlayer.processingState;
      if (!isPlayerScreenMounted &&
          currentBook != null &&
          currentChapter != null &&
          (globalAudioPlayer.audioSource == null ||
              pState == ProcessingState.idle ||
              pState == ProcessingState.completed)) {
        _isHandlingBgCompletion = false;
        if (pState == ProcessingState.completed) {
          _onBackgroundSegmentCompleted();
        } else {
          _playBackgroundSegment(
            book: currentBook!,
            chapter: currentChapter!,
            segments: currentSegments,
            index: currentSegmentIndex,
          );
        }
      } else {
        unawaited(globalAudioPlayer.play().catchError((_) {}));
        if (ambientVolume > 0) {
          NativeChannelService.setLoFiVolume(ambientVolume);
          NativeChannelService.playLoFi();
        }
        if (!isPlayerScreenMounted && currentBook != null && currentChapter != null) {
          _startBackgroundWatchdog();
        }
      }
    } else {
      userRequestedPause = true;
      _stopBackgroundWatchdog();
      _bgSynthesisGen++;
      _bgPrefetchGen++;
      _isHandlingBgCompletion = false;
      isSynthesizing = false;
      NativeChannelService.pauseLoFi();
      NativeChannelService.releaseBackgroundLock();
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

      if (userRequestedPause) return;

      final nextRem = rem - 1;
      if (nextRem <= 0) {
        timer.cancel();
        _triggerSleepStop();
        return;
      }

      _sleepRemainingSeconds = nextRem;

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
    _stopBackgroundWatchdog();
    userRequestedPause = true;
    isPlaying = false;
    isSynthesizing = false;
    _isHandlingBgCompletion = false;
    _bgSynthesisGen++;
    _bgPrefetchGen++;

    NativeChannelService.pauseLoFi();
    NativeChannelService.releaseBackgroundLock();
    unawaited(globalAudioPlayer.pause().catchError((_) {}));

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
  // ORQUESTACIÓN EN SEGUNDO PLANO (CUANDO PLAYERSCREEN ESTÁ MINIMIZADO O PANTALLA APAGADA)
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
    NativeChannelService.pauseLoFi();

    final book = currentBook!;
    final chapter = currentChapter!;

    try {
      if (currentSegmentIndex + 1 < currentSegments.length) {
        await _playBackgroundSegment(
          book: book,
          chapter: chapter,
          segments: currentSegments,
          index: currentSegmentIndex + 1,
        );
      } else {
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

          if (isPlayerScreenMounted || userRequestedPause) {
            _isHandlingBgCompletion = false;
            return;
          }

          final nextSegs = nextChapter.getSegmentsForLanguage(book.activeAudioLanguage);
          currentChapter = nextChapter;
          currentSegments = nextSegs;
          currentSegmentIndex = 0;
          bufferedUpToSegment = 0;
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
          _stopBackgroundWatchdog();
          NativeChannelService.pauseLoFi();
          NativeChannelService.releaseBackgroundLock();
        }
      }
    } catch (_) {
      _isHandlingBgCompletion = false;
      isSynthesizing = false;
      notifyListeners();
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
      isSynthesizing = false;
      return;
    }

    final int gen = ++_bgSynthesisGen;
    ++_bgPrefetchGen;
    currentSegmentIndex = index;
    bufferedUpToSegment = max(bufferedUpToSegment, index);
    final chIdx = book.chapters.indexWhere((c) => c.id == chapter.id);
    if (chIdx != -1) {
      book.lastChapterIndex = chIdx;
    }
    book.lastSegmentIndex = index;
    book.lastPositionMs = 0;
    book.totalSegmentsInLastChapter = max(1, segments.length);
    unawaited(_repository.saveBookProgressFast(book));
    notifyListeners();

    NativeChannelService.acquireBackgroundLock();
    NativeChannelService.pauseLoFi();

    final segText = segments[index];
    File? audioFile;

    try {
      const backoffDelaysMs = [900, 1800, 3000, 4500, 6500];
      for (int attempt = 0; attempt <= backoffDelaysMs.length; attempt++) {
        if (isPlayerScreenMounted || gen != _bgSynthesisGen || userRequestedPause) {
          return;
        }
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
            return;
          }
          if (attempt < backoffDelaysMs.length) {
            await Future<void>.delayed(Duration(milliseconds: backoffDelaysMs[attempt]));
          }
        }
      }

      if (audioFile == null ||
          isPlayerScreenMounted ||
          gen != _bgSynthesisGen ||
          userRequestedPause) {
        if (audioFile == null && !isPlayerScreenMounted && gen == _bgSynthesisGen) {
          // Liberar WakeLock si realmente no hay conexión tras todos los reintentos
          NativeChannelService.releaseBackgroundLock();
        }
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

      File currentFile = audioFile;
      for (int attempt = 0; attempt < 3; attempt++) {
        if (isPlayerScreenMounted || gen != _bgSynthesisGen || userRequestedPause) {
          return;
        }
        try {
          await globalAudioPlayer.setAudioSource(
            AudioSource.uri(
              Uri.file(currentFile.path),
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
          bufferedUpToSegment = max(bufferedUpToSegment, index + 1);
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
          // Si el MP3 en caché estaba corrupto, borrarlo y resintetizar automáticamente
          if (attempt == 0) {
            await _ttsService.invalidateCorruptedSegment(
              bookId: book.id,
              chapter: chapter,
              segIdx: index,
              voiceKey: selectedVoiceKey,
              text: segText,
            );
            try {
              currentFile = await _ttsService.synthesizeSegment(
                bookId: book.id,
                chapter: chapter,
                segIdx: index,
                text: segText,
                voiceKey: selectedVoiceKey,
              );
            } catch (_) {}
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 220));
          }
        }
      }
    } finally {
      if (gen == _bgSynthesisGen) {
        isSynthesizing = false;
        _isHandlingBgCompletion = false;
        notifyListeners();
      }
    }
  }

  /// Pre-carga paralela (3 workers) de toda la sección actual en segundo plano (estilo YouTube)
  Future<void> _startBackgroundPrefetch(
    BookItem book,
    ChapterItem chapter,
    int startIdx,
    String voiceKey,
  ) async {
    final prefetchId = ++_bgPrefetchGen;
    final segs = chapter.getSegmentsForLanguage(book.activeAudioLanguage);
    if (startIdx >= segs.length) return;

    bool shouldAbort() =>
        isPlayerScreenMounted ||
        prefetchId != _bgPrefetchGen ||
        currentChapter?.id != chapter.id ||
        userRequestedPause;

    final cachedKeys = await _ttsService.getCachedKeysForBook(book.id);
    if (shouldAbort()) return;

    final Set<int> completed = {};
    final List<int> missing = [];
    for (int i = startIdx; i < segs.length; i++) {
      final segKey = _ttsService.segmentKeyId(book.id, chapter, i, voiceKey, text: segs[i]);
      if (cachedKeys.contains(segKey)) {
        completed.add(i);
      } else {
        missing.add(i);
      }
    }

    int contiguous = startIdx;
    while (completed.contains(contiguous) && contiguous < segs.length) {
      contiguous++;
    }
    if (contiguous > bufferedUpToSegment) {
      bufferedUpToSegment = contiguous;
      notifyListeners();
    }

    // 1. Prioridad máxima al siguiente segmento inmediato para 0ms de espera
    if (missing.isNotEmpty && missing.first == startIdx) {
      final firstIdx = missing.removeAt(0);
      for (int retry = 0; retry < 3; retry++) {
        if (shouldAbort()) return;
        try {
          await _ttsService.synthesizeSegment(
            bookId: book.id,
            chapter: chapter,
            segIdx: firstIdx,
            text: segs[firstIdx],
            voiceKey: voiceKey,
          );
          completed.add(firstIdx);
          while (completed.contains(contiguous) && contiguous < segs.length) {
            contiguous++;
          }
          if (contiguous > bufferedUpToSegment) {
            bufferedUpToSegment = contiguous;
            notifyListeners();
          }
          break;
        } catch (_) {
          await Future<void>.delayed(Duration(milliseconds: 800 * (retry + 1)));
        }
      }
    }

    // 2. Pool paralelo de 3 workers para llenar el resto de la sección 3x más rápido
    if (missing.isNotEmpty && !shouldAbort()) {
      int cursor = 0;
      DateTime lastNotify = DateTime.now();

      Future<void> worker() async {
        while (!shouldAbort()) {
          if (cursor >= missing.length) return;
          final idx = missing[cursor++];
          for (int retry = 0; retry < 3; retry++) {
            if (shouldAbort()) return;
            try {
              await _ttsService.synthesizeSegment(
                bookId: book.id,
                chapter: chapter,
                segIdx: idx,
                text: segs[idx],
                voiceKey: voiceKey,
              );
              completed.add(idx);
              while (completed.contains(contiguous) && contiguous < segs.length) {
                contiguous++;
              }
              if (contiguous > bufferedUpToSegment) {
                bufferedUpToSegment = contiguous;
                final now = DateTime.now();
                if (now.difference(lastNotify).inMilliseconds >= 250 ||
                    contiguous >= segs.length) {
                  lastNotify = now;
                  notifyListeners();
                }
              }
              break;
            } catch (_) {
              await Future<void>.delayed(Duration(milliseconds: 900 * (retry + 1)));
            }
          }
        }
      }

      await Future.wait(List.generate(min(3, missing.length), (_) => worker()));
    }

    if (shouldAbort()) return;

    // 3. Pre-cargar también los primeros 4 párrafos del capítulo siguiente en paralelo
    final chIdx = book.chapters.indexWhere((c) => c.id == chapter.id);
    if (chIdx != -1 && chIdx + 1 < book.chapters.length) {
      final nextCh = book.chapters[chIdx + 1];
      final nextSegs = nextCh.getSegmentsForLanguage(book.activeAudioLanguage);
      final int lookahead = min(4, nextSegs.length);
      await Future.wait(
        List.generate(lookahead, (k) async {
          if (shouldAbort()) return;
          try {
            await _ttsService.synthesizeSegment(
              bookId: book.id,
              chapter: nextCh,
              segIdx: k,
              text: nextSegs[k],
              voiceKey: voiceKey,
            );
          } catch (_) {}
        }),
      );
    }
  }
}
