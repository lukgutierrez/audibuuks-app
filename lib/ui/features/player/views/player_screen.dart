import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../../../../core/utils/text_sanitizer.dart';
import '../../../../data/repositories/library_repository.dart';
import '../../../../data/services/cover_service.dart';
import '../../../../data/services/native_channel_service.dart';
import '../../../../data/services/offline_download_service.dart';
import '../../../../data/services/tts_synthesis_service.dart';
import '../../../../domain/models/ambient_track_info.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';
import '../../../shared/widgets/book_cover_widget.dart';
import '../../reader/views/document_viewer_screen.dart';

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
  // 0 = Modo Portada (YouTube Premium), 1 = Modo Texto Karaoke Minimalista
  int _viewMode = 0;

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
  int _synthesisGeneration = 0;
  int _prefetchGeneration = 0;
  int _lastSavedSecond = -1;

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
    _currentChapter = widget.initialChapter;
    _ambientAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    )..repeat(reverse: true);

    _loadCoverAmbientPalette();
    _setupAudioStreams();
    _initPreferencesAndStartPlayback();
  }

  Future<void> _initPreferencesAndStartPlayback() async {
    final prefs = await _repository.loadPlayerPreferences();
    if (!mounted) return;

    final savedSpeed = (prefs['speed'] as double?) ?? 1.0;
    final savedVoiceKey = (prefs['voiceKey'] as String?) ?? 'es-MX-JorgeNeural';
    final savedVoiceName =
        TtsSynthesisService.voicesMap[savedVoiceKey] ??
        (prefs['voiceName'] as String?) ??
        'Jorge HD (México 🇲🇽 • Cálido)';
    final savedVol = (prefs['ambientVolume'] as double?) ?? 0.25;
    final savedTrack = prefs['ambientTrackId'] as String?;

    setState(() {
      _playbackSpeed = savedSpeed.clamp(0.70, 2.00);
      _selectedVoiceKey = savedVoiceKey;
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveExactPositionNow();
      if (!_isPlaying) {
        NativeChannelService.pauseLoFi();
      }
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
        }
        return;
      }
      if (_isPlaying != state.playing) {
        setState(() => _isPlaying = state.playing);
      }

      if (state.playing && !_isSynthesizing && _ambientVolume > 0) {
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
      if (!mounted) return;
      // Solo reconstruir cuando la diferencia supera 120ms para ahorrar CPU en gama baja/media
      if ((pos.inMilliseconds - _position.inMilliseconds).abs() >= 120 ||
          pos == Duration.zero) {
        setState(() => _position = pos);
      }
      final sec = pos.inSeconds;
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
  }) async {
    _userRequestedPause = false;
    _isHandlingCompletion = false;
    final gen = ++_synthesisGeneration;
    NativeChannelService.pauseLoFi();
    await widget.player.stop();

    // Usa los segmentos ya cacheados en memoria en ChapterItem (O(1), 0ms en el hilo UI)
    final segs = chapter.segments;
    final int safeSeg = startSegment.clamp(0, max<int>(0, segs.length - 1)).toInt();

    if (!mounted) return;
    setState(() {
      _currentChapter = chapter;
      _segments = segs;
      _currentSegmentIndex = safeSeg;
      _lastAutoScrolledSegment = -1;
      _isSynthesizing = true;
      _statusMessage = 'Preparando voz HD (${_selectedVoiceName.split(' ').first})...';
    });

    widget.onProgressUpdated?.call(chapter, safeSeg, segs.length, initialSeekMs);
    await _playSegmentAtIndex(safeSeg, gen, initialSeekMs);
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

  Future<void> _playSegmentAtIndex(int index, [int? _ignoredGen, int seekToMs = 0]) async {
    if (!mounted) return;
    if (index < 0 || index >= _segments.length) return;

    // Cada cambio de párrafo genera un token único que invalida cualquier operación anterior en vuelo
    final int gen = ++_synthesisGeneration;
    _isHandlingCompletion = false;
    final voiceKey = _selectedVoiceKey;
    final chapter = _currentChapter;

    // Verificar si el párrafo ya está pre-cargado en caché local (estilo YouTube Music).
    // Si ya está en caché, NO mostramos el spinner de carga para que la transición sea 100% invisible y continua.
    final bool alreadyCached = await _ttsService.isSegmentCached(
      bookId: widget.book.id,
      chapter: chapter,
      segIdx: index,
      voiceKey: voiceKey,
    );
    if (gen != _synthesisGeneration || !mounted) return;

    setState(() {
      _currentSegmentIndex = index;
      if (!alreadyCached) {
        _isSynthesizing = true;
      } else {
        _isSynthesizing = false;
        _statusMessage = '';
      }
    });
    widget.onProgressUpdated?.call(_currentChapter, index, _segments.length, seekToMs);
    _scrollToCurrentSegment(index);

    // 1. Fase de Red / Caché (solo esta fase reintenta si se corta el 4G/LTE)
    File? audioFile;
    int networkAttempt = 0;
    while (mounted && gen == _synthesisGeneration && !_userRequestedPause) {
      try {
        audioFile = await _ttsService.synthesizeSegment(
          bookId: widget.book.id,
          chapter: chapter,
          segIdx: index,
          text: _segments[index],
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

        await Future<void>.delayed(const Duration(milliseconds: 2200));
      }
    }

    if (audioFile == null || gen != _synthesisGeneration || !mounted || _userRequestedPause) {
      return;
    }

    // 2. Arrancar INMEDIATAMENTE la pre-descarga en caché de los siguientes párrafos en segundo plano
    // mientras empieza a sonar este párrafo (así el próximo párrafo ya estará en disco antes de que termine este).
    _startSequentialPrefetch(chapter, index + 1, voiceKey, gen);

    // 3. Fase de Reproductor Local (aislada de errores de red: si el usuario cambia de página o párrafo rápido,
    // just_audio lanza PlayerInterruptedException que debe ignorarse silenciosamente).
    try {
      Uri? artUri;
      if (widget.book.coverImagePath != null &&
          await File(widget.book.coverImagePath!).exists()) {
        artUri = Uri.file(widget.book.coverImagePath!);
      } else if (widget.book.coverUrl != null) {
        artUri = Uri.parse(widget.book.coverUrl!);
      }

      if (gen != _synthesisGeneration || !mounted || _userRequestedPause) return;

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

      if (seekToMs > 500) {
        await widget.player.seek(Duration(milliseconds: seekToMs));
      }

      await widget.player.setSpeed(_playbackSpeed);
      try {
        await widget.player.setPitch(1.0);
      } catch (_) {}

      if (!mounted || gen != _synthesisGeneration) return;
      setState(() {
        _isSynthesizing = false;
        _statusMessage = '';
      });

      if (_userRequestedPause) return;

      // IMPORTANTE: No usar `await widget.player.play()` bloqueante porque en just_audio
      // ese Future no termina hasta que finaliza toda la pista o se interrumpe.
      unawaited(widget.player.play().catchError((_) {}));

      if (_ambientVolume > 0 && !_userRequestedPause) {
        NativeChannelService.setLoFiVolume(_ambientVolume);
        NativeChannelService.playLoFi();
      }
    } catch (_) {
      // Interrupción normal al cambiar de párrafo o página rápidamente
    }
  }

  /// Pre-descarga secuencial en segundo plano estilo YouTube Music:
  /// Va guardando en caché los próximos 12 párrafos y, cuando se acerca el final del capítulo,
  /// ya deja descargados los primeros 4 párrafos del capítulo siguiente para que la transición sea instantánea.
  Future<void> _startSequentialPrefetch(
    ChapterItem chapter,
    int startIdx,
    String voiceKey,
    int gen,
  ) async {
    final prefetchId = ++_prefetchGeneration;
    final segs = chapter.segments;

    for (int i = startIdx; i < min(segs.length, startIdx + 12); i++) {
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
      } catch (_) {
        // Si la red está débil, pausar el pre-fetch un momento para no competir con el audio principal
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    // Cuando faltan 6 párrafos o menos para terminar el capítulo, pre-cachear el inicio del próximo capítulo
    if (startIdx + 6 >= segs.length) {
      final chIdx = widget.book.chapters.indexWhere((c) => c.id == chapter.id);
      if (chIdx != -1 && chIdx + 1 < widget.book.chapters.length) {
        final nextCh = widget.book.chapters[chIdx + 1];
        final nextSegs = nextCh.segments;
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
  }

  void _onSegmentCompleted() {
    if (_isSynthesizing || _isHandlingCompletion || _userRequestedPause) return;
    _isHandlingCompletion = true;

    if (_currentSegmentIndex + 1 < _segments.length) {
      _playSegmentAtIndex(_currentSegmentIndex + 1, _synthesisGeneration);
    } else {
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
    final timings = _ttsService.getWordTimings(
      widget.book.id,
      _currentChapter,
      _currentSegmentIndex,
      _selectedVoiceKey,
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
      if (spokenWord.isNotEmpty) {
        final minSearch = max(0, expectedIdx - 4);
        final maxSearch = min(tokens.length - 1, expectedIdx + 4);
        int bestIdx = expectedIdx;
        int bestDist = 999;
        for (int k = minSearch; k <= maxSearch; k++) {
          final cleanToken = tokens[k]
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-záéíóúñü0-9]'), '');
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
      _saveExactPositionNow();
    } else {
      _userRequestedPause = false;
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

  void _showLoFiModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.65,
              minChildSize: 0.48,
              maxChildSize: 0.85,
              builder: (_, scrollController) {
                return ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 30),
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.piano_rounded, color: Color(0xFFF5A623), size: 24),
                            SizedBox(width: 10),
                            Text(
                              'Música Clásica Instrumental',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                            ),
                          ],
                        ),
                        Switch(
                          value: _ambientVolume > 0,
                          activeThumbColor: const Color(0xFFF5A623),
                          onChanged: (enabled) {
                            final newVol = enabled ? 0.25 : 0.0;
                            setModalState(() {});
                            setState(() => _ambientVolume = newVol);
                            _repository.savePlayerPreferences(ambientVolume: newVol);
                            if (newVol > 0 && _isPlaying) {
                              NativeChannelService.selectAndPlayTrack(
                                _selectedAmbientTrackId,
                                newVol,
                                shouldPlayNow: true,
                              );
                            } else {
                              NativeChannelService.setLoFiVolume(newVol);
                              NativeChannelService.pauseLoFi();
                            }
                          },
                        ),
                      ],
                    ),
                    const Text(
                      'Arpegios acústicos puros de piano y arpa sin ruido de fondo. Se pausa automáticamente al pausar la lectura.',
                      style: TextStyle(color: Colors.white60, fontSize: 12.5),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                _ambientVolume > 0
                                    ? Icons.volume_up_rounded
                                    : Icons.volume_off_rounded,
                                color: const Color(0xFFF5A623),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _ambientVolume,
                                  min: 0.0,
                                  max: 1.0,
                                  activeColor: const Color(0xFFF5A623),
                                  inactiveColor: Colors.white12,
                                  onChanged: (val) {
                                    setModalState(() {});
                                    setState(() => _ambientVolume = val);
                                    _repository.savePlayerPreferences(ambientVolume: val);
                                    NativeChannelService.setLoFiVolume(val);
                                    if (val > 0 && _isPlaying) {
                                      NativeChannelService.playLoFi();
                                    } else if (val == 0) {
                                      NativeChannelService.pauseLoFi();
                                    }
                                  },
                                ),
                              ),
                              SizedBox(
                                width: 46,
                                child: Text(
                                  '${(_ambientVolume * 100).round()}%',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    color: Color(0xFFF5A623),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildVolumePresetChip('Silencio', 0.0, setModalState),
                              _buildVolumePresetChip('Sutil 15%', 0.15, setModalState),
                              _buildVolumePresetChip('Armónico 30%', 0.30, setModalState),
                              _buildVolumePresetChip('Envolvente 55%', 0.55, setModalState),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...kAmbientTracks.map((track) {
                      final isSelected = _selectedAmbientTrackId == track.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            final vol = _ambientVolume > 0 ? _ambientVolume : 0.25;
                            setModalState(() {
                              _selectedAmbientTrackId = track.id;
                              _ambientVolume = vol;
                            });
                            setState(() {
                              _selectedAmbientTrackId = track.id;
                              _ambientVolume = vol;
                            });
                            _repository.savePlayerPreferences(
                              ambientTrackId: track.id,
                              ambientVolume: vol,
                            );
                            NativeChannelService.selectAndPlayTrack(
                              track.id,
                              vol,
                              shouldPlayNow: _isPlaying,
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFFF5A623).withValues(alpha: 0.15)
                                  : Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFFF5A623)
                                    : Colors.white12,
                                width: isSelected ? 1.4 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 21,
                                  backgroundColor: isSelected
                                      ? const Color(0xFFF5A623)
                                      : Colors.white10,
                                  child: Icon(
                                    track.icon,
                                    color: isSelected ? Colors.black : Colors.white70,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        track.title,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                          color: isSelected
                                              ? const Color(0xFFF5A623)
                                              : Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        track.subtitle,
                                        style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isSelected
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: isSelected
                                      ? const Color(0xFFF5A623)
                                      : Colors.white38,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildVolumePresetChip(String label, double val, StateSetter setModalState) {
    final bool active = (_ambientVolume - val).abs() < 0.04;
    return InkWell(
      onTap: () {
        setModalState(() {});
        setState(() => _ambientVolume = val);
        _repository.savePlayerPreferences(ambientVolume: val);
        NativeChannelService.setLoFiVolume(val);
        if (val > 0 && _isPlaying) {
          NativeChannelService.playLoFi();
        } else if (val == 0) {
          NativeChannelService.pauseLoFi();
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFF5A623) : Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            color: active ? Colors.black : Colors.white70,
          ),
        ),
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
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Narradores Neuronales HD (96 kbps)',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 4),
              const Text(
                'Se guarda automáticamente tu voz elegida para todos tus libros',
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: TtsSynthesisService.voicesMap.entries.map((entry) {
                      final isSelected = _selectedVoiceKey == entry.key;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: isSelected
                              ? const Color(0xFFF5A623)
                              : const Color(0xFF2C2D32),
                          child: Icon(
                            Icons.record_voice_over,
                            color: isSelected ? Colors.black : Colors.white,
                          ),
                        ),
                        title: Text(
                          entry.value,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? const Color(0xFFF5A623) : Colors.white,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle_rounded, color: Color(0xFFF5A623))
                            : null,
                        onTap: () {
                          setState(() {
                            _selectedVoiceKey = entry.key;
                            _selectedVoiceName = entry.value;
                          });
                          _repository.savePlayerPreferences(
                            voiceKey: entry.key,
                            voiceName: entry.value,
                          );
                          Navigator.pop(context);
                          _startChapterPlayback(
                            _currentChapter,
                            startSegment: _currentSegmentIndex,
                          );
                        },
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showChaptersModal() {
    final currentChIdx =
        widget.book.chapters.indexWhere((c) => c.id == _currentChapter.id);
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
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.45,
          maxChildSize: 0.92,
          builder: (_, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Capítulos (${widget.book.chapters.length})',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: _downloadService,
                          builder: (ctx, _) {
                            final bookDl = _downloadService.getBookDownloadProgress(widget.book.id);
                            final bool isBookDl = bookDl != null;

                            return FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                backgroundColor: isBookDl
                                    ? const Color(0xFFF5A623).withValues(alpha: 0.28)
                                    : const Color(0xFFF5A623).withValues(alpha: 0.16),
                                foregroundColor: const Color(0xFFF5A623),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                if (isBookDl) {
                                  _downloadService.cancelDownload(widget.book.id, -1);
                                } else {
                                  _downloadService.downloadEntireBook(
                                    book: widget.book,
                                    voiceKey: _selectedVoiceKey,
                                  );
                                }
                              },
                              icon: isBookDl
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFFF5A623),
                                      ),
                                    )
                                  : const Icon(Icons.download_for_offline_rounded, size: 15),
                              label: Text(
                                isBookDl
                                    ? 'Descargando (${bookDl.completed}/${bookDl.total})'
                                    : 'Descargar todo',
                                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5A623).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$bookPercent%',
                            style: const TextStyle(
                              color: Color(0xFFF5A623),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Duración total del libro: ${widget.book.totalTime}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                ...List.generate(widget.book.chapters.length, (idx) {
                  final ch = widget.book.chapters[idx];
                  final isCurrent = _currentChapter.id == ch.id;
                  final isCompleted = currentChIdx != -1 && idx < currentChIdx;
                  final double chProgress = isCurrent
                      ? (_segments.isEmpty
                          ? 0.0
                          : ((_currentSegmentIndex + 1) / _segments.length).clamp(0.0, 1.0))
                      : (isCompleted ? 1.0 : 0.0);

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? const Color(0xFFF5A623).withValues(alpha: 0.12)
                          : Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isCurrent
                            ? const Color(0xFFF5A623).withValues(alpha: 0.5)
                            : Colors.white10,
                      ),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      leading: CircleAvatar(
                        radius: 17,
                        backgroundColor: isCurrent
                            ? const Color(0xFFF5A623)
                            : (isCompleted
                                ? Colors.green.withValues(alpha: 0.22)
                                : const Color(0xFF2A2A2A)),
                        child: isCompleted
                            ? const Icon(Icons.check_rounded, size: 17, color: Colors.greenAccent)
                            : Text(
                                ch.id.toString().padLeft(2, '0'),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: isCurrent ? Colors.black : Colors.white70,
                                ),
                              ),
                      ),
                      title: Text(
                        ch.title,
                        style: TextStyle(
                          color: isCurrent
                              ? const Color(0xFFF5A623)
                              : (isCompleted ? Colors.white70 : Colors.white),
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 3),
                          Text(
                            isCurrent
                                ? 'En curso • Párrafo ${_currentSegmentIndex + 1} de ${_segments.length} (${(chProgress * 100).round()}%)'
                                : (isCompleted
                                    ? 'Completado • ${ch.subtitle}'
                                    : ch.subtitle),
                            style: TextStyle(
                              color: isCurrent ? Colors.white70 : Colors.white54,
                              fontSize: 11.5,
                            ),
                          ),
                          if (isCurrent) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: chProgress,
                                minHeight: 4,
                                backgroundColor: Colors.white12,
                                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFF5A623)),
                              ),
                            ),
                          ],
                        ],
                      ),
                      trailing: AnimatedBuilder(
                        animation: _downloadService,
                        builder: (ctx, _) {
                          final p = _downloadService.getProgress(widget.book.id, ch.id);
                          final isDownloading = p?.status == DownloadStatus.downloading;

                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                ch.durationText,
                                style: TextStyle(
                                  color: isCurrent ? const Color(0xFFF5A623) : Colors.white38,
                                  fontSize: 12,
                                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (isDownloading)
                                SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    value: p?.progressRatio,
                                    strokeWidth: 2.4,
                                    color: const Color(0xFFF5A623),
                                  ),
                                )
                              else
                                FutureBuilder<bool>(
                                  future: _downloadService.isChapterFullyDownloaded(
                                    bookId: widget.book.id,
                                    chapter: ch,
                                    voiceKey: _selectedVoiceKey,
                                  ),
                                  builder: (ctx, snap) {
                                    final isOffline = snap.data == true;
                                    return IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        isOffline
                                            ? Icons.check_circle_rounded
                                            : Icons.download_for_offline_outlined,
                                        size: 20,
                                        color: isOffline ? Colors.greenAccent : Colors.white38,
                                      ),
                                      tooltip: isOffline
                                          ? 'Descargado offline (Tocá para borrar)'
                                          : 'Descargar capítulo',
                                      onPressed: () async {
                                        if (isOffline) {
                                          await _downloadService.deleteChapterDownload(
                                            bookId: widget.book.id,
                                            chapter: ch,
                                            voiceKey: _selectedVoiceKey,
                                          );
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Descarga eliminada: ${ch.title}'),
                                              backgroundColor: Colors.white12,
                                              behavior: SnackBarBehavior.floating,
                                              duration: const Duration(seconds: 1),
                                            ),
                                          );
                                        } else {
                                          _downloadService.downloadChapter(
                                            bookId: widget.book.id,
                                            chapter: ch,
                                            voiceKey: _selectedVoiceKey,
                                          );
                                        }
                                      },
                                    );
                                  },
                                ),
                            ],
                          );
                        },
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _startChapterPlayback(ch, startSegment: 0);
                      },
                    ),
                  );
                }),
              ],
            );
          },
        );
      },
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
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Container(
              height: 38,
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
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.auto_stories_rounded,
                      size: 24, color: Color(0xFFF5A623)),
                  tooltip:
                      'Ver libro original (${widget.book.fileType?.toUpperCase() ?? 'PDF'})',
                  onPressed: _openDocumentViewer,
                ),
                IconButton(
                  icon: const Icon(Icons.queue_music_rounded, size: 26, color: Colors.white),
                  tooltip: 'Capítulos',
                  onPressed: _showChaptersModal,
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
          _lastAutoScrolledSegment = -1;
        });
        if (index == 1) {
          _scrollToCurrentSegment(_currentSegmentIndex);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF5A623) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? Colors.black : Colors.white60,
            ),
            const SizedBox(width: 6),
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
    final activeTrack = kAmbientTracks.firstWhere(
      (t) => t.id == _selectedAmbientTrackId,
      orElse: () => kAmbientTracks.first,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxH = constraints.maxHeight;
        final double maxW = constraints.maxWidth;
        final double coverWidth = min(maxW * 0.72, maxH * 0.48).clamp(155.0, 285.0);
        final double coverHeight = (coverWidth * 1.38).clamp(205.0, 370.0);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: AnimatedScale(
                  scale: _isPlaying ? 1.0 : 0.94,
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutBack,
                  child: BookCoverWidget(
                    book: widget.book,
                    width: coverWidth,
                    height: coverHeight,
                    borderRadius: 18,
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: _showChaptersModal,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _currentChapter.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.4,
                              height: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 26),
                      ],
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _statusMessage.isNotEmpty
                        ? _statusMessage
                        : '${widget.book.title} • ${_currentChapter.subtitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: _statusMessage.isNotEmpty
                          ? const Color(0xFFF5A623)
                          : Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildYouTubeActionChip(
                          icon: Icons.record_voice_over_rounded,
                          label: _selectedVoiceName.split(' ').first,
                          active: true,
                          onTap: _showVoicesModal,
                        ),
                        const SizedBox(width: 8),
                        _buildYouTubeActionChip(
                          icon: activeTrack.icon,
                          label: _ambientVolume > 0
                              ? '${activeTrack.title.split(' ').first} ${(100 * _ambientVolume).round()}%'
                              : 'Clásica Off',
                          active: _ambientVolume > 0,
                          onTap: _showLoFiModal,
                        ),
                        const SizedBox(width: 8),
                        _buildYouTubeActionChip(
                          icon: Icons.menu_book_rounded,
                          label: 'Karaoke',
                          active: false,
                          onTap: () {
                            setState(() {
                              _viewMode = 1;
                              _lastAutoScrolledSegment = -1;
                            });
                            _scrollToCurrentSegment(_currentSegmentIndex);
                          },
                        ),
                      ],
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

  Widget _buildYouTubeActionChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFFF5A623).withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active ? const Color(0xFFF5A623).withValues(alpha: 0.55) : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? const Color(0xFFF5A623) : Colors.white70,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKaraokeTextView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(_segments.length, (idx) {
          final bool isCurrentSeg = idx == _currentSegmentIndex;
          final String segText = _segments[idx];

          if (!isCurrentSeg) {
            return GestureDetector(
              onTap: () => _playSegmentAtIndex(idx, _synthesisGeneration),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                child: Text(
                  segText,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.62,
                    color: idx < _currentSegmentIndex
                        ? Colors.white.withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            );
          }

          final List<String> tokens =
              segText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
          final int activeWordIdx = _getActiveWordIndexForCurrentSegment(tokens);

          return GestureDetector(
            key: _activeSegmentKey,
            onTap: () => _playSegmentAtIndex(idx, _synthesisGeneration),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              decoration: BoxDecoration(
                color: const Color(0xFF231D14).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFF5A623).withValues(alpha: 0.55),
                  width: 1.3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFF5A623).withValues(alpha: 0.10),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_statusMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
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
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontFamily: GoogleFonts.inter().fontFamily,
                        fontSize: 18.5,
                        height: 1.65,
                      ),
                      children: List.generate(tokens.length, (wIdx) {
                        final bool isCurrentWord = wIdx == activeWordIdx;
                        final bool isPastWord = wIdx < activeWordIdx;
                        return TextSpan(
                          text: '${tokens[wIdx]}${wIdx < tokens.length - 1 ? ' ' : ''}',
                          style: TextStyle(
                            color: isCurrentWord
                                ? Colors.black
                                : (isPastWord
                                    ? Colors.white.withValues(alpha: 0.95)
                                    : Colors.white.withValues(alpha: 0.78)),
                            fontWeight: isCurrentWord ? FontWeight.w800 : FontWeight.w500,
                            backgroundColor: isCurrentWord
                                ? const Color(0xFFF5A623)
                                : Colors.transparent,
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildUnifiedBottomControls() {
    // Por defecto (_sliderShowsFullBook == false) la barra controla SOLO el capítulo actual para máxima precisión.
    final Duration baseElapsed =
        _sliderShowsFullBook ? _fullBookElapsedPosition : _chapterElapsedPosition;
    final Duration activeTotal =
        _sliderShowsFullBook ? _fullBookTotalDuration : _chapterTotalDuration;

    final double maxSliderSec = max(1.0, activeTotal.inSeconds.toDouble());
    final double currentSliderSec = _draggingSliderSec != null
        ? _draggingSliderSec!.clamp(0.0, maxSliderSec)
        : baseElapsed.inSeconds.toDouble().clamp(0.0, maxSliderSec);
    final Duration activeElapsed = Duration(seconds: currentSliderSec.round());

    final int remainingSec = max(0, activeTotal.inSeconds - activeElapsed.inSeconds);
    final int remMins = remainingSec ~/ 60;
    final String remainingShort = remMins >= 60
        ? '${remMins ~/ 60}h ${remMins % 60}m'
        : '${max(1, remMins)}m';

    final int bookPercent = ((_fullBookElapsedPosition.inSeconds /
                max(1, _fullBookTotalDuration.inSeconds)) *
            100)
        .clamp(0.0, 100.0)
        .round();

    // Si está arrastrando en modo capítulo, calculamos a qué párrafo va a caer para mostrárselo en vivo
    String? draggingPreviewText;
    if (_draggingSliderSec != null && !_sliderShowsFullBook && _segments.isNotEmpty) {
      final ratio = (currentSliderSec / maxSliderSec).clamp(0.0, 0.999);
      final previewSeg = (ratio * _segments.length).floor() + 1;
      draggingPreviewText =
          'Ir al Párrafo $previewSeg de ${_segments.length} • ${TextSanitizer.formatDuration(activeElapsed)}';
    }

    final String centerBadgeLabel = draggingPreviewText ??
        (_sliderShowsFullBook
            ? 'Libro: $remainingShort rest. ($bookPercent%) ⇄'
            : 'Cap: $remainingShort rest. • Libro $bookPercent% ⇄');

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101114).withValues(alpha: 0.95),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Barra de progreso de descarga si el libro completo o un capítulo se está descargando
            AnimatedBuilder(
              animation: _downloadService,
              builder: (ctx, _) {
                final bookDl = _downloadService.getBookDownloadProgress(widget.book.id);
                if (bookDl == null) return const SizedBox.shrink();

                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.downloading_rounded, size: 14, color: Color(0xFFF5A623)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Descargando audiolibro: capítulo ${bookDl.completed} de ${bookDl.total} (${(bookDl.ratio * 100).round()}%)',
                          style: const TextStyle(
                            color: Color(0xFFF5A623),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          value: bookDl.ratio,
                          strokeWidth: 2,
                          color: const Color(0xFFF5A623),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            GestureDetector(
              onTap: _showChaptersModal,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.format_list_bulleted_rounded,
                        size: 16, color: Color(0xFFF5A623)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${_currentChapter.title}  •  Párr. ${_currentSegmentIndex + 1}/${max(1, _segments.length)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: const Color(0xFFF5A623),
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: currentSliderSec,
                min: 0.0,
                max: maxSliderSec,
                onChangeStart: (val) {
                  setState(() {
                    _draggingSliderSec = val;
                  });
                },
                onChanged: (val) {
                  setState(() {
                    _draggingSliderSec = val;
                  });
                },
                onChangeEnd: (val) {
                  setState(() {
                    _draggingSliderSec = null;
                  });
                  if (_sliderShowsFullBook) {
                    _seekAcrossFullBook(val);
                  } else {
                    _seekWithinCurrentChapter(val);
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    TextSanitizer.formatDuration(activeElapsed),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _draggingSliderSec = null;
                        _sliderShowsFullBook = !_sliderShowsFullBook;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        centerBadgeLabel,
                        style: TextStyle(
                          color: draggingPreviewText != null
                              ? const Color(0xFFF5A623)
                              : Colors.white70,
                          fontSize: 11.5,
                          fontWeight: draggingPreviewText != null
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    TextSanitizer.formatDuration(activeTotal),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded, size: 30, color: Colors.white),
                  tooltip: 'Párrafo anterior',
                  onPressed: () {
                    if (_currentSegmentIndex > 0) {
                      _playSegmentAtIndex(_currentSegmentIndex - 1, _synthesisGeneration);
                    } else {
                      final idx = widget.book.chapters
                          .indexWhere((c) => c.id == _currentChapter.id);
                      if (idx > 0) {
                        _startChapterPlayback(widget.book.chapters[idx - 1]);
                      }
                    }
                  },
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
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5A623),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFF5A623).withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: _isSynthesizing
                        ? const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 3,
                              ),
                            ),
                          )
                        : Icon(
                            _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            size: 40,
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
                InkWell(
                  onTap: _showSpeedModal,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${_playbackSpeed.toStringAsFixed(_playbackSpeed % 0.1 == 0 ? 1 : 2)}x',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14.5,
                            color: Color(0xFFF5A623),
                          ),
                        ),
                        const Icon(
                          Icons.arrow_drop_up_rounded,
                          size: 16,
                          color: Color(0xFFF5A623),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                InkWell(
                  onTap: _showLoFiModal,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _ambientVolume > 0
                          ? const Color(0xFFF5A623).withValues(alpha: 0.16)
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.piano_rounded,
                          color: _ambientVolume > 0 ? const Color(0xFFF5A623) : Colors.white54,
                          size: 17,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _ambientVolume > 0
                              ? '${(_ambientVolume * 100).round()}%'
                              : 'Off',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            color: _ambientVolume > 0 ? const Color(0xFFF5A623) : Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: _showVoicesModal,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFF5A623).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircleAvatar(
                          radius: 11,
                          backgroundColor: Color(0xFFF5A623),
                          child: Icon(Icons.record_voice_over, size: 13, color: Colors.black),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _selectedVoiceName.split(' • ').first,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, color: Colors.white70, size: 26),
                  tooltip: 'Siguiente párrafo',
                  onPressed: () {
                    if (_currentSegmentIndex + 1 < _segments.length) {
                      _playSegmentAtIndex(_currentSegmentIndex + 1, _synthesisGeneration);
                    } else {
                      final currentIndex =
                          widget.book.chapters.indexWhere((c) => c.id == _currentChapter.id);
                      if (currentIndex != -1 &&
                          currentIndex + 1 < widget.book.chapters.length) {
                        _startChapterPlayback(widget.book.chapters[currentIndex + 1]);
                      }
                    }
                  },
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
    return Scaffold(
      backgroundColor: const Color(0xFF0D0E11),
      body: Stack(
        children: [
          // La animación de fondo queda aislada en su propio RepaintBoundary y NO reconstruye el texto ni los controles
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _ambientAnimController,
                builder: (context, _) {
                  final double t = _ambientAnimController.value;
                  final Color c1 = _ambientColors.first;
                  final Color c2 = _ambientColors.last;

                  final List<Color> bgGradient = _viewMode == 0
                      ? [c1, c2, const Color(0xFF0D0E11)]
                      : const [
                          Color(0xFF141311),
                          Color(0xFF0E0E0F),
                          Color(0xFF09090A),
                        ];

                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment(-0.8 + t * 1.2, -1.0),
                              end: Alignment(0.8 - t * 1.2, 1.0),
                              colors: bgGradient,
                              stops: const [0.0, 0.52, 1.0],
                            ),
                          ),
                        ),
                      ),
                      if (_viewMode == 0)
                        Positioned(
                          top: 60 + (t * 45),
                          left: 30 + ((1 - t) * 50),
                          right: 30 + (t * 50),
                          child: IgnorePointer(
                            child: Container(
                              height: 280,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: c1.withValues(alpha: 0.55),
                                    blurRadius: 110,
                                    spreadRadius: 35,
                                  ),
                                ],
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
          Column(
            children: [
              _buildTopBar(),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  child: _viewMode == 0
                      ? _buildCoverModeView()
                      : _buildKaraokeTextView(),
                ),
              ),
              _buildUnifiedBottomControls(),
            ],
          ),
        ],
      ),
    );
  }
}
