import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../../../core/utils/text_sanitizer.dart';
import '../../../../data/repositories/library_repository.dart';
import '../../../../data/services/book_translation_service.dart';
import '../../../../data/services/native_channel_service.dart';
import '../../../../data/services/tts_synthesis_service.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';
import '../../../shared/widgets/book_cover_widget.dart';

/// Palabra individual con coordenadas normalizadas (0.0 a 1.0) respecto al ancho/alto de la hoja PDF
class PdfNormalizedWord {
  final String text;
  final String cleanToken;
  final Rect normBounds;

  const PdfNormalizedWord({
    required this.text,
    required this.cleanToken,
    required this.normBounds,
  });
}

/// Línea de texto del PDF con sus coordenadas normalizadas (0.0 a 1.0) y sus palabras
class PdfNormalizedLine {
  final String text;
  final String cleanText;
  final Rect normBounds;
  final List<PdfNormalizedWord> words;

  const PdfNormalizedLine({
    required this.text,
    required this.cleanText,
    required this.normBounds,
    required this.words,
  });
}

/// Geometría extraída de una página del PDF para subrayado en vivo y toque directo
class PdfPageOverlayData {
  final double pageWidth;
  final double pageHeight;
  final String fullCleanPageText;
  final List<PdfNormalizedLine> lines;

  const PdfPageOverlayData({
    required this.pageWidth,
    required this.pageHeight,
    required this.fullCleanPageText,
    required this.lines,
  });

  double get aspectRatio => pageHeight > 0 ? (pageWidth / pageHeight) : 0.707;
}

/// Coincidencia de búsqueda de palabras/frases dentro del PDF o Libro
class PdfSearchMatch {
  final int pageIndex;
  final int chapterIndex;
  final int segmentIndex;
  final String snippet;
  final List<String> queryTokens;

  const PdfSearchMatch({
    required this.pageIndex,
    required this.chapterIndex,
    required this.segmentIndex,
    required this.snippet,
    required this.queryTokens,
  });
}

class DocumentViewerScreen extends StatefulWidget {
  final BookItem book;
  final AudioPlayer player;
  final int initialChapterIndex;
  final int? activeSegmentIndex;
  final int? totalSegmentsInChapter;
  final String? currentSpokenSnippet;
  final VoidCallback? onBookFileLinked;
  final Function(int chapterIndex, int segmentIndex)? onSeekToPosition;

  const DocumentViewerScreen({
    super.key,
    required this.book,
    required this.player,
    this.initialChapterIndex = 0,
    this.activeSegmentIndex,
    this.totalSegmentsInChapter,
    this.currentSpokenSnippet,
    this.onBookFileLinked,
    this.onSeekToPosition,
  });

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  final TtsSynthesisService _ttsService = TtsSynthesisService();

  late int _viewerMode; // 0 = PDF Original con subrayado en vivo, 1 = Modo Texto
  late int _activeChapterIndex;
  double _fontSize = 18.0;

  // Filtro visual de hoja PDF: 0 = Original (Blanco), 1 = Sepia Cálido, 2 = Modo Noche Oscuro
  int _pdfColorTheme = 0;
  bool _showPageSliderBar = false;
  bool _immersiveFullscreen = false;
  // Dirección de deslizamiento de páginas en PDF: true = Horizontal, false = Vertical
  bool _isVerticalScroll = false;
  // Modo de navegación: true = Sigue al audio automáticamente; false = Modo Libre (ojear sin mover el audio)
  bool _autoFollowAudio = true;

  // --- NUEVO: Modo Cuadrícula Libre (4 o 6 páginas visibles estilo Adobe Organizer) ---
  bool _isGridMode = false;
  int _gridPagesPerView = 6; // 4 (2x2 grande) o 6 (3x2 / 2x3 compacto)
  final ScrollController _gridScrollController = ScrollController();
  final Map<int, Uint8List> _pdfThumbCache = {};
  final List<int> _thumbLruOrder = [];
  static const int _maxCachedThumbs = 36;
  final Set<int> _thumbsBeingLoaded = {};

  // --- NUEVO: Buscador de Palabras en el PDF/Libro con resaltado geométrico ---
  bool _isSearchOpen = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  List<PdfSearchMatch> _searchMatches = [];
  int _activeSearchMatchIndex = 0;
  Timer? _searchDebounceTimer;

  // --- NUEVO: Zoom Inteligente (Doble Toque + Pellizco + Botones 1 mano sin bloquear el swipe) ---
  final TransformationController _zoomController = TransformationController();
  double _currentZoomScale = 1.0;
  Offset _lastDoubleTapLocalPos = Offset.zero;

  PageController? _pdfPageController;
  PdfDocument? _pdfDoc;
  PdfTextExtractor? _pdfTextExtractor;
  int _currentPdfPage = 0;
  int _totalPdfPages = 0;
  int _audioSyncedPdfPage = 0;
  bool _isProgrammaticPageTurn = false;

  final Map<int, Uint8List> _pdfPageCache = {};
  final List<int> _cacheLruOrder = [];
  static const int _maxCachedPages = 12;
  final Set<int> _pagesBeingLoaded = {};
  final Map<int, PdfPageOverlayData> _pdfOverlayCache = {};
  bool _hasLocalPdf = false;
  bool _isLoadingPdfPage = false;
  bool _isSynthesizingText = false;

  // Estado en tiempo real del audio para subrayar línea y palabra exacta sobre el PDF
  late int _liveAudioChapterIndex;
  late int _liveAudioSegmentIndex;
  Duration _livePosition = Duration.zero;
  Duration _liveDuration = const Duration(seconds: 8);
  String _selectedVoiceKey = 'es-MX-JorgeNeural';

  final ScrollController _textScrollController = ScrollController();
  final GlobalKey _activeTextSegmentKey = GlobalKey();

  StreamSubscription<PlayerState>? _playerSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<SequenceState?>? _sequenceSub;
  Timer? _liveSyncTimer;
  Timer? _pageTurnDebounceTimer;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _zoomController.addListener(_onZoomTransformChanged);
    _activeChapterIndex = widget.initialChapterIndex.clamp(
      0,
      max<int>(0, widget.book.chapters.length - 1),
    );
    _liveAudioChapterIndex = widget.book.lastChapterIndex.clamp(
      0,
      max<int>(0, widget.book.chapters.length - 1),
    );
    _liveAudioSegmentIndex =
        widget.activeSegmentIndex ?? widget.book.lastSegmentIndex;

    _hasLocalPdf = widget.book.originalFilePath != null &&
        widget.book.originalFilePath!.toLowerCase().endsWith('.pdf') &&
        File(widget.book.originalFilePath!).existsSync();

    _viewerMode = (widget.book.fileType == 'epub') ? 1 : 0;

    _loadVoicePreference();
    _setupLiveAudioListeners();

