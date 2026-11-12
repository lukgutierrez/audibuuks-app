import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../../../core/utils/text_sanitizer.dart';
import '../../../../data/repositories/library_repository.dart';
import '../../../../data/services/audio_player_service.dart';
import '../../../../data/services/book_translation_service.dart';
import '../../../../data/services/cover_service.dart';
import '../../../../data/services/native_channel_service.dart';
import '../../../../data/services/offline_download_service.dart';
import '../../../../data/services/tts_synthesis_service.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';
import '../../../shared/widgets/book_cover_widget.dart';
import '../../reader/views/document_viewer_screen.dart';
import '../widgets/ambient_music_sheet.dart';
import '../widgets/chapters_list_sheet.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/spotify_audio_visualizer.dart';
import '../widgets/voices_selector_sheet.dart';
import 'chapter_note_editor_sheet.dart';

class PlayerScreen extends StatefulWidget {
  final BookItem book;
  final ChapterItem initialChapter;
  final int initialSegmentIndex;
  final int initialPositionMs;
  final AudioPlayer player;
  final void Function(
    ChapterItem chapter,
    int segmentIndex,
    int totalSegments,
    int positionMs,
  )? onProgressUpdated;

  const PlayerScreen({
    super.key,
    required this.book,
    required this.initialChapter,
    this.initialSegmentIndex = 0,
    this.initialPositionMs = 0,
    required this.player,
    this.onProgressUpdated,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final LibraryRepository _repository = LibraryRepository();
  final TtsSynthesisService _ttsService = TtsSynthesisService();
  final OfflineDownloadService _downloadService = OfflineDownloadService();

  late ChapterItem _currentChapter;
  // 0 = Modo Portada, 1 = Modo Texto Minimalista (estilo ElevenReader por defecto)
  int _viewMode = 1;
  bool _immersiveTextMode = false;

  double _playbackSpeed = 1.0;
  double _ambientVolume = 0.25;
  String _selectedAmbientTrackId = NativeChannelService.currentTrackId;
  String _selectedVoiceKey = 'es-MX-JorgeNeural';
  String _selectedVoiceName = 'Jorge HD (México 🇲🇽 • Cálido)';

  bool _isPlaying = false;
  bool _userRequestedPause = false;
  bool _isHandlingCompletion = false;
  // Por defecto false = la barra mide el Capítulo actual (mucho más cómodo y preciso que las 10h del libro entero)
  bool _sliderShowsFullBook = false;
  double? _draggingSliderSec;
  bool _isSynthesizing = false;
  String _statusMessage = '';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  List<String> _segments = [];
  int _currentSegmentIndex = 0;
  int _bufferedUpToSegment = 0;
  int _synthesisGeneration = 0;
  int _prefetchGeneration = 0;
  int _lastSavedSecond = -1;
  int _lastDisplayedSecond = -1;
  int _lastActiveWordIdx = -1;

  // Caché de tokens del párrafo actual para evitar RegExp/split repetidos cada 120ms y reducir calor de CPU
  int _cachedTokenSegmentIdx = -1;
  int _cachedTokenChapterId = -1;
  List<String> _cachedTokens = const [];
  List<String> _cachedCleanTokens = const [];

  // Un único GlobalKey para el párrafo activo (evita crear 200 GlobalKeys y elimina el congelamiento ANR)
  final GlobalKey _activeSegmentKey = GlobalKey();
  int _lastAutoScrolledSegment = -1;

  List<Color> _ambientColors = [
    const Color(0xFF3E2723),
    const Color(0xFF1B263B),
  ];
  late AnimationController _ambientAnimController;

  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    audioPlayerService.setPlayerScreenMounted(true);
    audioPlayerService.addListener(_onGlobalAudioServiceChanged);
    _currentChapter = widget.initialChapter;
    _ambientAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    );

    _loadCoverAmbientPalette();
    _setupAudioStreams();
    _initPreferencesAndStartPlayback();
  }

  /// Solo activa el ticker de animación ambiental cuando el usuario está en Modo Portada (_viewMode == 0)
  /// y el audio está reproduciéndose con la pantalla encendida. Ahorra >70% de GPU/batería.
  void _syncAmbientAnimationTicker() {
    final bool shouldAnimate =
        mounted && _viewMode == 0 && _isPlaying && !_userRequestedPause;
    if (shouldAnimate && !_ambientAnimController.isAnimating) {
      _ambientAnimController.repeat(reverse: true);
    } else if (!shouldAnimate && _ambientAnimController.isAnimating) {
      _ambientAnimController.stop();
    }
  }

  void _ensureCurrentSegmentTokensCached() {
    if (_currentSegmentIndex < 0 || _currentSegmentIndex >= _segments.length) {
      _cachedTokens = const [];
      _cachedCleanTokens = const [];
      return;
    }
    if (_cachedTokenChapterId == _currentChapter.id &&
        _cachedTokenSegmentIdx == _currentSegmentIndex &&
        _cachedTokens.isNotEmpty) {
      return;
    }
    final raw = _segments[_currentSegmentIndex];
    final toks = raw.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final cleanToks = toks
        .map((w) => w.toLowerCase().replaceAll(RegExp(r'[^a-záéíóúñü0-9]'), ''))
        .toList();
    _cachedTokenChapterId = _currentChapter.id;
    _cachedTokenSegmentIdx = _currentSegmentIndex;
    _cachedTokens = toks;
    _cachedCleanTokens = cleanToks;
  }

  void _onGlobalAudioServiceChanged() {
    if (!mounted) return;
    if (audioPlayerService.userRequestedPause && !_userRequestedPause) {
      setState(() {
        _userRequestedPause = true;
        _isPlaying = false;
        _isSynthesizing = false;
        _statusMessage = 'Temporizador de sueño finalizado 🌙';
      });
      _syncAmbientAnimationTicker();
    } else {
      if (audioPlayerService.currentChapter?.id == _currentChapter.id &&
          audioPlayerService.bufferedUpToSegment > _bufferedUpToSegment) {
        _bufferedUpToSegment = audioPlayerService.bufferedUpToSegment;
      }
      setState(() {});
    }
  }

  void _syncToGlobalService() {
    audioPlayerService.syncState(
      book: widget.book,
      chapter: _currentChapter,
      segments: _segments,
      segmentIndex: _currentSegmentIndex,
      voiceKey: _selectedVoiceKey,
      voiceName: _selectedVoiceName,
      speed: _playbackSpeed,
      ambientVol: _ambientVolume,
      ambientTrackId: _selectedAmbientTrackId,
      pausedByUser: _userRequestedPause,
      bufferedSegment: _bufferedUpToSegment,
    );
  }

  Future<void> _initPreferencesAndStartPlayback() async {
    final prefs = await _repository.loadPlayerPreferences();
    if (!mounted) return;

    final savedSpeed = (prefs['speed'] as double?) ?? 1.0;
    final isBookEnglish = widget.book.activeAudioLanguage == 'en';
    final fallbackVoiceKey = isBookEnglish ? 'en-US-GuyNeural' : 'es-MX-JorgeNeural';
    final savedVoiceKey = (prefs['voiceKey'] as String?) ?? fallbackVoiceKey;
    final effectiveVoiceKey = (isBookEnglish && !savedVoiceKey.startsWith('en-'))
        ? 'en-US-GuyNeural'
        : (!isBookEnglish && savedVoiceKey.startsWith('en-'))
            ? 'es-MX-JorgeNeural'
            : savedVoiceKey;

    final savedVoiceName =
        TtsSynthesisService.voicesMap[effectiveVoiceKey] ??
        (prefs['voiceName'] as String?) ??
        (isBookEnglish ? 'Guy HD (EE. UU. 🇺🇸 • Cálido y narrativo)' : 'Jorge HD (México 🇲🇽 • Cálido)');
    final savedVol = (prefs['ambientVolume'] as double?) ?? 0.25;
    final savedTrack = prefs['ambientTrackId'] as String?;

    setState(() {
      _playbackSpeed = savedSpeed.clamp(0.70, 2.00);
      _selectedVoiceKey = effectiveVoiceKey;
      _selectedVoiceName = savedVoiceName;
      _ambientVolume = savedVol.clamp(0.0, 1.0);
      if (savedTrack != null && savedTrack.isNotEmpty) {
        _selectedAmbientTrackId = savedTrack;
      }
    });

    if (savedTrack != null && savedTrack.isNotEmpty) {
      NativeChannelService.selectAndPlayTrack(
        savedTrack,
        _ambientVolume,
        shouldPlayNow: false,
      );
    } else {
      NativeChannelService.setLoFiVolume(_ambientVolume);
    }

    if (audioPlayerService.isSameActiveTarget(
      widget.book,
      _currentChapter,
      widget.initialSegmentIndex,
    )) {
      final activeCh = audioPlayerService.currentChapter!;
      final segs = activeCh.getSegmentsForLanguage(widget.book.activeAudioLanguage);
      final safeSeg = audioPlayerService.currentSegmentIndex
          .clamp(0, max<int>(0, segs.length - 1))
          .toInt();

      setState(() {
        _currentChapter = activeCh;
        _segments = segs;
        _currentSegmentIndex = safeSeg;
        _bufferedUpToSegment = max(safeSeg + 1, audioPlayerService.bufferedUpToSegment);
        _position = widget.player.position;
        _duration = widget.player.duration ?? Duration.zero;
        _isPlaying = widget.player.playing;
        _userRequestedPause = audioPlayerService.userRequestedPause;
        _isSynthesizing = false;
        _statusMessage = '';
      });
      _ensureCurrentSegmentTokensCached();
      _syncToGlobalService();
      _syncAmbientAnimationTicker();

      if (!_userRequestedPause && !_isPlaying) {
        unawaited(widget.player.play().catchError((_) {}));
        if (_ambientVolume > 0) {
          NativeChannelService.setLoFiVolume(_ambientVolume);
          NativeChannelService.playLoFi();
        }
      }
      _startSequentialPrefetch(_currentChapter, safeSeg + 1, _selectedVoiceKey, _synthesisGeneration);
      return;
    }

    await _startChapterPlayback(
      _currentChapter,
      startSegment: widget.initialSegmentIndex,
      initialSeekMs: widget.initialPositionMs,
    );
  }

  Future<void> _loadCoverAmbientPalette() async {
    final colors = await CoverService.extractCoverPalette(widget.book);
    if (mounted) {
      setState(() {
        _ambientColors = colors;
      });
    }
  }

  @override
  void dispose() {
    audioPlayerService.removeListener(_onGlobalAudioServiceChanged);
    _syncToGlobalService();
    audioPlayerService.setPlayerScreenMounted(false);
    WidgetsBinding.instance.removeObserver(this);
    _saveExactPositionNow();
    _synthesisGeneration++;
    _prefetchGeneration++;
    _ambientAnimController.dispose();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      // Al apagar la pantalla o minimizar con el reproductor abierto:
      // 1. Apagar el ticker gráfico para no calentar el teléfono.
      // 2. Ceder el control al servicio nativo de fondo con WakeLock para que en el colectivo no se corte entre párrafos.
      _ambientAnimController.stop();
      _saveExactPositionNow();
      _syncToGlobalService();
      audioPlayerService.setPlayerScreenMounted(false);
      if (!_isPlaying) {
        NativeChannelService.pauseLoFi();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Al encender la pantalla nuevamente, recuperar el estado actualizado desde el servicio de fondo
      audioPlayerService.setPlayerScreenMounted(true);
      if (audioPlayerService.currentBook?.id == widget.book.id &&
          audioPlayerService.currentChapter != null) {
        final activeCh = audioPlayerService.currentChapter!;
        final segs = activeCh.getSegmentsForLanguage(widget.book.activeAudioLanguage);
        final safeSeg = audioPlayerService.currentSegmentIndex
            .clamp(0, max<int>(0, segs.length - 1))
            .toInt();
        setState(() {
          _currentChapter = activeCh;
          _segments = segs;
          _currentSegmentIndex = safeSeg;
          _bufferedUpToSegment = max(
            _bufferedUpToSegment,
            max(safeSeg + 1, audioPlayerService.bufferedUpToSegment),
          );
          _position = widget.player.position;
          _duration = widget.player.duration ?? Duration.zero;
          _isPlaying = widget.player.playing && !audioPlayerService.userRequestedPause;
          _userRequestedPause = audioPlayerService.userRequestedPause;
          _isSynthesizing = audioPlayerService.isSynthesizing;
        });
        _ensureCurrentSegmentTokensCached();
        _scrollToCurrentSegment(safeSeg);
      }
      _syncAmbientAnimationTicker();
    }
  }

  void _saveExactPositionNow() {
    widget.onProgressUpdated?.call(
      _currentChapter,
      _currentSegmentIndex,
      _segments.length,
      _position.inMilliseconds,
    );
  }