    if (_hasLocalPdf) {
      _initPdfRenderer();
    } else if (widget.book.fileType != 'epub') {
      _tryAutoLocatePdfOnDevice();
    }
  }

  Future<void> _loadVoicePreference() async {
    final prefs = await LibraryRepository().loadPlayerPreferences();
    if (mounted) {
      final isBookEnglish = widget.book.activeAudioLanguage == 'en';
      final fallbackVoiceKey = isBookEnglish ? 'en-US-GuyNeural' : 'es-MX-JorgeNeural';
      final savedVoiceKey = (prefs['voiceKey'] as String?) ?? fallbackVoiceKey;
      final effectiveVoiceKey = (isBookEnglish && !savedVoiceKey.startsWith('en-'))
          ? 'en-US-GuyNeural'
          : (!isBookEnglish && savedVoiceKey.startsWith('en-'))
              ? 'es-MX-JorgeNeural'
              : savedVoiceKey;
      setState(() {
        _selectedVoiceKey = effectiveVoiceKey;
      });
    }
  }

  Future<void> _toggleViewerAudioLanguage() async {
    final newLang = widget.book.activeAudioLanguage == 'es' ? 'en' : 'es';
    widget.book.activeAudioLanguage = newLang;

    if (newLang == 'es') {
      final chIdx = _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1);
      final ch = widget.book.chapters[chIdx];
      final isTextEnglish = BookTranslationService.detectLanguage(ch.textContent) == 'en';
      if (isTextEnglish && (ch.originalLanguageSegments == null || ch.originalLanguageSegments!.isEmpty)) {
        try {
          final translated = await BookTranslationService.translateSingleChapter(ch);
          widget.book.chapters[chIdx] = translated;
        } catch (_) {}
      }
    }

    final newVoiceKey = newLang == 'en' ? 'en-US-GuyNeural' : 'es-MX-JorgeNeural';
    final newVoiceName = TtsSynthesisService.voicesMap[newVoiceKey] ??
        (newLang == 'en' ? 'Guy HD (EE. UU. 🇺🇸 • Cálido y narrativo)' : 'Jorge HD (México 🇲🇽 • Cálido)');

    setState(() {
      _selectedVoiceKey = newVoiceKey;
    });

    await LibraryRepository().savePlayerPreferences(
      voiceKey: newVoiceKey,
      voiceName: newVoiceName,
    );

    widget.onSeekToPosition?.call(_liveAudioChapterIndex, _liveAudioSegmentIndex);

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

  void _setupLiveAudioListeners() {
    _isPlaying = widget.player.playing;
    _livePosition = widget.player.position;
    if (widget.player.duration != null) {
      _liveDuration = widget.player.duration!;
    }

    _playerSub = widget.player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
          if (state.playing) {
            _isSynthesizingText = false;
          }
        });
      }
    });

    _positionSub = widget.player.positionStream.listen((pos) {
      if (!mounted) return;
      if ((pos.inMilliseconds - _livePosition.inMilliseconds).abs() >= 90 ||
          pos == Duration.zero) {
        setState(() => _livePosition = pos);
      }
    });

    _durationSub = widget.player.durationStream.listen((dur) {
      if (mounted && dur != null && dur != _liveDuration) {
        setState(() => _liveDuration = dur);
      }
    });

    _sequenceSub = widget.player.sequenceStateStream.listen((_) {
      _syncWithLiveBookProgress();
    });

    _liveSyncTimer = Timer.periodic(const Duration(milliseconds: 450), (_) {
      _syncWithLiveBookProgress();
    });
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _pageTurnDebounceTimer?.cancel();
    _liveSyncTimer?.cancel();
    _playerSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _sequenceSub?.cancel();
    _zoomController.removeListener(_onZoomTransformChanged);
    _zoomController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _gridScrollController.dispose();
    _pdfPageController?.dispose();
    _textScrollController.dispose();
    _pdfDoc?.dispose();
    super.dispose();
  }

  void _onZoomTransformChanged() {
    final scale = _zoomController.value.getMaxScaleOnAxis();
    if ((scale - _currentZoomScale).abs() >= 0.03) {
      if (mounted) {
        setState(() {
          _currentZoomScale = scale;
        });
      }
    }
  }

  void _resetZoom() {
    _zoomController.value = Matrix4.identity();
    if (_currentZoomScale != 1.0 && mounted) {
      setState(() => _currentZoomScale = 1.0);
    }
  }

  void _applyStepZoom(double delta, Size viewportSize) {
    final targetScale = (_currentZoomScale + delta).clamp(1.0, 4.0);
    if ((targetScale - 1.0).abs() < 0.05) {
      _resetZoom();
      return;
    }
    final cx = viewportSize.width / 2.0;
    final cy = viewportSize.height / 2.0;
    final Matrix4 m = Matrix4.identity()
      ..translateByDouble(cx * (1.0 - targetScale), cy * (1.0 - targetScale), 0.0, 1.0)
      ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
    _zoomController.value = m;
    setState(() => _currentZoomScale = targetScale);
  }

  void _handleDoubleTapZoom(Size viewportSize) {
    if (_currentZoomScale > 1.15) {
      _resetZoom();
      return;
    }
    const double targetScale = 2.25;
    final tapX = _lastDoubleTapLocalPos.dx.clamp(0.0, viewportSize.width);
    final tapY = _lastDoubleTapLocalPos.dy.clamp(0.0, viewportSize.height);
    final Matrix4 m = Matrix4.identity()
      ..translateByDouble(tapX * (1.0 - targetScale), tapY * (1.0 - targetScale), 0.0, 1.0)
      ..scaleByDouble(targetScale, targetScale, 1.0, 1.0);
    _zoomController.value = m;
    setState(() => _currentZoomScale = targetScale);
  }

  static String _normalizeToken(String input) {
    return input
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll(RegExp(r'[^a-zñ0-9]'), '');
  }

  /// Sincroniza en vivo cuando el narrador avanza al siguiente párrafo o capítulo
  void _syncWithLiveBookProgress() {
    if (!mounted) return;
    final newChIdx = widget.book.lastChapterIndex.clamp(
      0,
      max<int>(0, widget.book.chapters.length - 1),
    );
    final newSegIdx = widget.book.lastSegmentIndex;

    if (newChIdx != _liveAudioChapterIndex || newSegIdx != _liveAudioSegmentIndex) {
      final prevSyncedPage = _audioSyncedPdfPage;
      final bool wasFollowingOnSyncedPage = (_currentPdfPage == prevSyncedPage);

      _liveAudioChapterIndex = newChIdx;
      _liveAudioSegmentIndex = newSegIdx;

      if (_totalPdfPages > 0) {
        final nextPage = _findBestPdfPageForActiveSegment(_totalPdfPages);
        setState(() {
          _audioSyncedPdfPage = nextPage;
        });

        // Si el usuario tiene activado el seguimiento del audio y el narrador cambia de hoja, pasamos la página sola.
        if (_viewerMode == 0 &&
            _autoFollowAudio &&
            wasFollowingOnSyncedPage &&
            nextPage != _currentPdfPage &&
            _pdfPageController != null &&
            _pdfPageController!.hasClients) {
          _isProgrammaticPageTurn = true;
          _pdfPageController!
              .animateToPage(
                nextPage,
                duration: const Duration(milliseconds: 360),
                curve: Curves.easeOutCubic,
              )
              .whenComplete(() {
            _isProgrammaticPageTurn = false;
          });
        }
      } else {
        setState(() {});
      }

      if (_viewerMode == 1) {
        if (_activeChapterIndex != newChIdx) {
          setState(() => _activeChapterIndex = newChIdx);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _activeTextSegmentKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: 0.3,
            );
          }
        });
      }
    }
  }

  /// Extrae el rango de páginas reales [startPageZeroBased, endPageZeroBased] leyendo tanto title como subtitle
  List<int>? _parseChapterPageRange(ChapterItem ch) {
    final combined = '${ch.title} ${ch.subtitle}';
    final m = RegExp(r'Págs?\.\s*(\d+)(?:\s*-\s*(\d+))?', caseSensitive: false)
        .firstMatch(combined);
    if (m == null) return null;
    final start = (int.tryParse(m.group(1) ?? '') ?? 1) - 1;
    final end = (int.tryParse(m.group(2) ?? m.group(1) ?? '') ?? (start + 1)) - 1;
    return [max(0, start), max(0, end)];
  }

  /// Calcula la página del PDF donde aparece el párrafo activo (verifica también el texto real extraído del PDF para precisión 100%)
  int _findBestPdfPageForActiveSegment(int totalPages) {
    if (totalPages <= 0) return 0;
    final chIdx = _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];
    final segs = (ch.originalLanguageSegments != null && ch.originalLanguageSegments!.isNotEmpty)
        ? ch.originalLanguageSegments!
        : ch.segments;
    final totalSegs = max(1, segs.length);
    final segIdx = _liveAudioSegmentIndex.clamp(0, totalSegs - 1);

    int estimatedPage = 0;
    final range = _parseChapterPageRange(ch);
    if (range != null) {
      final startP = range[0].clamp(0, totalPages - 1);
      final endP = range[1].clamp(startP, totalPages - 1);
      final pageSpan = max(1, endP - startP + 1);
      final pageOffset = ((segIdx / totalSegs) * pageSpan).floor().clamp(0, pageSpan - 1);
      estimatedPage = (startP + pageOffset).clamp(0, totalPages - 1);
    } else {
      final segRatio = (segIdx / totalSegs).clamp(0.0, 0.999);
      final bookRatio = (chIdx + segRatio) / max(1, widget.book.chapters.length);
      estimatedPage = (bookRatio * totalPages).floor().clamp(0, totalPages - 1);
    }

    // Si tenemos el documento PDF cargado, verificamos en [estimatedPage, estimatedPage-1, estimatedPage+1]
    // en cuál de esas hojas aparece realmente la frase actual para que el subrayado coincida siempre al 100%
    if (_pdfDoc != null && segs.isNotEmpty) {
      final snippetWords = segs[segIdx]
          .split(RegExp(r'\s+'))
          .map(_normalizeToken)
          .where((w) => w.length >= 4)
          .take(8)
          .toList();

      if (snippetWords.length >= 2) {
        final candidates = <int>{
          estimatedPage,
          if (estimatedPage + 1 < totalPages) estimatedPage + 1,
          if (estimatedPage - 1 >= 0) estimatedPage - 1,
          if (estimatedPage + 2 < totalPages) estimatedPage + 2,
          if (estimatedPage - 2 >= 0) estimatedPage - 2,
        };
        if (range != null) {
          final rStart = range[0].clamp(0, totalPages - 1);
          final rEnd = range[1].clamp(rStart, totalPages - 1);
          for (int p = rStart; p <= rEnd; p++) {
            candidates.add(p);
          }
        }

        int bestPage = estimatedPage;
        int bestHits = -1;
        for (final cand in candidates) {
          if (cand < 0 || cand >= totalPages) continue;
          final overlay = _ensurePageOverlayExtracted(cand);
          if (overlay == null || overlay.fullCleanPageText.isEmpty) continue;
          int hits = 0;
          for (final w in snippetWords) {
            if (overlay.fullCleanPageText.contains(w)) hits++;
          }
          if (hits > bestHits) {
            bestHits = hits;
            bestPage = cand;
          }
          if (hits == snippetWords.length) {
            return cand;
          }
        }
        if (bestHits >= 2) {
          return bestPage;
        }
      }
    }

    return estimatedPage;
  }

  /// Extrae y cachea las líneas y palabras con sus coordenadas exactas (Rect) SOLO cuando la página está en pantalla
  PdfPageOverlayData? _ensurePageOverlayExtracted(int pageIndex) {
    if (_pdfOverlayCache.containsKey(pageIndex)) {
      return _pdfOverlayCache[pageIndex];
    }
    // Si estamos en Modo Libre y es una página lejana tanto al audio como a la página visible/búsqueda, no bloquear el hilo
    if (!_autoFollowAudio &&
        pageIndex != _audioSyncedPdfPage &&
        pageIndex != _currentPdfPage &&
        _searchQuery.isEmpty) {
      return null;
    }
    if (_pdfDoc == null || _pdfTextExtractor == null) return null;
    if (pageIndex < 0 || pageIndex >= _pdfDoc!.pages.count) return null;

    try {
      final page = _pdfDoc!.pages[pageIndex];
      final double pageW = max(1.0, page.size.width);
      final double pageH = max(1.0, page.size.height);

      final rawLines = _pdfTextExtractor!.extractTextLines(
        startPageIndex: pageIndex,
        endPageIndex: pageIndex,
      );

      final List<PdfNormalizedLine> normLines = [];
      final StringBuffer pageCleanBuf = StringBuffer();

      for (final line in rawLines) {
        final lineStr = line.text.trim();
        if (lineStr.isEmpty) continue;

        final List<PdfNormalizedWord> normWords = [];
        final List<String> cleanWordTokens = [];

        for (final w in line.wordCollection) {
          final wText = w.text.trim();
          if (wText.isEmpty) continue;
          final cleanW = _normalizeToken(wText);
          if (cleanW.isNotEmpty) {
            cleanWordTokens.add(cleanW);
          }
          final wb = w.bounds;
          normWords.add(
            PdfNormalizedWord(
              text: wText,
              cleanToken: cleanW,
              normBounds: Rect.fromLTWH(
                (wb.left / pageW).clamp(0.0, 1.0),
                (wb.top / pageH).clamp(0.0, 1.0),
                (wb.width / pageW).clamp(0.005, 1.0),
                (wb.height / pageH).clamp(0.005, 1.0),
              ),
            ),
          );
        }

        final lb = line.bounds;
        final cleanLineStr = cleanWordTokens.join(' ');
        if (cleanLineStr.isNotEmpty) {
          pageCleanBuf.write('$cleanLineStr ');
        }

        normLines.add(
          PdfNormalizedLine(
            text: lineStr,
            cleanText: cleanLineStr,
            normBounds: Rect.fromLTWH(
              (lb.left / pageW).clamp(0.0, 1.0),
              (lb.top / pageH).clamp(0.0, 1.0),
              (lb.width / pageW).clamp(0.01, 1.0),
              (lb.height / pageH).clamp(0.008, 1.0),
            ),
            words: normWords,
          ),
        );
      }

      final overlay = PdfPageOverlayData(
        pageWidth: pageW,
        pageHeight: pageH,
        fullCleanPageText: pageCleanBuf.toString(),
        lines: normLines,
      );
      _pdfOverlayCache[pageIndex] = overlay;
      return overlay;
    } catch (_) {
      return null;
    }
  }

  /// Encuentra qué líneas y qué palabra individual de la página PDF corresponden al párrafo y milisegundo actual del narrador
  ({ List<Rect> activeLineRects, Rect? activeWordRect }) _computeActiveHighlightRectsForPage(
    int pageIndex,
  ) {
    if (pageIndex != _audioSyncedPdfPage) {
      return (activeLineRects: const [], activeWordRect: null);
    }
    final overlay = _ensurePageOverlayExtracted(pageIndex);
    if (overlay == null || overlay.lines.isEmpty) {
      return (activeLineRects: const [], activeWordRect: null);
    }

    final chIdx = _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];
    final segs = (ch.originalLanguageSegments != null && ch.originalLanguageSegments!.isNotEmpty)
        ? ch.originalLanguageSegments!
        : ch.segments;
    if (segs.isEmpty) {
      return (activeLineRects: const [], activeWordRect: null);
    }
    final segIdx = _liveAudioSegmentIndex.clamp(0, segs.length - 1);
    final activeParagraph = segs[segIdx];

    final segWords = activeParagraph
        .split(RegExp(r'\s+'))
        .map(_normalizeToken)
        .where((w) => w.isNotEmpty)
        .toList();
    if (segWords.isEmpty) {
      return (activeLineRects: const [], activeWordRect: null);
    }

    final segWordSet = segWords.where((w) => w.length >= 3).toSet();
    final String segJoined = segWords.join(' ');

    // Buscamos el mejor grupo continuo de líneas que contenga el párrafo actual
    int bestStart = -1;
    int bestEnd = -1;
    int maxContigHits = 0;

    for (int i = 0; i < overlay.lines.length; i++) {
      int curHits = 0;
      final Set<String> matchedWordsInBlock = {};
      for (int j = i; j < min(overlay.lines.length, i + 9); j++) {
        final line = overlay.lines[j];
        for (final w in line.words) {
          if (w.cleanToken.length >= 3 && segWordSet.contains(w.cleanToken)) {
            matchedWordsInBlock.add(w.cleanToken);
          }
        }
        curHits = matchedWordsInBlock.length;
        if (curHits > maxContigHits) {
          maxContigHits = curHits;
          bestStart = i;
          bestEnd = j;
        }
      }
    }

    // Encontrar la línea del PDF que coincide con las primeras 4 palabras del párrafo de audio
    final firstSegTokens = segWords.take(5).toList();
    int startLineIdx = -1;
    for (int i = 0; i < overlay.lines.length; i++) {
      final lineTokens = overlay.lines[i].words.map((w) => w.cleanToken).where((t) => t.length >= 3).toList();
      int startHits = 0;
      for (final t in firstSegTokens) {
        if (lineTokens.contains(t)) startHits++;
      }
      if (startHits >= 2 || (firstSegTokens.isNotEmpty && lineTokens.isNotEmpty && firstSegTokens.first == lineTokens.first)) {
        startLineIdx = i;
        break;
      }
    }

    final List<int> matchedLineIndices = [];
    if (startLineIdx != -1) {
      // Tomamos consecutivamente desde la línea exacta de inicio tantas líneas como abarque el párrafo
      int wordsAccumulated = 0;
      for (int k = startLineIdx; k < overlay.lines.length; k++) {
        matchedLineIndices.add(k);
        wordsAccumulated += overlay.lines[k].words.length;
        if (wordsAccumulated >= segWords.length) break;
      }
    } else if (bestStart != -1 && maxContigHits >= 4) {
      for (int k = bestStart; k <= bestEnd; k++) {
        matchedLineIndices.add(k);
      }
    } else {
      // Coincidencia exacta de substring
      for (int i = 0; i < overlay.lines.length; i++) {
        final line = overlay.lines[i];
        if (line.cleanText.isEmpty) continue;
        if (segJoined.contains(line.cleanText) || line.cleanText.contains(segJoined)) {
          matchedLineIndices.add(i);
        }
      }
    }

    // Fallback proporcional dentro de la página si el PDF tiene codificación especial de fuentes
    if (matchedLineIndices.isEmpty && overlay.lines.isNotEmpty) {
      final info = _resolveChapterAndSegmentsForPdfPage(pageIndex);
      final spanSegs = max(1, info.endSeg - info.startSeg + 1);
      final localSegOffset = (segIdx - info.startSeg).clamp(0, spanSegs - 1);
      final startLine = ((localSegOffset / spanSegs) * overlay.lines.length)
          .floor()
          .clamp(0, overlay.lines.length - 1);
      final endLine = (((localSegOffset + 1) / spanSegs) * overlay.lines.length)
          .ceil()
          .clamp(startLine + 1, overlay.lines.length);
      for (int i = startLine; i < endLine; i++) {
        matchedLineIndices.add(i);
      }
    }

    final List<Rect> lineRects = [];
    final List<PdfNormalizedWord> paragraphPdfWords = [];

    for (final idx in matchedLineIndices) {
      final l = overlay.lines[idx];
      lineRects.add(l.normBounds);
      paragraphPdfWords.addAll(l.words.where((w) => w.cleanToken.isNotEmpty));
    }

    // Determinar la palabra individual activa dentro del párrafo
    Rect? activeWordRect;
    if (paragraphPdfWords.isNotEmpty) {
      final posMs = _livePosition.inMilliseconds;
      final timings = _ttsService.getWordTimings(
        widget.book.id,
        ch,
        segIdx,
        _selectedVoiceKey,
      );

      if (timings != null && timings.isNotEmpty) {
        int eventIdx = 0;
        for (int i = 0; i < timings.length; i++) {
          if (posMs >= timings[i].startMs) {
            eventIdx = i;
          } else {
            break;
          }
        }
        final spokenClean = _normalizeToken(timings[eventIdx].word);

        // Alineación 1: Buscar si la palabra exacta pronunciada por TTS aparece en las palabras de esta hoja
        int bestIdx = -1;
        if (spokenClean.isNotEmpty) {
          final expectedIdx = ((eventIdx / max(1, timings.length - 1)) * (paragraphPdfWords.length - 1))
              .round()
              .clamp(0, paragraphPdfWords.length - 1);
          final minSearch = max(0, expectedIdx - 5);
          final maxSearch = min(paragraphPdfWords.length - 1, expectedIdx + 5);

          for (int k = minSearch; k <= maxSearch; k++) {
            if (paragraphPdfWords[k].cleanToken == spokenClean) {
              bestIdx = k;
              break;
            }
          }
        }

        // Alineación 2: Si no hubo match exacto de token, alinear proporcionalmente por índice del evento TTS
        if (bestIdx == -1) {
          final ratio = (eventIdx / max(1, timings.length - 1)).clamp(0.0, 1.0);
          bestIdx = (ratio * (paragraphPdfWords.length - 1)).round().clamp(0, paragraphPdfWords.length - 1);
        }

        activeWordRect = paragraphPdfWords[bestIdx].normBounds;
      } else {
        final totalMs = max(1200, _liveDuration.inMilliseconds);
        final progress = (posMs / totalMs).clamp(0.0, 0.999);
        final wordIdx = (progress * paragraphPdfWords.length)
            .floor()
            .clamp(0, paragraphPdfWords.length - 1);
        activeWordRect = paragraphPdfWords[wordIdx].normBounds;
      }
    }

    return (activeLineRects: lineRects, activeWordRect: activeWordRect);
  }

  /// Devuelve el capítulo y el rango de párrafos [startSeg, endSeg] que pertenecen a una página del PDF (0-based)
  ({ int chapterIndex, ChapterItem chapter, int startSeg, int endSeg }) _resolveChapterAndSegmentsForPdfPage(
    int targetPage,
  ) {
    // 1. Buscar primero por rango explícito de páginas ("Págs. 41-50")
    for (int i = 0; i < widget.book.chapters.length; i++) {
      final ch = widget.book.chapters[i];
      final range = _parseChapterPageRange(ch);
      if (range != null && targetPage >= range[0] && targetPage <= range[1]) {
        final segs = (ch.originalLanguageSegments != null && ch.originalLanguageSegments!.isNotEmpty)
            ? ch.originalLanguageSegments!
            : ch.segments;
        if (segs.isEmpty) {
          return (chapterIndex: i, chapter: ch, startSeg: 0, endSeg: 0);
        }

        // Si tenemos el texto extraído de esta página del PDF, buscamos exactamente cuál es el primer párrafo de este capítulo que aparece en la hoja
        final overlay = _ensurePageOverlayExtracted(targetPage);
        if (overlay != null && overlay.lines.isNotEmpty) {
          int? firstMatchedSeg;
          int? lastMatchedSeg;
          for (int s = 0; s < segs.length; s++) {
            final words = segs[s]
                .split(RegExp(r'\s+'))
                .map(_normalizeToken)
                .where((w) => w.length >= 4)
                .take(6)
                .toList();
            if (words.length >= 2) {
              int hits = 0;
              for (final w in words) {
                if (overlay.fullCleanPageText.contains(w)) hits++;
              }
              if (hits >= (words.length * 0.6).ceil()) {
                firstMatchedSeg ??= s;
                lastMatchedSeg = s;
              }
            }
          }
          if (firstMatchedSeg != null) {
            return (
              chapterIndex: i,
              chapter: ch,
              startSeg: firstMatchedSeg,
              endSeg: lastMatchedSeg ?? firstMatchedSeg,
            );
          }
        }

        final pageSpan = max(1, range[1] - range[0] + 1);
        final pageIdxInChapter = targetPage - range[0];
        final startRatio = (pageIdxInChapter / pageSpan).clamp(0.0, 0.999);
        final endRatio = ((pageIdxInChapter + 1) / pageSpan).clamp(0.0, 1.0);

        final startSeg = (startRatio * segs.length)
            .floor()
            .clamp(0, max<int>(0, segs.length - 1));
        final endSeg = max(
          startSeg,
          (endRatio * segs.length).ceil() - 1,
        ).clamp(0, max<int>(0, segs.length - 1));

        return (chapterIndex: i, chapter: ch, startSeg: startSeg, endSeg: endSeg);
      }
    }

    // 2. Fallback proporcional si no hay etiqueta de páginas
    final ratio = targetPage / max(1, _totalPdfPages);
    final chIdx = (ratio * widget.book.chapters.length)
        .floor()
        .clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];
    final segs = ch.segments;
    return (
      chapterIndex: chIdx,
      chapter: ch,
      startSeg: 0,
      endSeg: max<int>(0, segs.length - 1),
    );
  }

  /// Si el usuario toca directamente una línea o párrafo sobre la hoja del PDF
  void _onTapPdfPagePosition(
    TapUpDetails details,
    Size renderedBoxSize,
    int pageIndex,
  ) {
    // Si estamos en Modo Libre, un toque en la hoja alterna la barra completa (Modo Pantalla Completa Limpio)
    if (!_autoFollowAudio) {
      setState(() => _immersiveFullscreen = !_immersiveFullscreen);
      return;
    }

    final overlay = _ensurePageOverlayExtracted(pageIndex);
    if (overlay == null || overlay.lines.isEmpty) {
      setState(() => _immersiveFullscreen = !_immersiveFullscreen);
      return;
    }

    // Calcular el rectángulo real donde BoxFit.contain dibujó la página dentro de renderedBoxSize
    final double pageAspect = overlay.aspectRatio;
    final double boxAspect = renderedBoxSize.width / max(1.0, renderedBoxSize.height);

    double drawnW;
    double drawnH;
    double offsetX = 0;
    double offsetY = 0;

    if (boxAspect > pageAspect) {
      drawnH = renderedBoxSize.height;
      drawnW = drawnH * pageAspect;
      offsetX = (renderedBoxSize.width - drawnW) / 2.0;
    } else {
      drawnW = renderedBoxSize.width;
      drawnH = drawnW / pageAspect;
      offsetY = (renderedBoxSize.height - drawnH) / 2.0;
    }

    final localPos = details.localPosition;
    final normX = (localPos.dx - offsetX) / max(1.0, drawnW);
    final normY = (localPos.dy - offsetY) / max(1.0, drawnH);

    if (normX < 0.0 || normX > 1.0 || normY < 0.0 || normY > 1.0) return;

    // Buscar la línea del PDF más cercana verticalmente al toque del usuario
    PdfNormalizedLine? tappedLine;
    double bestDist = 0.045; // tolerancia vertical de ~4.5% de la altura de la hoja
    for (final line in overlay.lines) {
      if (normY >= line.normBounds.top - 0.012 &&
          normY <= line.normBounds.bottom + 0.012) {
        tappedLine = line;
        break;
      }
      final centerDist = (normY - line.normBounds.center.dy).abs();
      if (centerDist < bestDist) {
        bestDist = centerDist;
        tappedLine = line;
      }
    }

    if (tappedLine == null || tappedLine.cleanText.isEmpty) return;

    // Encontrar a qué párrafo del capítulo pertenece la línea tocada
    final info = _resolveChapterAndSegmentsForPdfPage(pageIndex);
    final segs = info.chapter.segments;
    if (segs.isEmpty) return;

    // 1. Recolectar las líneas del bloque alrededor del toque
    int tappedLineIdx = overlay.lines.indexOf(tappedLine);
    final blockLines = <PdfNormalizedLine>[];
    for (int k = max(0, tappedLineIdx - 2); k <= min(overlay.lines.length - 1, tappedLineIdx + 4); k++) {
      blockLines.add(overlay.lines[k]);
    }
    final tappedBlockTokens = blockLines
        .expand((l) => l.words)
        .map((w) => w.cleanToken)
        .where((t) => t.length >= 3)
        .toList();

    int bestChIdx = info.chapterIndex;
    int bestSegIdx = info.startSeg;
    int bestScore = -1;

    // Buscamos primero en el capítulo de esta página y en los capítulos vecinos
    final candidateChIndices = <int>{
      info.chapterIndex,
      if (info.chapterIndex > 0) info.chapterIndex - 1,
      if (info.chapterIndex + 1 < widget.book.chapters.length) info.chapterIndex + 1,
    };

    for (final cIdx in candidateChIndices) {
      final ch = widget.book.chapters[cIdx];
      // Si el PDF original está en inglés y el libro fue traducido, comparar contra los fragmentos originales en inglés
      final segs = (ch.originalLanguageSegments != null && ch.originalLanguageSegments!.isNotEmpty)
          ? ch.originalLanguageSegments!
          : ch.segments;
      for (int s = 0; s < segs.length; s++) {
        final segWords = segs[s]
            .split(RegExp(r'\s+'))
            .map(_normalizeToken)
            .where((w) => w.length >= 3)
            .toList();
        if (segWords.isEmpty) continue;

        final segJoined = segWords.join(' ');

        // Coincidencia exacta de frase
        if (segJoined.contains(tappedLine.cleanText) || tappedLine.cleanText.contains(segJoined)) {
          bestChIdx = cIdx;
          bestSegIdx = s;
          bestScore = 9999;
          break;
        }

        // Búsqueda por solapamiento de tokens ponderado
        int hits = 0;
        final segTokenSet = segWords.toSet();
        for (final tok in tappedBlockTokens) {
          if (segTokenSet.contains(tok)) hits += 3;
        }
        for (final tok in tappedLine.words.map((w) => w.cleanToken).where((t) => t.length >= 3)) {
          if (segTokenSet.contains(tok)) hits += 5;
        }

        // Si el párrafo empieza con palabras clave similares al inicio de la línea tocada
        if (tappedLine.words.isNotEmpty && segWords.isNotEmpty) {
          if (tappedLine.words.first.cleanToken == segWords.first) {
            hits += 15;
          }
        }

        if (cIdx == info.chapterIndex && s >= info.startSeg && s <= info.endSeg) {
          hits += 2;
        }

        if (hits > bestScore) {
          bestScore = hits;
          bestChIdx = cIdx;
          bestSegIdx = s;
        }
      }
      if (bestScore >= 9999) break;
    }

    // Actualizar inmediatamente estado local para sincronizar el resaltado y mostrar el spinner de preparación
    setState(() {
      _activeChapterIndex = bestChIdx;
      _liveAudioChapterIndex = bestChIdx;
      _liveAudioSegmentIndex = bestSegIdx;
      _audioSyncedPdfPage = pageIndex;
      _livePosition = Duration.zero;
      _isSynthesizingText = true;
    });

    // Pausar cualquier audio viejo mientras el nuevo segmento se sintetiza/carga
    widget.player.pause();
    NativeChannelService.pauseLoFi();

    widget.onSeekToPosition?.call(bestChIdx, bestSegIdx);
  }

  Future<void> _tryAutoLocatePdfOnDevice() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${docDir.path}/books');
      if (await booksDir.exists()) {
        final files = booksDir.listSync().whereType<File>().toList();
        for (final f in files) {
          if (f.path.toLowerCase().endsWith('.pdf') && f.path.contains(widget.book.id)) {
            widget.book.originalFilePath = f.path;
            widget.book.fileType = 'pdf';
            _hasLocalPdf = true;
            await _initPdfRenderer();
            return;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _pickAndLinkOriginalPdf() async {
    try {
      const typeGroup = XTypeGroup(
        label: 'Archivo PDF Original',
        extensions: ['pdf'],
        mimeTypes: ['application/pdf'],
      );
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;

      setState(() => _isLoadingPdfPage = true);
      final bytes = await file.readAsBytes();
      final repo = LibraryRepository();
      final savedPath = await repo.savePermanentBookCopy(widget.book.id, file.name, bytes);

      widget.book.originalFilePath = savedPath;
      widget.book.fileType = 'pdf';
      widget.onBookFileLinked?.call();

      setState(() {
        _hasLocalPdf = true;
        _viewerMode = 0;
      });
      await _initPdfRenderer();
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingPdfPage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo vincular el PDF: $e')),
        );
      }
    }
  }

  Future<void> _initPdfRenderer() async {
    final path = widget.book.originalFilePath!;
    setState(() => _isLoadingPdfPage = true);

    try {
      final pdfBytes = await File(path).readAsBytes();
      _pdfDoc?.dispose();
      _pdfDoc = PdfDocument(inputBytes: pdfBytes);
      _pdfTextExtractor = PdfTextExtractor(_pdfDoc!);
    } catch (_) {}

    final res = await NativeChannelService.renderPdfPage(path, 0, width: 1300);
    if (res != null && mounted) {
      final total = (res['pageCount'] as int?) ?? (_pdfDoc?.pages.count ?? 1);
      final firstBytes = res['bytes'] as Uint8List?;
      if (firstBytes != null) _pdfPageCache[0] = firstBytes;

      final targetAudioPage = _findBestPdfPageForActiveSegment(total);
      _ensurePageOverlayExtracted(targetAudioPage);

      _pdfPageController?.dispose();
      _pdfPageController = PageController(initialPage: targetAudioPage);

      setState(() {
        _totalPdfPages = total;
        _audioSyncedPdfPage = targetAudioPage;
        _currentPdfPage = targetAudioPage;
        _isLoadingPdfPage = false;
      });

      await _loadPdfPage(targetAudioPage);
      _preloadPdfPages([targetAudioPage - 1, targetAudioPage + 1, targetAudioPage + 2]);
    } else if (mounted) {
      setState(() {
        _isLoadingPdfPage = false;
      });
    }
  }

  void _recordPageCacheHit(int pageIndex, Uint8List bytes) {
    _pdfPageCache[pageIndex] = bytes;
    _cacheLruOrder.remove(pageIndex);
    _cacheLruOrder.add(pageIndex);

    // Si supera el límite de memoria permitido en RAM, desalojamos las páginas más antiguas
    while (_cacheLruOrder.length > _maxCachedPages) {
      final oldestPage = _cacheLruOrder.removeAt(0);
      // Nunca desalojar la página actualmente visible ni la página sincronizada con el audio
      if (oldestPage != _currentPdfPage && oldestPage != _audioSyncedPdfPage) {
        _pdfPageCache.remove(oldestPage);
        _pdfOverlayCache.remove(oldestPage);
      } else {
        _cacheLruOrder.add(oldestPage);
        break;
      }
    }
  }

  Future<void> _loadPdfPage(int pageIndex) async {
    if (pageIndex < 0 || (_totalPdfPages > 0 && pageIndex >= _totalPdfPages)) return;
    if (_autoFollowAudio || pageIndex == _audioSyncedPdfPage) {
      _ensurePageOverlayExtracted(pageIndex);
    }
    if (_pdfPageCache.containsKey(pageIndex)) {
      _cacheLruOrder.remove(pageIndex);
      _cacheLruOrder.add(pageIndex);
      return;
    }
    if (_pagesBeingLoaded.contains(pageIndex)) return;
    _pagesBeingLoaded.add(pageIndex);

    final path = widget.book.originalFilePath;
    if (path == null) {
      _pagesBeingLoaded.remove(pageIndex);
      return;
    }
    try {
      final res = await NativeChannelService.renderPdfPage(path, pageIndex, width: 1300);
      if (res != null && mounted && res['bytes'] is Uint8List) {
        setState(() {
          _recordPageCacheHit(pageIndex, res['bytes'] as Uint8List);
        });
      }
    } catch (_) {
    } finally {
      _pagesBeingLoaded.remove(pageIndex);
    }
  }

  void _jumpToAudioPosition() {
    setState(() => _autoFollowAudio = true);
    final targetPage = _findBestPdfPageForActiveSegment(_totalPdfPages);
    if (_viewerMode == 0 && _totalPdfPages > 0) {
      _isProgrammaticPageTurn = true;
      _pdfPageController
          ?.animateToPage(
            targetPage,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() => _isProgrammaticPageTurn = false);
    }
    if (!_isPlaying) {
      widget.player.play();
      NativeChannelService.playLoFi();
    }
  }

  void _preloadPdfPages(List<int> pages) {
    for (final p in pages) {
      if (p >= 0 && p < _totalPdfPages && !_pdfPageCache.containsKey(p)) {
        _loadPdfPage(p);
      }
    }
  }

  // --- CACHÉ DE MINIATURAS ULTRALIVIANAS (340px, ~18KB) PARA CUADRÍCULA DE 4 / 6 PÁGINAS ---
  void _recordThumbCacheHit(int pageIndex, Uint8List bytes) {
    _pdfThumbCache[pageIndex] = bytes;
    _thumbLruOrder.remove(pageIndex);
    _thumbLruOrder.add(pageIndex);
    while (_thumbLruOrder.length > _maxCachedThumbs) {
      final oldest = _thumbLruOrder.removeAt(0);
      if (oldest != _currentPdfPage && oldest != _audioSyncedPdfPage) {
        _pdfThumbCache.remove(oldest);
      } else {
        _thumbLruOrder.add(oldest);
        break;
      }
    }
  }

  Future<void> _loadPdfThumbnail(int pageIndex) async {
    if (pageIndex < 0 || (_totalPdfPages > 0 && pageIndex >= _totalPdfPages)) return;
    if (_pdfThumbCache.containsKey(pageIndex)) {
      _thumbLruOrder.remove(pageIndex);
      _thumbLruOrder.add(pageIndex);
      return;
    }
    if (_pdfPageCache.containsKey(pageIndex)) {
      _recordThumbCacheHit(pageIndex, _pdfPageCache[pageIndex]!);
      return;
    }
    if (_thumbsBeingLoaded.contains(pageIndex)) return;
    _thumbsBeingLoaded.add(pageIndex);

    final path = widget.book.originalFilePath;
    if (path == null) {
      _thumbsBeingLoaded.remove(pageIndex);
      return;
    }
    try {
      final res = await NativeChannelService.renderPdfPage(path, pageIndex, width: 340);
      if (res != null && mounted && res['bytes'] is Uint8List) {
        setState(() {
          _recordThumbCacheHit(pageIndex, res['bytes'] as Uint8List);
        });
      }
    } catch (_) {
    } finally {
      _thumbsBeingLoaded.remove(pageIndex);
    }
  }

  void _toggleGridMode() {
    if (_viewerMode != 0 || _totalPdfPages <= 0) return;
    final nextGrid = !_isGridMode;
    setState(() {
      _isGridMode = nextGrid;
      if (nextGrid) {
        _resetZoom();
      }
    });
    if (nextGrid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrentGridPage(_currentPdfPage);
      });
    }
  }

  void _scrollToCurrentGridPage(int pageIdx) {
    if (!_gridScrollController.hasClients || _totalPdfPages <= 0) return;
    final cols = _gridPagesPerView == 6 ? 3 : 2;
    final rowIdx = pageIdx ~/ cols;
    final totalRows = max(1, (_totalPdfPages / cols).ceil());
    final maxScroll = _gridScrollController.position.maxScrollExtent;
    final targetOffset = ((rowIdx / max(1, totalRows - 1)) * maxScroll).clamp(0.0, maxScroll);
    _gridScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _narrateFromPdfPage(int pageIdx) {
    final info = _resolveChapterAndSegmentsForPdfPage(pageIdx);
    setState(() {
      _isGridMode = false;
      _autoFollowAudio = true;
      _currentPdfPage = pageIdx;
      _audioSyncedPdfPage = pageIdx;
      _activeChapterIndex = info.chapterIndex;
      _liveAudioChapterIndex = info.chapterIndex;
      _liveAudioSegmentIndex = info.startSeg;
      _livePosition = Duration.zero;
      _isSynthesizingText = true;
    });
    _resetZoom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pdfPageController?.jumpToPage(pageIdx);
    });
    widget.player.pause();
    NativeChannelService.pauseLoFi();
    widget.onSeekToPosition?.call(info.chapterIndex, info.startSeg);
  }

  // --- BUSCADOR DE PALABRAS Y FRASES EN EL LIBRO/PDF CON RESALTADO EXACTO ---
  void _onSearchQueryChanged(String raw) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 220), () {
      _performDocumentSearch(raw);
    });
  }

  void _performDocumentSearch(String rawQuery) {
    final trimmed = rawQuery.trim();
    if (trimmed.length < 2) {
      if (mounted) {
        setState(() {
          _searchQuery = '';
          _searchMatches = [];
          _activeSearchMatchIndex = 0;
        });
      }
      return;
    }

    final queryTokens = trimmed
        .split(RegExp(r'\s+'))
        .map(_normalizeToken)
        .where((t) => t.isNotEmpty)
        .toList();
    if (queryTokens.isEmpty) return;

    final String cleanQueryJoined = queryTokens.join(' ');
    final List<PdfSearchMatch> matches = [];
    final int totalPages = max(1, _totalPdfPages);

    for (int cIdx = 0; cIdx < widget.book.chapters.length; cIdx++) {
      final ch = widget.book.chapters[cIdx];
      final segs = (ch.originalLanguageSegments != null && ch.originalLanguageSegments!.isNotEmpty && widget.book.activeAudioLanguage == 'en')
          ? ch.originalLanguageSegments!
          : ch.segments;
      final range = _parseChapterPageRange(ch);

      for (int sIdx = 0; sIdx < segs.length; sIdx++) {
        final rawSeg = segs[sIdx];
        final cleanSeg = rawSeg
            .split(RegExp(r'\s+'))
            .map(_normalizeToken)
            .where((t) => t.isNotEmpty)
            .join(' ');
        if (!cleanSeg.contains(cleanQueryJoined)) continue;

        // Estimar la página correspondiente a este segmento
        int estPage = 0;
        if (range != null && _totalPdfPages > 0) {
          final startP = range[0].clamp(0, totalPages - 1);
          final endP = range[1].clamp(startP, totalPages - 1);
          final span = max(1, endP - startP + 1);
          final offset = ((sIdx / max(1, segs.length)) * span).floor().clamp(0, span - 1);
          estPage = (startP + offset).clamp(0, totalPages - 1);
        } else if (_totalPdfPages > 0) {
          final ratio = (cIdx + (sIdx / max(1, segs.length))) / max(1, widget.book.chapters.length);
          estPage = (ratio * totalPages).floor().clamp(0, totalPages - 1);
        }

        // Crear un extracto legible alrededor de la coincidencia
        final lowerRaw = rawSeg.toLowerCase();
        final firstTok = trimmed.split(RegExp(r'\s+')).first.toLowerCase();
        final pos = lowerRaw.indexOf(firstTok);
        String snippet = rawSeg;
        if (pos != -1 && rawSeg.length > 95) {
          final start = max(0, pos - 32);
          final end = min(rawSeg.length, pos + 65);
          snippet = '${start > 0 ? '...' : ''}${rawSeg.substring(start, end).trim()}${end < rawSeg.length ? '...' : ''}';
        } else if (rawSeg.length > 95) {
          snippet = '${rawSeg.substring(0, 92).trim()}...';
        }

        matches.add(
          PdfSearchMatch(
            pageIndex: estPage,
            chapterIndex: cIdx,
            segmentIndex: sIdx,
            snippet: snippet,
            queryTokens: queryTokens,
          ),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _searchQuery = cleanQueryJoined;
      _searchMatches = matches;
      _activeSearchMatchIndex = 0;
    });

    if (matches.isNotEmpty) {
      _jumpToSearchMatch(0, closeKeyboard: false);
    }
  }

  void _jumpToSearchMatch(int matchIdx, {bool closeKeyboard = true}) {
    if (_searchMatches.isEmpty) return;
    final safeIdx = (matchIdx % _searchMatches.length + _searchMatches.length) % _searchMatches.length;
    final match = _searchMatches[safeIdx];
    if (closeKeyboard) {
      _searchFocusNode.unfocus();
    }

    // Si tenemos el PDF cargado, verificamos en [match.pageIndex - 1, match.pageIndex, match.pageIndex + 1] dónde está exactamente la palabra
    int resolvedPage = match.pageIndex;
    if (_pdfDoc != null && _totalPdfPages > 0 && match.queryTokens.isNotEmpty) {
      final candidates = <int>[
        match.pageIndex,
        if (match.pageIndex + 1 < _totalPdfPages) match.pageIndex + 1,
        if (match.pageIndex - 1 >= 0) match.pageIndex - 1,
      ];
      for (final cand in candidates) {
        final ov = _ensurePageOverlayExtracted(cand);
        if (ov != null && ov.fullCleanPageText.contains(match.queryTokens.first)) {
          resolvedPage = cand;
          break;
        }
      }
    }

    setState(() {
      _activeSearchMatchIndex = safeIdx;
      _activeChapterIndex = match.chapterIndex;
      if (_viewerMode == 0 && _totalPdfPages > 0) {
        _isGridMode = false;
        _currentPdfPage = resolvedPage;
      }
    });

    if (_viewerMode == 0 && _totalPdfPages > 0) {
      _resetZoom();
      _pdfPageController?.jumpToPage(resolvedPage);
    }
  }

  /// Devuelve los rectángulos normalizados de todas las palabras en `pageIndex` que coinciden con `_searchQuery`
  List<Rect> _computeSearchHighlightRectsForPage(int pageIndex) {
    if (_searchQuery.isEmpty) return const [];
    final overlay = _ensurePageOverlayExtracted(pageIndex);
    if (overlay == null || overlay.lines.isEmpty) return const [];

    final queryTokens = _searchQuery.split(' ').where((t) => t.isNotEmpty).toList();
    if (queryTokens.isEmpty) return const [];

    final List<Rect> rects = [];
    for (final line in overlay.lines) {
      if (queryTokens.length == 1) {
        final q = queryTokens.first;
        for (final w in line.words) {
          if (w.cleanToken.isNotEmpty && w.cleanToken.contains(q)) {
            rects.add(w.normBounds);
          }
        }
      } else {
        // Coincidencia de frase multi-palabra dentro de la línea
        for (int i = 0; i <= line.words.length - queryTokens.length; i++) {
          bool allMatch = true;
          for (int k = 0; k < queryTokens.length; k++) {
            if (!line.words[i + k].cleanToken.contains(queryTokens[k])) {
              allMatch = false;
              break;
            }
          }
          if (allMatch) {
            for (int k = 0; k < queryTokens.length; k++) {
              rects.add(line.words[i + k].normBounds);
            }
          }
        }
      }
    }
    return rects;
  }

  Widget _applyPdfThemeFilter(Widget child) {
    if (_pdfColorTheme == 1) {
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.95, 0.0, 0.0, 0, 0,
          0.0, 0.90, 0.0, 0, 0,
          0.0, 0.0, 0.78, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: child,
      );
    } else if (_pdfColorTheme == 2) {
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          -0.88, 0, 0, 0, 240,
          0, -0.88, 0, 0, 238,
          0, 0, -0.86, 0, 232,
          0, 0, 0, 1, 0,
        ]),
        child: child,
      );
    }
    return child;
  }

  Duration get _activeChapterElapsed {
    final ch = widget.book.chapters[
        _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1)];
    final segs = ch.segments;
    if (segs.isEmpty) return Duration.zero;
    final totalSec = max(15, ch.estimatedTotalSeconds);
    final secPerSeg = totalSec / segs.length;
    final baseSec = (_liveAudioSegmentIndex * secPerSeg).round();
    return Duration(seconds: (baseSec + _livePosition.inSeconds).clamp(0, totalSec));
  }

  Duration get _activeChapterTotal {
    final ch = widget.book.chapters[
        _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1)];
    return Duration(seconds: max(15, ch.estimatedTotalSeconds));
  }

  void _skipParagraph(int delta) {
    final chIdx = _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];
    final segs = ch.segments;
    final nextSeg = _liveAudioSegmentIndex + delta;

    if (nextSeg >= 0 && nextSeg < segs.length) {
      setState(() {
        _liveAudioSegmentIndex = nextSeg;
        _livePosition = Duration.zero;
      });
      widget.onSeekToPosition?.call(chIdx, nextSeg);
    } else if (delta > 0 && chIdx + 1 < widget.book.chapters.length) {
      setState(() {
        _liveAudioChapterIndex = chIdx + 1;
        _liveAudioSegmentIndex = 0;
        _livePosition = Duration.zero;
      });
      widget.onSeekToPosition?.call(chIdx + 1, 0);
    } else if (delta < 0 && chIdx > 0) {
      final prevCh = widget.book.chapters[chIdx - 1];
      final lastSeg = max<int>(0, prevCh.segments.length - 1);
      setState(() {
        _liveAudioChapterIndex = chIdx - 1;
        _liveAudioSegmentIndex = lastSeg;
        _livePosition = Duration.zero;
      });
      widget.onSeekToPosition?.call(chIdx - 1, lastSeg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentCh = widget.book.chapters[_activeChapterIndex];

    return Scaffold(
      backgroundColor: const Color(0xFF141518),
      appBar: _immersiveFullscreen
          ? null
          : AppBar(
              backgroundColor: const Color(0xFF1A1B1F),
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.close_rounded, size: 22, color: Colors.white70),
                tooltip: 'Volver al reproductor',
                onPressed: () => Navigator.pop(context),
              ),
              title: GestureDetector(
                onTap: _viewerMode == 0 ? _showJumpToPageDialog : _showChapterSelector,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _viewerMode == 0 && _totalPdfPages > 0
                          ? (_isGridMode
                              ? 'Cuadrícula ($_gridPagesPerView págs) • $_totalPdfPages hojas'
                              : 'Pág. ${_currentPdfPage + 1} de $_totalPdfPages • Tocá para ir a pág.')
                          : currentCh.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFF5A623),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                if (widget.book.chapters.any((c) => c.originalLanguageSegments != null && c.originalLanguageSegments!.isNotEmpty))
                  GestureDetector(
                    onTap: _toggleViewerAudioLanguage,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 3),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2D32),
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
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          color: widget.book.activeAudioLanguage == 'es'
                              ? const Color(0xFFF5A623)
                              : const Color(0xFF64B5F6),
                        ),
                      ),
                    ),
                  ),
                // Botón Buscador de Palabras en el PDF/Libro
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _isSearchOpen ? Icons.search_off_rounded : Icons.search_rounded,
                    color: _isSearchOpen || _searchQuery.isNotEmpty
                        ? const Color(0xFF00E5FF)
                        : Colors.white70,
                    size: 22,
                  ),
                  tooltip: 'Buscar palabra o frase',
                  onPressed: () {
                    setState(() {
                      _isSearchOpen = !_isSearchOpen;
                      if (_isSearchOpen) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _searchFocusNode.requestFocus();
                        });
                      } else {
                        _searchFocusNode.unfocus();
                      }
                    });
                  },
                ),
                // Botón Vista Cuadrícula (4 / 6 páginas visibles)
                if (_viewerMode == 0 && _totalPdfPages > 0)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _isGridMode ? Icons.insert_drive_file_outlined : Icons.grid_view_rounded,
                      color: _isGridMode ? const Color(0xFFF5A623) : Colors.white70,
                      size: 21,
                    ),
                    tooltip: _isGridMode ? 'Ver 1 página' : 'Cuadrícula de 4 / 6 páginas',
                    onPressed: _toggleGridMode,
                  ),
                if (_viewerMode == 0 && _totalPdfPages > 0 && !_isGridMode)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      if (!_autoFollowAudio) {
                        _jumpToAudioPosition();
                        if (!_isPlaying) {
                          widget.player.play();
                          NativeChannelService.playLoFi();
                        }
                      } else {
                        if (_isPlaying) {
                          widget.player.pause();
                          NativeChannelService.pauseLoFi();
                        }
                        setState(() => _autoFollowAudio = false);
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _autoFollowAudio
                            ? const Color(0xFFF5A623).withValues(alpha: 0.18)
                            : Colors.white10,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _autoFollowAudio ? const Color(0xFFF5A623) : Colors.white24,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _autoFollowAudio
                                ? Icons.sync_rounded
                                : Icons.pan_tool_rounded,
                            size: 13,
                            color: _autoFollowAudio ? const Color(0xFFF5A623) : Colors.white70,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _autoFollowAudio ? 'Sync' : 'Libre',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: _autoFollowAudio ? const Color(0xFFF5A623) : Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
      body: Column(
        children: [
          if (_isSearchOpen && !_immersiveFullscreen) _buildSearchToolbar(),
          Expanded(
            child: _viewerMode == 0
                ? _buildPdfOriginalWithLiveHighlight()
                : _buildTextReader(currentCh),
          ),
          if (!_immersiveFullscreen) _buildAmorFatiStyleBottomControls(),
        ],
      ),
    );
  }

  Widget _buildSearchToolbar() {
    final hasMatches = _searchMatches.isNotEmpty;
    final currentMatch = hasMatches
        ? _searchMatches[_activeSearchMatchIndex.clamp(0, _searchMatches.length - 1)]
        : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF1F2128),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121317),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: hasMatches ? const Color(0xFF00E5FF) : Colors.white24,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search_rounded, size: 18, color: Color(0xFF00E5FF)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: const TextStyle(color: Colors.white, fontSize: 13.5),
                          decoration: const InputDecoration(
                            hintText: 'Buscar palabra o frase en el libro...',
                            hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: _onSearchQueryChanged,
                          onSubmitted: (val) {
                            _performDocumentSearch(val);
                            _searchFocusNode.unfocus();
                          },
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            _performDocumentSearch('');
                          },
                          child: const Icon(Icons.clear_rounded, size: 17, color: Colors.white54),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              if (hasMatches) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_activeSearchMatchIndex + 1}/${_searchMatches.length}',
                    style: const TextStyle(
                      color: Color(0xFF00E5FF),
                      fontWeight: FontWeight.w800,
                      fontSize: 11.5,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded, color: Colors.white, size: 22),
                  tooltip: 'Resultado anterior',
                  onPressed: () => _jumpToSearchMatch(_activeSearchMatchIndex - 1),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 22),
                  tooltip: 'Siguiente resultado',
                  onPressed: () => _jumpToSearchMatch(_activeSearchMatchIndex + 1),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.list_alt_rounded, color: Color(0xFF00E5FF), size: 20),
                  tooltip: 'Ver lista de coincidencias',
                  onPressed: _showSearchResultsBottomSheet,
                ),
              ] else if (_searchQuery.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '0 resultados',
                    style: TextStyle(color: Colors.redAccent, fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          if (currentMatch != null)
            Padding(
              padding: const EdgeInsets.only(top: 5, left: 4, right: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5A623).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Pág. ${currentMatch.pageIndex + 1}',
                      style: const TextStyle(
                        color: Color(0xFFF5A623),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      currentMatch.snippet,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isGridMode = false;
                        _liveAudioChapterIndex = currentMatch.chapterIndex;
                        _liveAudioSegmentIndex = currentMatch.segmentIndex;
                        _audioSyncedPdfPage = currentMatch.pageIndex;
                      });
                      widget.onSeekToPosition?.call(
                        currentMatch.chapterIndex,
                        currentMatch.segmentIndex,
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Text(
                        '🔊 Narrar acá',
                        style: TextStyle(
                          color: Color(0xFFF5A623),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _showSearchResultsBottomSheet() {
    if (_searchMatches.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181A20),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.62,
          minChildSize: 0.38,
          maxChildSize: 0.88,
          builder: (_, scrollCtrl) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Resultados para "${_searchController.text.trim()}"',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF).withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${_searchMatches.length} hallazgos',
                          style: const TextStyle(
                            color: Color(0xFF00E5FF),
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: ListView.separated(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _searchMatches.length,
                    separatorBuilder: (_, _) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (_, idx) {
                      final m = _searchMatches[idx];
                      final isSelected = idx == _activeSearchMatchIndex;
                      final chTitle = widget.book.chapters[m.chapterIndex].title;
                      return ListTile(
                        selected: isSelected,
                        selectedTileColor: const Color(0xFF00E5FF).withValues(alpha: 0.08),
                        leading: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF00E5FF)
                                : const Color(0xFF262932),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Pág. ${m.pageIndex + 1}',
                            style: TextStyle(
                              color: isSelected ? Colors.black : const Color(0xFFF5A623),
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        title: Text(
                          m.snippet,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '$chTitle • Párrafo ${m.segmentIndex + 1}',
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.volume_up_rounded, color: Color(0xFFF5A623), size: 20),
                          tooltip: 'Narrar desde aquí',
                          onPressed: () {
                            Navigator.pop(ctx);
                            _jumpToSearchMatch(idx);
                            widget.onSeekToPosition?.call(m.chapterIndex, m.segmentIndex);
                          },
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _jumpToSearchMatch(idx);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildPdfOriginalWithLiveHighlight() {
    if (_isLoadingPdfPage) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFF5A623)),
            SizedBox(height: 12),
            Text(
              'Preparando páginas y subrayado inteligente del PDF...',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (!_hasLocalPdf || _totalPdfPages == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1D24),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFF5A623).withValues(alpha: 0.45)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.picture_as_pdf_rounded,
                  size: 56,
                  color: Color(0xFFF5A623),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Ver PDF Original con Subrayado en Vivo',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Seleccioná el archivo PDF una sola vez para ver sus páginas originales con subrayado sincronizado palabra por palabra.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF5A623),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _pickAndLinkOriginalPdf,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text(
                    'Vincular archivo PDF original',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_isGridMode) {
      return _buildPdfGridOrganizerView();
    }

    return LayoutBuilder(
      builder: (context, outerConstraints) {
        final viewportSize = Size(outerConstraints.maxWidth, outerConstraints.maxHeight);
        final bool isZoomedIn = _currentZoomScale > 1.04;

        return Stack(
          children: [
            PageView.builder(
              controller: _pdfPageController,
              // Cuando hay Zoom aplicado (> 1.04x), bloqueamos el cambio accidental de página para poder arrastrar libremente con 1 dedo
              physics: isZoomedIn
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(),
              scrollDirection: _isVerticalScroll ? Axis.vertical : Axis.horizontal,
              itemCount: _totalPdfPages,
              onPageChanged: (pageIdx) {
                _resetZoom();
                setState(() {
                  _currentPdfPage = pageIdx;
                });
                if (!_isProgrammaticPageTurn) {
                  _preloadPdfPages([pageIdx - 1, pageIdx + 1, pageIdx + 2]);
                }
              },
              itemBuilder: (context, pageIdx) {
                final bytes = _pdfPageCache[pageIdx];
                if (bytes == null) {
                  _loadPdfPage(pageIdx);
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFF5A623)),
                  );
                }

                final overlay = _ensurePageOverlayExtracted(pageIdx);
                final highlights = _computeActiveHighlightRectsForPage(pageIdx);
                final searchRects = _computeSearchHighlightRectsForPage(pageIdx);
                final bool isDarkTheme = _pdfColorTheme == 2;

                return InteractiveViewer(
                  transformationController: pageIdx == _currentPdfPage ? _zoomController : null,
                  minScale: 1.0,
                  maxScale: 4.5,
                  panEnabled: true,
                  scaleEnabled: true,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final boxSize = Size(constraints.maxWidth, constraints.maxHeight);
                      final double pageAspect = overlay?.aspectRatio ?? 0.707;
                      final double boxAspect = boxSize.width / max(1.0, boxSize.height);

                      double drawnW;
                      double drawnH;
                      if (boxAspect > pageAspect) {
                        drawnH = boxSize.height;
                        drawnW = drawnH * pageAspect;
                      } else {
                        drawnW = boxSize.width;
                        drawnH = drawnW / pageAspect;
                      }

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTapDown: (details) {
                          _lastDoubleTapLocalPos = details.localPosition;
                        },
                        onDoubleTap: () => _handleDoubleTapZoom(boxSize),
                        onTapUp: (details) => _onTapPdfPagePosition(details, boxSize, pageIdx),
                        child: Center(
                          child: SizedBox(
                            width: drawnW,
                            height: drawnH,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // 1. Hoja original del PDF
                                _applyPdfThemeFilter(
                                  Image.memory(
                                    bytes,
                                    fit: BoxFit.fill,
                                    gaplessPlayback: true,
                                  ),
                                ),
                                // 2. Capa de subrayado sincronizado en vivo (#F5A623) + Resaltado de Búsqueda (#00E5FF)
                                if (highlights.activeLineRects.isNotEmpty ||
                                    highlights.activeWordRect != null ||
                                    searchRects.isNotEmpty)
                                  IgnorePointer(
                                    child: CustomPaint(
                                      painter: _PdfLiveHighlightPainter(
                                        lineNormRects: highlights.activeLineRects,
                                        wordNormRect: highlights.activeWordRect,
                                        searchNormRects: searchRects,
                                        isDarkPageTheme: isDarkTheme,
                                      ),
                                    ),
                                  ),
                                // Indicador de carga cuando el usuario toca un texto para narrar
                                if (_isSynthesizingText && pageIdx == _audioSyncedPdfPage)
                                  IgnorePointer(
                                    child: Container(
                                      color: Colors.black38,
                                      child: const Center(
                                        child: Card(
                                          color: Color(0xFF1E2026),
                                          elevation: 8,
                                          child: Padding(
                                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2.2,
                                                    color: Color(0xFFF5A623),
                                                  ),
                                                ),
                                                SizedBox(width: 12),
                                                Text(
                                                  'Preparando narración...',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            // Controles flotantes de Zoom con 1 mano (- | 100% | +) en la esquina inferior izquierda
            if (!_immersiveFullscreen)
              Positioned(
                left: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1B20).withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: isZoomedIn ? const Color(0xFFF5A623) : Colors.white12,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _applyStepZoom(-0.5, viewportSize),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.zoom_out_rounded, size: 18, color: Colors.white70),
                        ),
                      ),
                      GestureDetector(
                        onTap: _resetZoom,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Text(
                            '${(_currentZoomScale * 100).round()}%',
                            style: TextStyle(
                              color: isZoomedIn ? const Color(0xFFF5A623) : Colors.white70,
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _applyStepZoom(0.6, viewportSize),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.zoom_in_rounded, size: 18, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Botón flotante para regresar al audio cuando estás ojeando en Modo Libre en otra página
            if (!_immersiveFullscreen && !_autoFollowAudio && _currentPdfPage != _audioSyncedPdfPage)
              Positioned(
                right: 16,
                bottom: 12,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF5A623),
                    foregroundColor: Colors.black,
                    elevation: 6,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                  ),
                  onPressed: _jumpToAudioPosition,
                  icon: const Icon(Icons.my_location_rounded, size: 16),
                  label: Text(
                    'Volver a Pág. ${_audioSyncedPdfPage + 1}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
                  ),
                ),
              ),
            if (_immersiveFullscreen)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 14,
                child: FloatingActionButton.small(
                  backgroundColor: Colors.black87,
                  foregroundColor: const Color(0xFFF5A623),
                  onPressed: () => setState(() => _immersiveFullscreen = false),
                  child: const Icon(Icons.fullscreen_exit_rounded),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Vista Cuadrícula Libre de 4 o 6 páginas (estilo Adobe Organize Pages) con miniaturas ultralivianas de 340px
  Widget _buildPdfGridOrganizerView() {
    final int crossAxisCount = _gridPagesPerView == 6 ? 3 : 2;
    final double childAspectRatio = _gridPagesPerView == 6 ? 0.58 : 0.62;
    final Set<int> searchMatchedPages = _searchMatches.map((m) => m.pageIndex).toSet();

    return Container(
      color: const Color(0xFF141518),
      child: Column(
        children: [
          // Barra de herramientas superior de la Cuadrícula (Selector 4 Págs / 6 Págs + Ir a Pág. Narrada)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF1C1E24),
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.grid_view_rounded, size: 16, color: Color(0xFFF5A623)),
                    const SizedBox(width: 6),
                    const Text(
                      'Vista Mosaico:',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildGridDensityChip(count: 4, label: '4 Págs'),
                    const SizedBox(width: 6),
                    _buildGridDensityChip(count: 6, label: '6 Págs'),
                  ],
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    setState(() {
                      _isGridMode = false;
                      _currentPdfPage = _audioSyncedPdfPage;
                    });
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _pdfPageController?.jumpToPage(_audioSyncedPdfPage);
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5A623).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFF5A623)),
                    ),
                    child: Text(
                      '🔊 Pág. ${_audioSyncedPdfPage + 1}',
                      style: const TextStyle(
                        color: Color(0xFFF5A623),
                        fontWeight: FontWeight.w800,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              controller: _gridScrollController,
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: _gridPagesPerView == 6 ? 10 : 14,
                mainAxisSpacing: _gridPagesPerView == 6 ? 12 : 16,
                childAspectRatio: childAspectRatio,
              ),
              itemCount: _totalPdfPages,
              itemBuilder: (context, pageIdx) {
                final Uint8List? thumbBytes = _pdfThumbCache[pageIdx] ?? _pdfPageCache[pageIdx];
                if (thumbBytes == null) {
                  _loadPdfThumbnail(pageIdx);
                }

                final bool isAudioPage = pageIdx == _audioSyncedPdfPage;
                final bool isCurrentSelected = pageIdx == _currentPdfPage;
                final bool hasSearchHit = searchMatchedPages.contains(pageIdx);

                return RepaintBoundary(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _currentPdfPage = pageIdx;
                        _isGridMode = false;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _pdfPageController?.jumpToPage(pageIdx);
                      });
                    },
                    onLongPress: () => _narrateFromPdfPage(pageIdx),
                    child: Column(
                      children: [
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isAudioPage
                                    ? const Color(0xFFF5A623)
                                    : (hasSearchHit
                                        ? const Color(0xFF00E5FF)
                                        : (isCurrentSelected ? Colors.white : Colors.white24)),
                                width: (isAudioPage || hasSearchHit || isCurrentSelected) ? 2.4 : 1.0,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black45,
                                  blurRadius: 6,
                                  offset: Offset(0, 3),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (thumbBytes != null)
                                    _applyPdfThemeFilter(
                                      Image.memory(
                                        thumbBytes,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                      ),
                                    )
                                  else
                                    Container(
                                      color: const Color(0xFF22242C),
                                      child: const Center(
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Color(0xFFF5A623),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (isAudioPage)
                                    Positioned(
                                      top: 5,
                                      right: 5,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF5A623),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Text(
                                          '🔊 VOZ',
                                          style: TextStyle(
                                            color: Colors.black,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 9.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (hasSearchHit)
                                    Positioned(
                                      top: 5,
                                      left: 5,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00E5FF),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Icon(
                                          Icons.search_rounded,
                                          size: 11,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${pageIdx + 1}',
                              style: TextStyle(
                                color: isAudioPage
                                    ? const Color(0xFFF5A623)
                                    : (isCurrentSelected ? Colors.white : Colors.white70),
                                fontWeight: (isAudioPage || isCurrentSelected)
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                fontSize: 12.5,
                              ),
                            ),
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () => _narrateFromPdfPage(pageIdx),
                              child: Icon(
                                Icons.play_circle_fill_rounded,
                                size: 15,
                                color: isAudioPage
                                    ? const Color(0xFFF5A623)
                                    : Colors.white38,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridDensityChip({required int count, required String label}) {
    final bool selected = _gridPagesPerView == count;
    return GestureDetector(
      onTap: () {
        setState(() => _gridPagesPerView = count);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF5A623) : Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: FontWeight.w800,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  /// Controles inferiores minimalistas inspirados en la captura de referencia (Mini-reproductor flotante + barra de iconos limpia)
  Widget _buildAmorFatiStyleBottomControls() {
    final liveAudioCh = widget.book.chapters[
        _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1)];
    final elapsed = _activeChapterElapsed;
    final total = _activeChapterTotal;
    final remaining = Duration(seconds: max(0, total.inSeconds - elapsed.inSeconds));
    final double progress = (elapsed.inSeconds / max(1, total.inSeconds)).clamp(0.0, 1.0);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1B1F),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Deslizador rápido de páginas del PDF (se despliega al tocar el icono de deslizador)
            if (_showPageSliderBar && _viewerMode == 0 && _totalPdfPages > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: Row(
                  children: [
                    Text(
                      'Pág. ${_currentPdfPage + 1}',
                      style: const TextStyle(
                        color: Color(0xFFF5A623),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.5,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                          activeTrackColor: const Color(0xFFF5A623),
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: _currentPdfPage
                              .toDouble()
                              .clamp(0.0, max(0.0, _totalPdfPages - 1.0)),
                          min: 0.0,
                          max: max(0.0, _totalPdfPages - 1.0),
                          onChanged: (val) {
                            final p = val.round();
                            if (p != _currentPdfPage) {
                              setState(() => _currentPdfPage = p);
                              _pageTurnDebounceTimer?.cancel();
                              _pageTurnDebounceTimer = Timer(const Duration(milliseconds: 120), () {
                                _pdfPageController?.jumpToPage(p);
                              });
                            }
                          },
                        ),
                      ),
                    ),
                    Text(
                      '$_totalPdfPages',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            // Mini-reproductor flotante compacto (Portada + Título + Tiempo 0:05 • -0:22 + ⏮ ⏸ ⏭ + Barra dorada en la base)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF282A30),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                        child: Row(
                          children: [
                            BookCoverWidget(
                              book: widget.book,
                              width: 42,
                              height: 42,
                              borderRadius: 8,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    liveAudioCh.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${TextSanitizer.formatDuration(elapsed)}  •  -${TextSanitizer.formatDuration(remaining)}  (Pág. ${_audioSyncedPdfPage + 1})',
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.skip_previous_rounded,
                                color: Colors.white,
                                size: 26,
                              ),
                              tooltip: 'Párrafo anterior',
                              onPressed: () => _skipParagraph(-1),
                            ),
                            GestureDetector(
                              onTap: () {
                                if (_isPlaying) {
                                  NativeChannelService.pauseLoFi();
                                  widget.player.pause();
                                } else {
                                  widget.player.play();
                                  NativeChannelService.playLoFi();
                                }
                              },
                              child: Container(
                                width: 40,
                                height: 40,
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF5A623),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                  color: Colors.black,
                                  size: 24,
                                ),
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(
                                Icons.skip_next_rounded,
                                color: Colors.white,
                                size: 26,
                              ),
                              tooltip: 'Siguiente párrafo',
                              onPressed: () => _skipParagraph(1),
                            ),
                          ],
                        ),
                      ),
                      // Línea de progreso dorada integrada en el borde inferior de la píldora
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFF5A623)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Barra de iconos inferior estilo lector profesional (Capítulos | Cuadrícula 4/6 | Brillo/Tema | Deslizador Págs | Scroll H/V | Modo Texto 'A' | Modo Audio 🎧)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.format_list_bulleted_rounded, color: Colors.white70),
                    tooltip: 'Capítulos',
                    onPressed: _showChapterSelector,
                  ),
                  if (_viewerMode == 0 && _totalPdfPages > 0)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.grid_view_rounded,
                        color: _isGridMode ? const Color(0xFFF5A623) : Colors.white70,
                      ),
                      tooltip: 'Cuadrícula de 4 / 6 páginas',
                      onPressed: _toggleGridMode,
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _pdfColorTheme == 0
                          ? Icons.wb_sunny_outlined
                          : (_pdfColorTheme == 1
                              ? Icons.auto_awesome_mosaic_outlined
                              : Icons.dark_mode_rounded),
                      color: _pdfColorTheme == 0 ? Colors.white70 : const Color(0xFFF5A623),
                    ),
                    tooltip: 'Tema de página (Día / Sepia / Noche)',
                    onPressed: () {
                      setState(() {
                        _pdfColorTheme = (_pdfColorTheme + 1) % 3;
                      });
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.tune_rounded,
                      color: _showPageSliderBar ? const Color(0xFFF5A623) : Colors.white70,
                    ),
                    tooltip: 'Deslizador de páginas',
                    onPressed: () {
                      setState(() {
                        _showPageSliderBar = !_showPageSliderBar;
                      });
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _isVerticalScroll
                          ? Icons.swap_vert_rounded
                          : Icons.swap_horiz_rounded,
                      color: _isVerticalScroll ? const Color(0xFFF5A623) : Colors.white70,
                    ),
                    tooltip: _isVerticalScroll
                        ? 'Desplazamiento Vertical (Tocá para Horizontal)'
                        : 'Desplazamiento Horizontal (Tocá para Vertical)',
                    onPressed: () {
                      setState(() {
                        _isVerticalScroll = !_isVerticalScroll;
                      });
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.text_fields_rounded,
                      color: _viewerMode == 1 ? const Color(0xFFF5A623) : Colors.white70,
                    ),
                    tooltip: 'Alternar PDF Original / Modo Texto',
                    onPressed: () {
                      setState(() {
                        _isGridMode = false;
                        _viewerMode = _viewerMode == 0 ? 1 : 0;
                      });
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.headphones_rounded, color: Color(0xFFF5A623)),
                    tooltip: 'Volver al reproductor principal',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextReader(ChapterItem chapter) {
    final segments = chapter.segments;
    final isSameChapterAsAudio = _liveAudioChapterIndex == _activeChapterIndex;
    final activeSeg = _liveAudioSegmentIndex;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: const Color(0xFF16181D),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${segments.length} párrafos • ${chapter.subtitle}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.text_decrease_rounded, size: 20, color: Colors.white70),
                    onPressed: () {
                      if (_fontSize > 13) setState(() => _fontSize -= 1.5);
                    },
                  ),
                  Text(
                    '${_fontSize.round()}',
                    style: const TextStyle(
                      color: Color(0xFFF5A623),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.text_increase_rounded, size: 20, color: Colors.white70),
                    onPressed: () {
                      if (_fontSize < 28) setState(() => _fontSize += 1.5);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _textScrollController,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
            itemCount: segments.length,
            itemBuilder: (context, sIdx) {
              final isCurrentAudioSegment = isSameChapterAsAudio && activeSeg == sIdx;
              final text = segments[sIdx];

              return GestureDetector(
                key: isCurrentAudioSegment ? _activeTextSegmentKey : null,
                onTap: () {
                  setState(() {
                    _liveAudioChapterIndex = _activeChapterIndex;
                    _liveAudioSegmentIndex = sIdx;
                    _livePosition = Duration.zero;
                  });
                  widget.onSeekToPosition?.call(_activeChapterIndex, sIdx);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: EdgeInsets.all(isCurrentAudioSegment ? 14 : 0),
                  decoration: BoxDecoration(
                    color: isCurrentAudioSegment
                        ? const Color(0xFFF5A623).withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: isCurrentAudioSegment
                        ? Border.all(color: const Color(0xFFF5A623), width: 1.3)
                        : null,
                  ),
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: _fontSize,
                      height: 1.65,
                      color: isCurrentAudioSegment
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.85),
                      fontWeight: isCurrentAudioSegment ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showJumpToPageDialog() {
    if (_totalPdfPages <= 0) return;
    final controller = TextEditingController(text: '${_currentPdfPage + 1}');
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1B1D24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Ir a la página (y narrar desde ahí)',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            decoration: InputDecoration(
              hintText: '1 - $_totalPdfPages',
              suffixText: 'de $_totalPdfPages',
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFF5A623)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.white24),
              ),
            ),
            onSubmitted: (_) {
              final pageNum = int.tryParse(controller.text.trim());
              Navigator.pop(ctx);
              if (pageNum != null) {
                final target = (pageNum - 1).clamp(0, _totalPdfPages - 1);
                _pdfPageController?.jumpToPage(target);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFF5A623),
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                final pageNum = int.tryParse(controller.text.trim());
                Navigator.pop(ctx);
                if (pageNum != null) {
                  final target = (pageNum - 1).clamp(0, _totalPdfPages - 1);
                  _pdfPageController?.jumpToPage(target);
                }
              },
              child: const Text('Ir y Narrar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showChapterSelector() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF181A1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          minChildSize: 0.40,
          maxChildSize: 0.85,
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
                const Text(
                  'Capítulos y Páginas del Libro',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const SizedBox(height: 12),
                ...widget.book.chapters.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final ch = entry.value;
                  final isAudioHere = idx == _liveAudioChapterIndex;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 15,
                      backgroundColor:
                          isAudioHere ? const Color(0xFFF5A623) : const Color(0xFF2C2D32),
                      child: Text(
                        ch.id.toString(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isAudioHere ? Colors.black : Colors.white70,
                        ),
                      ),
                    ),
                    title: Text(
                      ch.title,
                      style: TextStyle(
                        fontWeight: isAudioHere ? FontWeight.bold : FontWeight.normal,
                        color: isAudioHere ? const Color(0xFFF5A623) : Colors.white,
                      ),
                    ),
                    subtitle: Text(
                      isAudioHere
                          ? '🔊 Narrando acá • ${ch.subtitle} • ${ch.durationText}'
                          : '${ch.subtitle} • ${ch.durationText}',
                      style: TextStyle(
                        color: isAudioHere ? const Color(0xFFF5A623) : Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _activeChapterIndex = idx);
                      if (_viewerMode == 0 && _totalPdfPages > 0) {
                        final range = _parseChapterPageRange(ch);
                        if (range != null) {
                          _pdfPageController?.jumpToPage(
                            range[0].clamp(0, _totalPdfPages - 1),
                          );
                        }
                      } else {
                        widget.onSeekToPosition?.call(idx, 0);
                      }
                    },
                  );
                }),
              ],
            );
          },
        );
      },
    );
  }
}

/// Pinta el subrayado dorado suave sobre las líneas del párrafo actual, resalta la palabra exacta pronunciada y pinta en cian (#00E5FF) las palabras buscadas
class _PdfLiveHighlightPainter extends CustomPainter {
  final List<Rect> lineNormRects;
  final Rect? wordNormRect;
  final List<Rect> searchNormRects;
  final bool isDarkPageTheme;

  const _PdfLiveHighlightPainter({
    required this.lineNormRects,
    required this.wordNormRect,
    this.searchNormRects = const [],
    required this.isDarkPageTheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Subrayado suave del párrafo/bloque de líneas actual en el tono dorado de AudioMind (#F5A623)
    final Paint linePaint = Paint()
      ..color = const Color(0xFFF5A623).withValues(alpha: isDarkPageTheme ? 0.24 : 0.25)
      ..style = PaintingStyle.fill;

    for (final norm in lineNormRects) {
      final rect = Rect.fromLTWH(
        norm.left * size.width - 2,
        norm.top * size.height - 1,
        norm.width * size.width + 4,
        norm.height * size.height + 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3.5)),
        linePaint,
      );
    }

    // 2. Resaltado de coincidencias del Buscador de Palabras en Cian Brillante (#00E5FF)
    if (searchNormRects.isNotEmpty) {
      final Paint searchFillPaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: isDarkPageTheme ? 0.38 : 0.44)
        ..style = PaintingStyle.fill;
      final Paint searchBorderPaint = Paint()
        ..color = const Color(0xFF00B8D4)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;

      for (final sNorm in searchNormRects) {
        final sRect = Rect.fromLTWH(
          sNorm.left * size.width - 2,
          sNorm.top * size.height - 1.5,
          sNorm.width * size.width + 4,
          sNorm.height * size.height + 3,
        );
        final rrect = RRect.fromRectAndRadius(sRect, const Radius.circular(3.5));
        canvas.drawRRect(rrect, searchFillPaint);
        canvas.drawRRect(rrect, searchBorderPaint);
      }
    }

    // 3. Resaltado más intenso para la palabra exacta que está diciendo el narrador en este milisegundo
    if (wordNormRect != null) {
      final wRect = Rect.fromLTWH(
        wordNormRect!.left * size.width - 2.5,
        wordNormRect!.top * size.height - 1.5,
        wordNormRect!.width * size.width + 5,
        wordNormRect!.height * size.height + 3,
      );

      final Paint wordFillPaint = Paint()
        ..color = const Color(0xFFF5A623).withValues(alpha: isDarkPageTheme ? 0.50 : 0.55)
        ..style = PaintingStyle.fill;

      final Paint wordUnderlinePaint = Paint()
        ..color = const Color(0xFFD98200)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;

      canvas.drawRRect(
        RRect.fromRectAndRadius(wRect, const Radius.circular(4)),
        wordFillPaint,
      );
      canvas.drawLine(
        Offset(wRect.left + 1, wRect.bottom),
        Offset(wRect.right - 1, wRect.bottom),
        wordUnderlinePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PdfLiveHighlightPainter oldDelegate) {
    return oldDelegate.wordNormRect != wordNormRect ||
        oldDelegate.lineNormRects != lineNormRects ||
        oldDelegate.searchNormRects != searchNormRects ||
        oldDelegate.isDarkPageTheme != isDarkPageTheme;
  }
}