  void _setupAudioStreams() {
    _playerStateSub = widget.player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (_userRequestedPause) {
        NativeChannelService.pauseLoFi();
        if (_isPlaying) {
          setState(() => _isPlaying = false);
          _syncAmbientAnimationTicker();
        }
        return;
      }

      // Si PlayerScreen cedió el control porque la pantalla está bloqueada, deja que AudioPlayerService maneje todo
      if (!audioPlayerService.isPlayerScreenMounted) {
        return;
      }

      final bool activelySpeaking = state.playing &&
          state.processingState == ProcessingState.ready &&
          !_isSynthesizing &&
          !_userRequestedPause;

      if (_isPlaying != state.playing) {
        setState(() => _isPlaying = state.playing);
        _syncAmbientAnimationTicker();
      }

      // Sincronización estricta: la música de fondo solo suena cuando la voz está hablando en estado ready
      if (activelySpeaking && _ambientVolume > 0) {
        NativeChannelService.setLoFiVolume(_ambientVolume);
        NativeChannelService.playLoFi();
      } else {
        NativeChannelService.pauseLoFi();
      }

      if (state.processingState == ProcessingState.completed && !_isHandlingCompletion) {
        _onSegmentCompleted();
      }
    });

    _positionSub = widget.player.positionStream.listen((pos) {
      if (!mounted || !audioPlayerService.isPlayerScreenMounted) return;
      _position = pos;

      _ensureCurrentSegmentTokensCached();
      final int newWordIdx = _viewMode == 1
          ? _getActiveWordIndexForCurrentSegment(_cachedTokens)
          : -1;
      final int sec = pos.inSeconds;

      // Solo reconstruir la interfaz cuando cambia la palabra hablada, el segundo del reloj,
      // o en Modo Portada cada 250ms para el visualizador (reduce el calor de CPU/GPU en un 75%)
      final bool wordChanged = _viewMode == 1 && newWordIdx != _lastActiveWordIdx;
      final bool secChanged = sec != _lastDisplayedSecond;
      final bool coverTick =
          _viewMode == 0 && (pos.inMilliseconds % 260 < 60);

      if (wordChanged || secChanged || coverTick || pos == Duration.zero) {
        _lastActiveWordIdx = newWordIdx;
        _lastDisplayedSecond = sec;
        setState(() {});
      }

      if (sec != _lastSavedSecond && sec % 3 == 0) {
        _lastSavedSecond = sec;
        _saveExactPositionNow();
      }
    });

    _durationSub = widget.player.durationStream.listen((dur) {
      if (mounted && dur != null && dur != _duration) {
        setState(() => _duration = dur);
      }
    });
  }

  Future<void> _startChapterPlayback(
    ChapterItem chapter, {
    int startSegment = 0,
    int initialSeekMs = 0,
    double initialWordRatio = 0.0,
  }) async {
    _userRequestedPause = false;
    _isHandlingCompletion = true;
    final gen = ++_synthesisGeneration;
    ++_prefetchGeneration;
    NativeChannelService.pauseLoFi();
    unawaited(widget.player.pause().catchError((_) {}));

    // Tomar siempre la versión más reciente del capítulo en el libro
    final chIdxInBook = widget.book.chapters.indexWhere((c) => c.id == chapter.id);
    ChapterItem playableChapter =
        chIdxInBook != -1 ? widget.book.chapters[chIdxInBook] : chapter;

    // Si el libro está en modo español pero este capítulo todavía no fue traducido,
    // traducirlo en el acto para que jamás se cuelgue ni quede mudo al pasar de sección.
    if (widget.book.activeAudioLanguage == 'es' &&
        (playableChapter.originalLanguageSegments == null ||
            playableChapter.originalLanguageSegments!.isEmpty) &&
        widget.book.detectedLanguage == 'en') {
      if (mounted) {
        setState(() {
          _isSynthesizing = true;
          _statusMessage = 'Traduciendo ${playableChapter.title} al español...';
        });
      }
      try {
        playableChapter = await BookTranslationService.translateSingleChapter(playableChapter);
        if (chIdxInBook != -1) {
          widget.book.chapters[chIdxInBook] = playableChapter;
          unawaited(LibraryRepository().updateSingleBookInStorage(widget.book));
        }
      } catch (_) {}
    }

    if (!mounted || gen != _synthesisGeneration) return;

    // Usa los segmentos correspondientes al idioma de audio activo (Español o Inglés)
    final segs = playableChapter.getSegmentsForLanguage(widget.book.activeAudioLanguage);
    final int safeSeg = startSegment.clamp(0, max<int>(0, segs.length - 1)).toInt();

    setState(() {
      _currentChapter = playableChapter;
      _segments = segs;
      _currentSegmentIndex = safeSeg;
      _bufferedUpToSegment = safeSeg;
      _lastAutoScrolledSegment = -1;
      _isSynthesizing = true;
      _statusMessage = 'Preparando voz HD (${_selectedVoiceName.split(' ').first})...';
    });
    _ensureCurrentSegmentTokensCached();

    widget.onProgressUpdated?.call(playableChapter, safeSeg, segs.length, initialSeekMs);
    await _playSegmentAtIndex(safeSeg, gen, initialSeekMs, initialWordRatio);
  }

  void _scrollToCurrentSegment(int index) {
    if (_viewMode != 1) return;
    if (_lastAutoScrolledSegment == index) return;
    _lastAutoScrolledSegment = index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _activeSegmentKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
          alignment: 0.25,
        );
      }
    });
  }

  Future<void> _playSegmentAtIndex(
    int index, [
    int? ignoredGen,
    int seekToMs = 0,
    double initialWordRatio = 0.0,
  ]) async {
    if (!mounted) return;
    if (index < 0 || index >= _segments.length) return;

    final int gen = ++_synthesisGeneration;
    ++_prefetchGeneration;
    _isHandlingCompletion = true;
    final voiceKey = _selectedVoiceKey;
    final chapter = _currentChapter;

    // Pausar inmediatamente la música ambiental para que jamás suene sola mientras carga un segmento
    NativeChannelService.pauseLoFi();

    final currentSegText = _segments[index];
    final bool alreadyCached = await _ttsService.isSegmentCached(
      bookId: widget.book.id,
      chapter: chapter,
      segIdx: index,
      voiceKey: voiceKey,
      text: currentSegText,
    );
    if (gen != _synthesisGeneration || !mounted) return;

    setState(() {
      _currentSegmentIndex = index;
      _bufferedUpToSegment = max(_bufferedUpToSegment, index + (alreadyCached ? 1 : 0));
      widget.book.lastChapterIndex = widget.book.chapters
          .indexWhere((c) => c.id == chapter.id)
          .clamp(0, widget.book.chapters.length - 1);
      widget.book.lastSegmentIndex = index;
      if (!alreadyCached) {
        _isSynthesizing = true;
      } else {
        _isSynthesizing = false;
        _statusMessage = '';
      }
    });
    _ensureCurrentSegmentTokensCached();
    _syncToGlobalService();
    widget.onProgressUpdated?.call(_currentChapter, index, _segments.length, seekToMs);
    _scrollToCurrentSegment(index);

    // 1. Fase de Red / Caché con reintento automático si se corta el 4G/LTE en el colectivo
    File? audioFile;
    int networkAttempt = 0;
    while (mounted && gen == _synthesisGeneration && !_userRequestedPause) {
      try {
        audioFile = await _ttsService.synthesizeSegment(
          bookId: widget.book.id,
          chapter: chapter,
          segIdx: index,
          text: currentSegText,
          voiceKey: voiceKey,
        );
        break;
      } catch (e) {
        networkAttempt++;
        if (!mounted || gen != _synthesisGeneration || _userRequestedPause) return;

        setState(() {
          _isSynthesizing = true;
          _statusMessage =
              'Señal inestable • Reconectando automáticamente (intento $networkAttempt)...';
        });

        await Future<void>.delayed(const Duration(milliseconds: 1800));
      }
    }

    if (audioFile == null || gen != _synthesisGeneration || !mounted || _userRequestedPause) {
      return;
    }

    // 2. Fase de Reproductor Local con reintento automático ante colisiones de cambio de sección
    Uri? artUri;
    try {
      if (widget.book.coverImagePath != null &&
          await File(widget.book.coverImagePath!).exists()) {
        artUri = Uri.file(widget.book.coverImagePath!);
      } else if (widget.book.coverUrl != null) {
        artUri = Uri.parse(widget.book.coverUrl!);
      }
    } catch (_) {}

    for (int playerAttempt = 0; playerAttempt < 4; playerAttempt++) {
      if (gen != _synthesisGeneration || !mounted || _userRequestedPause) return;
      try {
        await widget.player.setAudioSource(
          AudioSource.uri(
            Uri.file(audioFile.path),
            tag: MediaItem(
              id: '${widget.book.id}_${chapter.id}_$index',
              album: widget.book.title,
              title: '${chapter.title} (${index + 1}/${_segments.length})',
              artist: widget.book.author,
              artUri: artUri,
            ),
          ),
        );

        int effectiveSeekMs = seekToMs;
        if (effectiveSeekMs <= 500 && initialWordRatio > 0.05) {
          final timings = _ttsService.getWordTimings(
            widget.book.id,
            chapter,
            index,
            voiceKey,
          );
          if (timings != null && timings.isNotEmpty) {
            final tIdx = (initialWordRatio * timings.length)
                .floor()
                .clamp(0, timings.length - 1);
            effectiveSeekMs = max(0, timings[tIdx].startMs - 80);
          } else if (widget.player.duration != null) {
            effectiveSeekMs =
                (widget.player.duration!.inMilliseconds * initialWordRatio).round();
          }
        }

        if (effectiveSeekMs > 250) {
          await widget.player.seek(Duration(milliseconds: effectiveSeekMs));
        }

        await widget.player.setSpeed(_playbackSpeed);
        try {
          await widget.player.setPitch(1.0);
        } catch (_) {}

        if (!mounted || gen != _synthesisGeneration) return;
        _isHandlingCompletion = false;
        setState(() {
          _isSynthesizing = false;
          _statusMessage = '';
          _bufferedUpToSegment = max(_bufferedUpToSegment, index + 1);
        });
        _syncToGlobalService();

        if (_userRequestedPause) return;

        unawaited(widget.player.play().catchError((_) {}));

        if (_ambientVolume > 0 && !_userRequestedPause) {
          NativeChannelService.setLoFiVolume(_ambientVolume);
          NativeChannelService.playLoFi();
        }
        _syncAmbientAnimationTicker();

        // 3. Pre-descarga continua de TODA la sección actual en segundo plano (estilo YouTube)
        _startSequentialPrefetch(chapter, index + 1, voiceKey, gen);
        break;
      } catch (_) {
        if (playerAttempt == 3) {
          if (mounted && gen == _synthesisGeneration) {
            _isHandlingCompletion = false;
            setState(() {
              _isSynthesizing = false;
              _statusMessage = '';
            });
          }
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 140));
        }
      }
    }
  }

  /// Pre-descarga continua estilo YouTube:
  /// Va guardando en caché todos los párrafos restantes de la sección actual y actualiza en vivo
  /// la barra secundaria de buffer (`_bufferedUpToSegment`) delante del punto de reproducción.
  Future<void> _startSequentialPrefetch(
    ChapterItem chapter,
    int startIdx,
    String voiceKey,
    int gen,
  ) async {
    final prefetchId = ++_prefetchGeneration;
    final segs = chapter.getSegmentsForLanguage(widget.book.activeAudioLanguage);

    // 1. Escanear rápido cuántos segmentos consecutivos ya estaban en disco
    int contiguousCached = startIdx;
    for (int i = startIdx; i < segs.length; i++) {
      final cached = await _ttsService.isSegmentCached(
        bookId: widget.book.id,
        chapter: chapter,
        segIdx: i,
        voiceKey: voiceKey,
        text: segs[i],
      );
      if (cached) {
        contiguousCached = i + 1;
      } else {
        break;
      }
    }
    if (mounted &&
        prefetchId == _prefetchGeneration &&
        _currentChapter.id == chapter.id &&
        contiguousCached > _bufferedUpToSegment) {
      setState(() {
        _bufferedUpToSegment = contiguousCached;
      });
      _syncToGlobalService();
    }

    // 2. Pre-cargar toda la sección actual de principio a fin con reintento ante microcortes de 4G
    for (int i = contiguousCached; i < segs.length; i++) {
      if (prefetchId != _prefetchGeneration ||
          _currentChapter.id != chapter.id ||
          !mounted ||
          _userRequestedPause) {
        return;
      }
      bool ok = false;
      for (int retry = 0; retry < 3; retry++) {
        if (prefetchId != _prefetchGeneration ||
            _currentChapter.id != chapter.id ||
            !mounted ||
            _userRequestedPause) {
          return;
        }
        try {
          await _ttsService.synthesizeSegment(
            bookId: widget.book.id,
            chapter: chapter,
            segIdx: i,
            text: segs[i],
            voiceKey: voiceKey,
          );
          ok = true;
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 1600));
        }
      }

      if (ok &&
          mounted &&
          prefetchId == _prefetchGeneration &&
          _currentChapter.id == chapter.id) {
        setState(() {
          _bufferedUpToSegment = max(_bufferedUpToSegment, i + 1);
        });
        _syncToGlobalService();
      }
    }

    // 3. Una vez que la sección actual está 100% pre-cargada, pre-cachear los primeros 4 párrafos del próximo capítulo
    final chIdx = widget.book.chapters.indexWhere((c) => c.id == chapter.id);
    if (chIdx != -1 && chIdx + 1 < widget.book.chapters.length) {
      final nextCh = widget.book.chapters[chIdx + 1];
      final nextSegs = nextCh.getSegmentsForLanguage(widget.book.activeAudioLanguage);
      for (int k = 0; k < min(4, nextSegs.length); k++) {
        if (prefetchId != _prefetchGeneration ||
            _currentChapter.id != chapter.id ||
            !mounted ||
            _userRequestedPause) {
          return;
        }
        try {
          await _ttsService.synthesizeSegment(
            bookId: widget.book.id,
            chapter: nextCh,
            segIdx: k,
            text: nextSegs[k],
            voiceKey: voiceKey,
          );
        } catch (_) {}
      }
    }
  }

  void _onSegmentCompleted() {
    if (_isSynthesizing || _isHandlingCompletion || _userRequestedPause) return;
    _isHandlingCompletion = true;
    NativeChannelService.pauseLoFi();

    if (_currentSegmentIndex + 1 < _segments.length) {
      _playSegmentAtIndex(_currentSegmentIndex + 1, _synthesisGeneration);
    } else {
      if (audioPlayerService.consumeEndOfChapterSleepIfActive()) {
        _isHandlingCompletion = false;
        setState(() {
          _userRequestedPause = true;
          _isPlaying = false;
          _statusMessage = 'Temporizador: Fin del capítulo alcanzado 🌙';
        });
        _syncAmbientAnimationTicker();
        _saveExactPositionNow();
        return;
      }

      final idx = widget.book.chapters.indexWhere((c) => c.id == _currentChapter.id);
      if (idx != -1 && idx + 1 < widget.book.chapters.length) {
        _startChapterPlayback(widget.book.chapters[idx + 1], startSegment: 0);
      } else {
        _isHandlingCompletion = false;
        NativeChannelService.pauseLoFi();
      }
    }
  }

  Duration get _chapterTotalDuration {
    return Duration(seconds: max(15, _currentChapter.estimatedTotalSeconds));
  }

  Duration get _chapterElapsedPosition {
    if (_segments.isEmpty) return Duration.zero;
    final totalSec = _chapterTotalDuration.inSeconds;
    final secPerSeg = totalSec / _segments.length;
    final baseSec = (_currentSegmentIndex * secPerSeg).round();
    final elapsed = baseSec + _position.inSeconds;
    return Duration(seconds: elapsed.clamp(0, totalSec));
  }

  Duration get _chapterBufferedPosition {
    if (_segments.isEmpty) return Duration.zero;
    final totalSec = _chapterTotalDuration.inSeconds;
    final int bufferedSegs = max(_currentSegmentIndex + 1, _bufferedUpToSegment)
        .clamp(0, _segments.length);
    final int bufSec = ((bufferedSegs / _segments.length) * totalSec).round();
    return Duration(
      seconds: max(_chapterElapsedPosition.inSeconds, bufSec).clamp(0, totalSec),
    );
  }

  Duration get _fullBookTotalDuration {
    return Duration(seconds: max(60, widget.book.estimatedBookTotalSeconds));
  }

  Duration get _fullBookElapsedPosition {
    int secBefore = 0;
    for (final ch in widget.book.chapters) {
      if (ch.id == _currentChapter.id) break;
      secBefore += ch.estimatedTotalSeconds;
    }
    return Duration(seconds: secBefore + _chapterElapsedPosition.inSeconds);
  }

  Duration get _fullBookBufferedPosition {
    int secBefore = 0;
    for (final ch in widget.book.chapters) {
      if (ch.id == _currentChapter.id) break;
      secBefore += ch.estimatedTotalSeconds;
    }
    return Duration(seconds: secBefore + _chapterBufferedPosition.inSeconds);
  }

  void _seekWithinCurrentChapter(double targetSeconds) {
    if (_segments.isEmpty) return;
    _userRequestedPause = false;
    final totalSec = max(1, _chapterTotalDuration.inSeconds);
    final ratio = (targetSeconds / totalSec).clamp(0.0, 0.999);
    final targetSeg = (ratio * _segments.length)
        .floor()
        .clamp(0, max<int>(0, _segments.length - 1));
    _playSegmentAtIndex(targetSeg, _synthesisGeneration);
  }

  void _seekAcrossFullBook(double targetSeconds) {
    _userRequestedPause = false;
    int acc = 0;
    for (final ch in widget.book.chapters) {
      final chSec = ch.estimatedTotalSeconds;
      if (targetSeconds <= acc + chSec || ch == widget.book.chapters.last) {
        final localSec = (targetSeconds - acc).clamp(0.0, chSec.toDouble());
        final localRatio = (localSec / max(1, chSec)).clamp(0.0, 0.999);
        final segs = ch.segments;
        final targetSeg = (localRatio * segs.length).floor();
        if (ch.id == _currentChapter.id) {
          _playSegmentAtIndex(targetSeg, _synthesisGeneration);
        } else {
          _startChapterPlayback(ch, startSegment: targetSeg);
        }
        return;
      }
      acc += chSec;
    }
  }

  int _getActiveWordIndexForCurrentSegment(List<String> tokens) {
    if (tokens.isEmpty) return -1;
    final posMs = _position.inMilliseconds;
    final currentText = (_currentSegmentIndex >= 0 && _currentSegmentIndex < _segments.length)
        ? _segments[_currentSegmentIndex]
        : null;
    final timings = _ttsService.getWordTimings(
      widget.book.id,
      _currentChapter,
      _currentSegmentIndex,
      _selectedVoiceKey,
      text: currentText,
    );

    if (timings != null && timings.isNotEmpty) {
      int eventIdx = -1;
      for (int i = 0; i < timings.length; i++) {
        if (posMs >= timings[i].startMs - 40) {
          eventIdx = i;
        } else {
          break;
        }
      }
      if (eventIdx == -1) return 0;
      final ratio = eventIdx / max(1, timings.length - 1);
      final expectedIdx = (ratio * (tokens.length - 1)).round().clamp(0, tokens.length - 1);

      final spokenWord = timings[eventIdx]
          .word
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-záéíóúñü0-9]'), '');
      if (spokenWord.isNotEmpty && _cachedCleanTokens.length == tokens.length) {
        final minSearch = max(0, expectedIdx - 4);
        final maxSearch = min(tokens.length - 1, expectedIdx + 4);
        int bestIdx = expectedIdx;
        int bestDist = 999;
        for (int k = minSearch; k <= maxSearch; k++) {
          final cleanToken = _cachedCleanTokens[k];
          if (cleanToken == spokenWord ||
              (spokenWord.length >= 4 && cleanToken.startsWith(spokenWord))) {
            final dist = (k - expectedIdx).abs();
            if (dist < bestDist) {
              bestDist = dist;
              bestIdx = k;
            }
          }
        }
        return bestIdx;
      }

      return expectedIdx;
    }

    final totalMs = max(1200, _duration.inMilliseconds);
    final progress = (posMs / totalMs).clamp(0.0, 0.999);
    int totalChars = 0;
    for (final t in tokens) {
      totalChars += t.length + 1;
    }
    final targetChar = (progress * totalChars).round();
    int running = 0;
    for (int i = 0; i < tokens.length; i++) {
      running += tokens[i].length + 1;
      if (running >= targetChar) return i;
    }
    return tokens.length - 1;
  }

  void _setPlaybackSpeed(double newSpeed) {
    final clamped = (newSpeed * 20).round() / 20.0;
    final safeSpeed = clamped.clamp(0.70, 2.00);
    setState(() {
      _playbackSpeed = safeSpeed;
    });
    widget.player.setSpeed(_playbackSpeed);
    try {
      widget.player.setPitch(1.0);
    } catch (_) {}
    _repository.savePlayerPreferences(speed: _playbackSpeed);
  }

  void _showSpeedModal() {
    final presets = <Map<String, dynamic>>[
      {'speed': 0.75, 'label': '0.75x', 'desc': 'Lento'},
      {'speed': 0.90, 'label': '0.9x', 'desc': 'Pausado'},
      {'speed': 1.00, 'label': '1.0x', 'desc': 'Natural'},
      {'speed': 1.10, 'label': '1.1x', 'desc': 'Fluido'},
      {'speed': 1.25, 'label': '1.25x', 'desc': 'Ágil'},
      {'speed': 1.50, 'label': '1.5x', 'desc': 'Rápido'},
      {'speed': 1.75, 'label': '1.75x', 'desc': 'Veloz'},
      {'speed': 2.00, 'label': '2.0x', 'desc': 'Máximo'},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181A20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.speed_rounded, color: Color(0xFFF5A623), size: 24),
                            SizedBox(width: 10),
                            Text(
                              'Velocidad de Narración',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5A623).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFF5A623)),
                          ),
                          child: Text(
                            '${_playbackSpeed.toStringAsFixed(_playbackSpeed % 0.1 == 0 ? 1 : 2)}x',
                            style: const TextStyle(
                              color: Color(0xFFF5A623),
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Se guarda automáticamente para todos tus capítulos y libros',
                        style: TextStyle(color: Colors.white54, fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        IconButton.filledTonal(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white10,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.remove_rounded),
                          onPressed: () {
                            _setPlaybackSpeed(_playbackSpeed - 0.05);
                            setModalState(() {});
                          },
                        ),
                        Expanded(
                          child: Slider(
                            value: _playbackSpeed.clamp(0.70, 2.00),
                            min: 0.70,
                            max: 2.00,
                            divisions: 26,
                            activeColor: const Color(0xFFF5A623),
                            inactiveColor: Colors.white12,
                            onChanged: (val) {
                              _setPlaybackSpeed(val);
                              setModalState(() {});
                            },
                          ),
                        ),
                        IconButton.filledTonal(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white10,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.add_rounded),
                          onPressed: () {
                            _setPlaybackSpeed(_playbackSpeed + 0.05);
                            setModalState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: presets.map((p) {
                        final double sp = p['speed'] as double;
                        final bool isSelected = (_playbackSpeed - sp).abs() < 0.03;
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () {
                            _setPlaybackSpeed(sp);
                            setModalState(() {});
                          },
                          child: Container(
                            width: 76,
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFFF5A623)
                                  : Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected ? const Color(0xFFF5A623) : Colors.white12,
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  p['label'] as String,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13.5,
                                    color: isSelected ? Colors.black : Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  p['desc'] as String,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: isSelected ? Colors.black87 : Colors.white54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _togglePlayPause() {
    if (_isSynthesizing) {
      _userRequestedPause = true;
      _synthesisGeneration++;
      _prefetchGeneration++;
      NativeChannelService.pauseLoFi();
      widget.player.pause();
      setState(() {
        _isSynthesizing = false;
        _isPlaying = false;
        _statusMessage = 'Pausado';
      });
      _syncAmbientAnimationTicker();
      _syncToGlobalService();
      _saveExactPositionNow();
      return;
    }

    if (_isPlaying) {
      _userRequestedPause = true;
      NativeChannelService.pauseLoFi();
      widget.player.pause();
      setState(() {
        _isPlaying = false;
      });
      _syncAmbientAnimationTicker();
      _syncToGlobalService();
      _saveExactPositionNow();
    } else {
      _userRequestedPause = false;
      widget.player.setVolume(1.0);
      _syncToGlobalService();
      if (widget.player.audioSource == null) {
        _playSegmentAtIndex(
          _currentSegmentIndex,
          ++_synthesisGeneration,
          _position.inMilliseconds,
        );
      } else {
        widget.player.play();
        if (_ambientVolume > 0) {
          NativeChannelService.setLoFiVolume(_ambientVolume);
          NativeChannelService.playLoFi();
        }
      }
    }
  }

  void _showSleepTimerModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16181D),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => SleepTimerSheet(currentChapter: _currentChapter),
    );
  }

  void _showLoFiModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => AmbientMusicSheet(
        initialVolume: _ambientVolume,
        initialTrackId: _selectedAmbientTrackId,
        onVolumeChanged: (val) {
          setState(() => _ambientVolume = val);
          _repository.savePlayerPreferences(ambientVolume: val);
          NativeChannelService.setLoFiVolume(val);
          if (val > 0 && _isPlaying) {
            NativeChannelService.playLoFi();
          } else if (val == 0) {
            NativeChannelService.pauseLoFi();
          }
        },
        onTrackSelected: (trackId, vol) {
          setState(() {
            _selectedAmbientTrackId = trackId;
            _ambientVolume = vol;
          });
          _repository.savePlayerPreferences(
            ambientTrackId: trackId,
            ambientVolume: vol,
          );
          NativeChannelService.selectAndPlayTrack(
            trackId,
            vol,
            shouldPlayNow: _isPlaying,
          );
        },
      ),
    );
  }

  void _showVoicesModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1B1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => VoicesSelectorSheet(
        selectedVoiceKey: _selectedVoiceKey,
        onVoiceSelected: (voiceKey, voiceName) {
          setState(() {
            _selectedVoiceKey = voiceKey;
            _selectedVoiceName = voiceName;
          });
          _repository.savePlayerPreferences(
            voiceKey: voiceKey,
            voiceName: voiceName,
          );
          _startChapterPlayback(
            _currentChapter,
            startSegment: _currentSegmentIndex,
          );
        },
      ),
    );
  }

  void _openChapterNoteEditor(ChapterItem targetChapter, {VoidCallback? onSheetUpdated}) {
    final bool isCurrentCh = targetChapter.id == _currentChapter.id;
    final String? spokenSnippet = (isCurrentCh &&
            _segments.isNotEmpty &&
            _currentSegmentIndex >= 0 &&
            _currentSegmentIndex < _segments.length)
        ? _segments[_currentSegmentIndex]
        : null;
    final int? spokenSegNum = isCurrentCh ? (_currentSegmentIndex + 1) : null;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChapterNoteEditorSheet(
          book: widget.book,
          chapter: targetChapter,
          currentSpokenParagraph: spokenSnippet,
          currentSegmentNumber: spokenSegNum,
          onNoteChanged: () {
            if (mounted) {
              setState(() {});
            }
            onSheetUpdated?.call();
          },
        ),
      ),
    );
  }

  void _showChaptersModal() {
    final bookElapsedSec = _fullBookElapsedPosition.inSeconds;
    final bookTotalSec = max(1, _fullBookTotalDuration.inSeconds);
    final bookPercent = ((bookElapsedSec / bookTotalSec) * 100).clamp(0.0, 100.0).round();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF18191D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) => ChaptersListSheet(
        book: widget.book,
        currentChapter: _currentChapter,
        currentSegmentIndex: _currentSegmentIndex,
        totalSegmentsInCurrentChapter: _segments.length,
        bookPercent: bookPercent,
        selectedVoiceKey: _selectedVoiceKey,
        downloadService: _downloadService,
        onSelectChapter: (ch) => _startChapterPlayback(ch, startSegment: 0),
        onOpenChapterNote: (ch, onNoteSaved) =>
            _openChapterNoteEditor(ch, onSheetUpdated: onNoteSaved),
      ),
    );
  }

  void _openDocumentViewer() {
    final curIdx = widget.book.chapters
        .indexWhere((c) => c.id == _currentChapter.id)
        .clamp(0, max<int>(0, widget.book.chapters.length - 1))
        .toInt();
    final String? snippet = (_segments.isNotEmpty &&
            _currentSegmentIndex >= 0 &&
            _currentSegmentIndex < _segments.length)
        ? _segments[_currentSegmentIndex]
        : null;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentViewerScreen(
          book: widget.book,
          player: widget.player,
          initialChapterIndex: curIdx,
          activeSegmentIndex: _currentSegmentIndex,
          totalSegmentsInChapter: _segments.length,
          currentSpokenSnippet: snippet,
          onBookFileLinked: () {
            _saveExactPositionNow();
          },
          onSeekToPosition: (chIdx, segIdx) {
            if (chIdx < 0 || chIdx >= widget.book.chapters.length) return;
            final targetCh = widget.book.chapters[chIdx];
            widget.book.lastChapterIndex = chIdx;
            widget.book.lastSegmentIndex = segIdx;
            widget.book.totalSegmentsInLastChapter = max(1, targetCh.segments.length);
            _userRequestedPause = false;
            if (targetCh.id == _currentChapter.id) {
              _playSegmentAtIndex(segIdx, ++_synthesisGeneration);
            } else {
              _startChapterPlayback(targetCh, startSegment: segIdx);
            }
          },
          onSeekToExactRatio: (chIdx, segIdx, wordRatio) {
            if (chIdx < 0 || chIdx >= widget.book.chapters.length) return;
            final targetCh = widget.book.chapters[chIdx];
            widget.book.lastChapterIndex = chIdx;
            widget.book.lastSegmentIndex = segIdx;
            widget.book.totalSegmentsInLastChapter = max(1, targetCh.segments.length);
            _userRequestedPause = false;
            if (targetCh.id == _currentChapter.id) {
              _playSegmentAtIndex(segIdx, ++_synthesisGeneration, 0, wordRatio);
            } else {
              _startChapterPlayback(
                targetCh,
                startSegment: segIdx,
                initialWordRatio: wordRatio,
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _toggleAudioLanguage() async {
    final newLang = widget.book.activeAudioLanguage == 'es' ? 'en' : 'es';
    widget.book.activeAudioLanguage = newLang;

    if (newLang == 'es') {
      final ch = _currentChapter;
      final isTextEnglish = BookTranslationService.detectLanguage(ch.textContent) == 'en';
      if (isTextEnglish && (ch.originalLanguageSegments == null || ch.originalLanguageSegments!.isEmpty)) {
        setState(() {
          _isSynthesizing = true;
          _statusMessage = 'Traduciendo capítulo al español...';
        });
        try {
          final translated = await BookTranslationService.translateSingleChapter(ch);
          final chIdx = widget.book.chapters.indexWhere((c) => c.id == ch.id);
          if (chIdx != -1) {
            widget.book.chapters[chIdx] = translated;
            _currentChapter = translated;
          }
        } catch (_) {}
      }
    }

    // Actualizar voz predeterminada acorde al idioma
    final newVoiceKey = newLang == 'en' ? 'en-US-GuyNeural' : 'es-MX-JorgeNeural';
    final newVoiceName = TtsSynthesisService.voicesMap[newVoiceKey] ??
        (newLang == 'en' ? 'Guy HD (EE. UU. 🇺🇸 • Cálido y narrativo)' : 'Jorge HD (México 🇲🇽 • Cálido)');

    setState(() {
      _selectedVoiceKey = newVoiceKey;
      _selectedVoiceName = newVoiceName;
    });

    await _repository.savePlayerPreferences(
      voiceKey: newVoiceKey,
      voiceName: newVoiceName,
    );

    // Reiniciar reproducción en el segmento actual con el nuevo idioma
    _startChapterPlayback(
      _currentChapter,
      startSegment: _currentSegmentIndex,
      initialSeekMs: 0,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newLang == 'es' ? '🇪🇸 Audio cambiado a Español' : '🇺🇸 Audio cambiado a Inglés (Original)',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          duration: const Duration(seconds: 2),
          backgroundColor: newLang == 'es' ? const Color(0xFFEAA036) : const Color(0xFF1976D2),
        ),
      );
    }
  }

  void _showQuickOptionsSheet() {
    final bool hasBilingual = widget.book.chapters.any(
      (c) => c.originalLanguageSegments != null && c.originalLanguageSegments!.isNotEmpty,
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141519),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 14),
                ListTile(
                  leading: Icon(
                    _viewMode == 1 ? Icons.album_rounded : Icons.article_rounded,
                    color: const Color(0xFFF5A623),
                  ),
                  title: Text(
                    _viewMode == 1 ? 'Cambiar a Vista Portada' : 'Cambiar a Vista Texto Limpio',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _viewMode = _viewMode == 1 ? 0 : 1;
                      _immersiveTextMode = false;
                      _lastAutoScrolledSegment = -1;
                    });
                    _syncAmbientAnimationTicker();
                    if (_viewMode == 1) {
                      _scrollToCurrentSegment(_currentSegmentIndex);
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.auto_stories_rounded, color: Color(0xFFF5A623)),
                  title: Text(
                    'Ver documento original (${widget.book.fileType?.toUpperCase() ?? 'PDF'})',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openDocumentViewer();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit_note_rounded, color: Color(0xFFF5A623)),
                  title: Text(
                    _currentChapter.hasNote
                        ? 'Ver / Editar nota de esta sección'
                        : 'Escribir nota en esta sección',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openChapterNoteEditor(_currentChapter);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.format_list_bulleted_rounded, color: Color(0xFFF5A623)),
                  title: Text(
                    'Capítulos del libro (${widget.book.chapters.length})',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showChaptersModal();
                  },
                ),
                if (hasBilingual)
                  ListTile(
                    leading: const Icon(Icons.translate_rounded, color: Color(0xFFF5A623)),
                    title: Text(
                      widget.book.activeAudioLanguage == 'es'
                          ? 'Cambiar audio a Inglés Original (🇺🇸 EN)'
                          : 'Cambiar audio a Español (🇪🇸 ES)',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleAudioLanguage();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    final bool hasBilingual = widget.book.detectedLanguage == 'en' ||
        widget.book.chapters.any(
          (c) => c.originalLanguageSegments != null && c.originalLanguageSegments!.isNotEmpty,
        );

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30, color: Colors.white),
              tooltip: 'Minimizar',
              onPressed: () => Navigator.pop(context),
            ),
            // Switch central Portada / Texto
            Container(
              height: 36,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildModePillButton(
                    index: 0,
                    icon: Icons.headphones_rounded,
                    label: 'Portada',
                  ),
                  _buildModePillButton(
                    index: 1,
                    icon: Icons.menu_book_rounded,
                    label: 'Texto',
                  ),
                ],
              ),
            ),
            // Derecha: Botón directo Español <-> Inglés + Opciones/PDF
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasBilingual)
                  GestureDetector(
                    onTap: _toggleAudioLanguage,
                    child: Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E2026),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: widget.book.activeAudioLanguage == 'es'
                              ? const Color(0xFFF5A623)
                              : const Color(0xFF64B5F6),
                        ),
                      ),
                      child: Text(
                        widget.book.activeAudioLanguage == 'es' ? '🇪🇸 ES' : '🇺🇸 EN',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: widget.book.activeAudioLanguage == 'es'
                              ? const Color(0xFFF5A623)
                              : const Color(0xFF64B5F6),
                        ),
                      ),
                    ),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.more_horiz_rounded, size: 25, color: Colors.white),
                  tooltip: 'Opciones',
                  onPressed: _showQuickOptionsSheet,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModePillButton({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final bool selected = _viewMode == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _viewMode = index;
          _immersiveTextMode = false;
          _lastAutoScrolledSegment = -1;
        });
        _syncAmbientAnimationTicker();
        if (index == 1) {
          _scrollToCurrentSegment(_currentSegmentIndex);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF5A623) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? Colors.black : Colors.white60,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? Colors.black : Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoverModeView() {
    final Color primaryCoverColor = _ambientColors.first;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxH = constraints.maxHeight;
        final double maxW = constraints.maxWidth;
        final double availableH = max(260.0, maxH - 235.0);
        final double coverWidth = min(maxW * 0.66, availableH * 0.56).clamp(145.0, 245.0);
        final double coverHeight = (coverWidth * 1.38).clamp(195.0, 330.0);

        return Padding(
          padding: const EdgeInsets.fromLTRB(26, 6, 26, 235),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Portada con halo reactivo de color de portada y ondas de audio estilo Spotify moderno
              Center(
                child: AnimatedBuilder(
                  animation: _ambientAnimController,
                  builder: (context, child) {
                    final double pulse = _isPlaying
                        ? (0.96 + (_ambientAnimController.value * 0.08))
                        : 0.92;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // Halo difuso ligero con RadialGradient (0% GPU thermal overhead)
                        Transform.scale(
                          scale: pulse * 1.28,
                          child: Container(
                            width: coverWidth * 1.32,
                            height: coverHeight * 1.18,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  primaryCoverColor.withValues(
                                    alpha: _isPlaying ? 0.58 : 0.28,
                                  ),
                                  const Color(0xFFF5A623).withValues(
                                    alpha: _isPlaying ? 0.18 : 0.06,
                                  ),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                        AnimatedScale(
                          scale: _isPlaying ? 1.0 : 0.94,
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutBack,
                          child: BookCoverWidget(
                            book: widget.book,
                            width: coverWidth,
                            height: coverHeight,
                            borderRadius: 20,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              // Visualizador de ondas de audio estilo Spotify Canvas + Info limpia del libro
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SpotifyAudioVisualizer(
                    isPlaying: _isPlaying,
                    position: _position,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _currentChapter.title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _statusMessage.isNotEmpty
                        ? _statusMessage
                        : '${widget.book.title} • Párr. ${_currentSegmentIndex + 1}/${max(1, _segments.length)}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: _statusMessage.isNotEmpty
                          ? const Color(0xFFF5A623)
                          : Colors.white60,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKaraokeTextView() {
    final int chNumber =
        (widget.book.chapters.indexWhere((c) => c.id == _currentChapter.id) + 1)
            .clamp(1, max(1, widget.book.chapters.length));
    final String formattedChHeader =
        '${chNumber.toString().padLeft(2, '0')}. ${_currentChapter.title.toUpperCase()}';

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        setState(() {
          _immersiveTextMode = !_immersiveTextMode;
        });
      },
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          _immersiveTextMode ? 56 : 16,
          24,
          _immersiveTextMode ? 80 : 270,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Text(
                formattedChHeader,
                style: TextStyle(
                  fontFamily: GoogleFonts.inter().fontFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1.25,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            if (_statusMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFFF5A623),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusMessage,
                        style: const TextStyle(
                          color: Color(0xFFF5A623),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ...List.generate(_segments.length, (idx) {
              final bool isCurrentSeg = idx == _currentSegmentIndex;
              final String segText = _segments[idx];

              if (!isCurrentSeg) {
                return RepaintBoundary(
                  child: GestureDetector(
                    onTap: () {
                      if (_immersiveTextMode) {
                        setState(() => _immersiveTextMode = false);
                        return;
                      }
                      _playSegmentAtIndex(idx, _synthesisGeneration);
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Text(
                        segText,
                        style: TextStyle(
                          fontFamily: GoogleFonts.inter().fontFamily,
                          fontSize: 19,
                          height: 1.65,
                          color: idx < _currentSegmentIndex
                              ? Colors.white.withValues(alpha: 0.42)
                              : Colors.white.withValues(alpha: 0.68),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              }

              _ensureCurrentSegmentTokensCached();
              final List<String> tokens = _cachedTokens;
              final int activeWordIdx = _getActiveWordIndexForCurrentSegment(tokens);

              return RepaintBoundary(
                child: GestureDetector(
                  key: _activeSegmentKey,
                  onTap: () {
                    setState(() {
                      _immersiveTextMode = !_immersiveTextMode;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontFamily: GoogleFonts.inter().fontFamily,
                          fontSize: 19,
                          height: 1.65,
                        ),
                        children: List.generate(tokens.length, (wIdx) {
                          final bool isCurrentWord = wIdx == activeWordIdx;
                          return TextSpan(
                            text: '${tokens[wIdx]}${wIdx < tokens.length - 1 ? ' ' : ''}',
                            style: TextStyle(
                              color: isCurrentWord
                                  ? const Color(0xFFFFCA58)
                                  : Colors.white.withValues(alpha: 0.96),
                              fontWeight: isCurrentWord ? FontWeight.w800 : FontWeight.w400,
                              backgroundColor: isCurrentWord
                                  ? const Color(0xFFF5A623).withValues(alpha: 0.34)
                                  : const Color(0xFFF5A623).withValues(alpha: 0.16),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildUnifiedBottomControls() {
    final Duration baseElapsed =
        _sliderShowsFullBook ? _fullBookElapsedPosition : _chapterElapsedPosition;
    final Duration activeTotal =
        _sliderShowsFullBook ? _fullBookTotalDuration : _chapterTotalDuration;
    final Duration bufferedPos =
        _sliderShowsFullBook ? _fullBookBufferedPosition : _chapterBufferedPosition;

    final double maxSliderSec = max(1.0, activeTotal.inSeconds.toDouble());
    final double currentSliderSec = _draggingSliderSec != null
        ? _draggingSliderSec!.clamp(0.0, maxSliderSec)
        : baseElapsed.inSeconds.toDouble().clamp(0.0, maxSliderSec);
    final double bufferedSliderSec = max(
      currentSliderSec,
      bufferedPos.inSeconds.toDouble().clamp(0.0, maxSliderSec),
    );
    final Duration activeElapsed = Duration(seconds: currentSliderSec.round());

    final int remainingSec = max(0, activeTotal.inSeconds - activeElapsed.inSeconds);
    final int remMins = remainingSec ~/ 60;
    final bool isChapterFullyBuffered = _segments.isNotEmpty &&
        _bufferedUpToSegment >= _segments.length - 1;
    final int bufferedPercent = _segments.isEmpty
        ? 100
        : (((_bufferedUpToSegment + 1) / _segments.length) * 100).clamp(0, 100).round();
    final String remainingShort = remMins >= 60
        ? '${remMins ~/ 60}h ${remMins % 60}m rest.${!isChapterFullyBuffered && _bufferedUpToSegment >= _currentSegmentIndex ? ' • Buffer $bufferedPercent%' : ''}'
        : '${remMins}m restantes${!isChapterFullyBuffered && _bufferedUpToSegment >= _currentSegmentIndex ? ' • Buffer $bufferedPercent%' : ''}';

    String? draggingPreviewText;
    if (_draggingSliderSec != null && !_sliderShowsFullBook && _segments.isNotEmpty) {
      final ratio = (currentSliderSec / maxSliderSec).clamp(0.0, 0.999);
      final previewSeg = (ratio * _segments.length).floor() + 1;
      draggingPreviewText =
          'Párrafo $previewSeg de ${_segments.length} • ${TextSanitizer.formatDuration(activeElapsed)}';
    }

    final int chNumber =
        (widget.book.chapters.indexWhere((c) => c.id == _currentChapter.id) + 1)
            .clamp(1, max(1, widget.book.chapters.length));
    final String chapterPillTitle =
        '${chNumber.toString().padLeft(2, '0')}. ${_currentChapter.title.toUpperCase()}';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF09090B).withValues(alpha: 0.0),
            const Color(0xFF09090B).withValues(alpha: 0.86),
            const Color(0xFF09090B).withValues(alpha: 0.98),
            const Color(0xFF09090B),
          ],
          stops: const [0.0, 0.22, 0.48, 1.0],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.center,
                  child: GestureDetector(
                    onTap: _showChaptersModal,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 270),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1B20).withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.drag_indicator_rounded,
                            size: 15,
                            color: Colors.white54,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              chapterPillTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_viewMode == 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _immersiveTextMode = true);
                      },
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1B20).withValues(alpha: 0.94),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white12),
                        ),
                        child: const Icon(
                          Icons.chrome_reader_mode_outlined,
                          size: 18,
                          color: Color(0xFFF5A623),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: const Color(0xFFF5A623),
                secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.42),
                inactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: currentSliderSec,
                secondaryTrackValue: bufferedSliderSec,
                min: 0.0,
                max: maxSliderSec,
                onChangeStart: (val) {
                  setState(() => _draggingSliderSec = val);
                },
                onChanged: (val) {
                  setState(() => _draggingSliderSec = val);
                },
                onChangeEnd: (val) {
                  setState(() => _draggingSliderSec = null);
                  if (_sliderShowsFullBook) {
                    _seekAcrossFullBook(val);
                  } else {
                    _seekWithinCurrentChapter(val);
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    TextSanitizer.formatDuration(activeElapsed),
                    style: const TextStyle(color: Colors.white54, fontSize: 11.5),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _draggingSliderSec = null;
                        _sliderShowsFullBook = !_sliderShowsFullBook;
                      });
                    },
                    child: Text(
                      draggingPreviewText ?? remainingShort,
                      style: TextStyle(
                        color: draggingPreviewText != null
                            ? const Color(0xFFF5A623)
                            : Colors.white54,
                        fontSize: 11.5,
                        fontWeight: draggingPreviewText != null
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  Text(
                    TextSanitizer.formatDuration(activeTotal),
                    style: const TextStyle(color: Colors.white54, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: _showSleepTimerModal,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 52,
                    height: 44,
                    child: Center(
                      child: audioPlayerService.isSleepTimerActive
                          ? Text(
                              audioPlayerService.sleepTimerBadgeText,
                              style: const TextStyle(
                                color: Color(0xFFF5A623),
                                fontWeight: FontWeight.w900,
                                fontSize: 12.5,
                              ),
                            )
                          : const Text(
                              'zZz',
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                letterSpacing: -0.5,
                              ),
                            ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.replay_10_rounded, size: 30, color: Colors.white),
                  onPressed: () {
                    final newPos = _position - const Duration(seconds: 10);
                    widget.player.seek(newPos < Duration.zero ? Duration.zero : newPos);
                  },
                ),
                GestureDetector(
                  onTap: _togglePlayPause,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(
                      color: Color(0xFFF5A623),
                      shape: BoxShape.circle,
                    ),
                    child: _isSynthesizing
                        ? const Center(
                            child: SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2.8,
                              ),
                            ),
                          )
                        : Icon(
                            _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            size: 36,
                            color: Colors.black,
                          ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.forward_30_rounded, size: 30, color: Colors.white),
                  onPressed: () {
                    final newPos = _position + const Duration(seconds: 30);
                    if (newPos < _duration) {
                      widget.player.seek(newPos);
                    } else if (_currentSegmentIndex + 1 < _segments.length) {
                      _playSegmentAtIndex(_currentSegmentIndex + 1, _synthesisGeneration);
                    }
                  },
                ),
                GestureDetector(
                  onTap: _showSpeedModal,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 52,
                    height: 44,
                    child: Center(
                      child: Text(
                        '${_playbackSpeed.toStringAsFixed(_playbackSpeed % 0.1 == 0 ? 1 : 2)}x',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: _playbackSpeed != 1.0
                              ? const Color(0xFFF5A623)
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: Icon(
                    _ambientVolume > 0 ? Icons.volume_up_rounded : Icons.piano_rounded,
                    color: _ambientVolume > 0 ? const Color(0xFFF5A623) : Colors.white70,
                    size: 24,
                  ),
                  tooltip: 'Música clásica de fondo',
                  onPressed: _showLoFiModal,
                ),
                InkWell(
                  onTap: _showVoicesModal,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1B20),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircleAvatar(
                          radius: 10,
                          backgroundColor: Color(0xFFF5A623),
                          child: Icon(Icons.graphic_eq_rounded, size: 13, color: Colors.black),
                        ),
                        const SizedBox(width: 9),
                        Text(
                          _selectedVoiceName.split(' (').first,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _currentChapter.hasNote
                        ? Icons.sticky_note_2_rounded
                        : Icons.edit_note_rounded,
                    color: _currentChapter.hasNote
                        ? const Color(0xFFF5A623)
                        : Colors.white70,
                    size: 25,
                  ),
                  tooltip: 'Nota de esta sección',
                  onPressed: () => _openChapterNoteEditor(_currentChapter),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool hideChrome = _viewMode == 1 && _immersiveTextMode;

    return Scaffold(
      backgroundColor: const Color(0xFF09090B),
      body: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _ambientAnimController,
                builder: (context, _) {
                  if (_viewMode == 1) {
                    return const ColoredBox(color: Color(0xFF09090B));
                  }
                  final double t = _ambientAnimController.value;
                  final Color c1 = _ambientColors.first;
                  final Color c2 = _ambientColors.last;

                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment(-0.8 + t * 1.2, -1.0),
                              end: Alignment(0.8 - t * 1.2, 1.0),
                              colors: [c1, c2, const Color(0xFF09090B)],
                              stops: const [0.0, 0.52, 1.0],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 40 + (t * 45),
                        left: 10 + ((1 - t) * 40),
                        right: 10 + (t * 40),
                        child: IgnorePointer(
                          child: Container(
                            height: 320,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  c1.withValues(alpha: 0.48),
                                  c1.withValues(alpha: 0.16),
                                  Colors.transparent,
                                ],
                                stops: const [0.0, 0.55, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          Positioned.fill(
            child: Column(
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  child: hideChrome
                      ? const SizedBox(height: 12)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTopBar(),
                            ValueListenableBuilder<TranslationProgressInfo?>(
                              valueListenable: BookTranslationService.progressNotifier,
                              builder: (context, info, _) {
                                if (info == null || info.bookId != widget.book.id) {
                                  return const SizedBox.shrink();
                                }
                                return Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E1E24).withValues(alpha: 0.92),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: info.isCompleted
                                          ? const Color(0xFF81C784)
                                          : const Color(0xFFF5A623).withValues(alpha: 0.4),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!info.isCompleted)
                                        const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Color(0xFFF5A623),
                                          ),
                                        )
                                      else
                                        const Icon(
                                          Icons.check_circle_rounded,
                                          size: 16,
                                          color: Color(0xFF81C784),
                                        ),
                                      const SizedBox(width: 8),
                                      Text(
                                        info.statusText,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: info.isCompleted
                                              ? const Color(0xFF81C784)
                                              : Colors.white70,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: _viewMode == 0
                        ? _buildCoverModeView()
                        : _buildKaraokeTextView(),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: hideChrome,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                offset: hideChrome ? const Offset(0, 1.05) : Offset.zero,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  opacity: hideChrome ? 0.0 : 1.0,
                  child: _buildUnifiedBottomControls(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
