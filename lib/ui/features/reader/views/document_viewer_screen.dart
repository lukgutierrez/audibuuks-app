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

  PageController? _pdfPageController;
  PdfDocument? _pdfDoc;
  PdfTextExtractor? _pdfTextExtractor;
  int _currentPdfPage = 0;
  int _totalPdfPages = 0;
  int _audioSyncedPdfPage = 0;
  bool _isProgrammaticPageTurn = false;

  final Map<int, Uint8List> _pdfPageCache = {};
  final Map<int, PdfPageOverlayData> _pdfOverlayCache = {};
  bool _hasLocalPdf = false;
  bool _isLoadingPdfPage = false;

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
    if (mounted && prefs['voiceKey'] is String) {
      setState(() {
        _selectedVoiceKey = prefs['voiceKey'] as String;
      });
    }
  }

  void _setupLiveAudioListeners() {
    _isPlaying = widget.player.playing;
    _livePosition = widget.player.position;
    if (widget.player.duration != null) {
      _liveDuration = widget.player.duration!;
    }

    _playerSub = widget.player.playerStateStream.listen((state) {
      if (mounted && _isPlaying != state.playing) {
        setState(() => _isPlaying = state.playing);
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
    _pageTurnDebounceTimer?.cancel();
    _liveSyncTimer?.cancel();
    _playerSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _sequenceSub?.cancel();
    _pdfPageController?.dispose();
    _textScrollController.dispose();
    _pdfDoc?.dispose();
    super.dispose();
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
    final segs = ch.segments;
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
        };

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
    // Si estamos en Modo Libre y es una página lejana al audio, no bloquear el hilo con extracción sincrónica
    if (!_autoFollowAudio && pageIndex != _audioSyncedPdfPage) {
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
    final segs = ch.segments;
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

    // Buscamos el bloque contiguo de líneas en la página que mejor coincide con el párrafo actual
    final List<int> matchedLineIndices = [];
    for (int i = 0; i < overlay.lines.length; i++) {
      final line = overlay.lines[i];
      if (line.cleanText.isEmpty) continue;

      if (segJoined.contains(line.cleanText) || line.cleanText.contains(segJoined)) {
        matchedLineIndices.add(i);
        continue;
      }

      final lineTokens = line.words
          .map((w) => w.cleanToken)
          .where((t) => t.length >= 3)
          .toList();
      if (lineTokens.isEmpty) continue;

      int hits = 0;
      for (final lt in lineTokens) {
        if (segWordSet.contains(lt)) hits++;
      }
      final ratio = hits / lineTokens.length;
      if (ratio >= 0.55 || (hits >= 3 && ratio >= 0.42)) {
        matchedLineIndices.add(i);
      }
    }

    // Si alguna línea intermedia quedó suelta entre dos líneas del mismo párrafo, la incluimos para que el bloque sea continuo
    if (matchedLineIndices.length >= 2) {
      final firstIdx = matchedLineIndices.first;
      final lastIdx = matchedLineIndices.last;
      if (lastIdx - firstIdx <= 14) {
        matchedLineIndices
          ..clear()
          ..addAll(List.generate(lastIdx - firstIdx + 1, (k) => firstIdx + k));
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
          if (posMs >= timings[i].startMs - 45) {
            eventIdx = i;
          } else {
            break;
          }
        }
        final ratio = (eventIdx / max(1, timings.length - 1)).clamp(0.0, 1.0);
        final expectedIdx = (ratio * (paragraphPdfWords.length - 1))
            .round()
            .clamp(0, paragraphPdfWords.length - 1);
        final spokenClean = _normalizeToken(timings[eventIdx].word);

      // Tolerancia: si coincide la palabra o contiene los primeros 3 caracteres clave
      if (spokenClean.isNotEmpty) {
        final minSearch = max(0, expectedIdx - 6);
        final maxSearch = min(paragraphPdfWords.length - 1, expectedIdx + 6);
        int bestIdx = expectedIdx;
        int bestDist = 999;
        for (int k = minSearch; k <= maxSearch; k++) {
          final candToken = paragraphPdfWords[k].cleanToken;
          if (candToken == spokenClean ||
              (spokenClean.length >= 3 && candToken.startsWith(spokenClean.substring(0, min(3, spokenClean.length))))) {
            final dist = (k - expectedIdx).abs();
            if (dist < bestDist) {
              bestDist = dist;
              bestIdx = k;
            }
          }
        }
        activeWordRect = paragraphPdfWords[bestIdx].normBounds;
      } else {
        activeWordRect = paragraphPdfWords[expectedIdx].normBounds;
      }
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
        final segs = ch.segments;
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

  /// Salta el audio a la página `targetPage` (o al párrafo exacto que el usuario tocó sobre la hoja del PDF)
  void _seekAudioToPdfPage(int targetPage, {int? specificSegIdx}) {
    if (_totalPdfPages <= 0) return;
    final info = _resolveChapterAndSegmentsForPdfPage(targetPage);
    final targetSeg = specificSegIdx ?? info.startSeg;

    setState(() {
      _activeChapterIndex = info.chapterIndex;
      _liveAudioChapterIndex = info.chapterIndex;
      _liveAudioSegmentIndex = targetSeg;
      _audioSyncedPdfPage = targetPage;
      _livePosition = Duration.zero;
    });

    widget.onSeekToPosition?.call(info.chapterIndex, targetSeg);
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

    final tappedTokens = tappedLine.words
        .map((w) => w.cleanToken)
        .where((t) => t.length >= 3)
        .toList();

    int bestSegIdx = info.startSeg;
    int bestScore = -1;

    for (int s = 0; s < segs.length; s++) {
      final cleanSeg = segs[s]
          .split(RegExp(r'\s+'))
          .map(_normalizeToken)
          .where((w) => w.isNotEmpty)
          .join(' ');

      if (cleanSeg.contains(tappedLine.cleanText)) {
        bestSegIdx = s;
        bestScore = 999;
        break;
      }

      int hits = 0;
      for (final tok in tappedTokens) {
        if (cleanSeg.contains(tok)) hits++;
      }
      // Bonus si el párrafo está dentro del rango estimado de esta página
      if (s >= info.startSeg && s <= info.endSeg) {
        hits += 1;
      }
      if (hits > bestScore) {
        bestScore = hits;
        bestSegIdx = s;
      }
    }

    _seekAudioToPdfPage(pageIndex, specificSegIdx: bestSegIdx);
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

  Future<void> _loadPdfPage(int pageIndex) async {
    if (pageIndex < 0 || (_totalPdfPages > 0 && pageIndex >= _totalPdfPages)) return;
    if (_autoFollowAudio || pageIndex == _audioSyncedPdfPage) {
      _ensurePageOverlayExtracted(pageIndex);
    }
    if (_pdfPageCache.containsKey(pageIndex)) return;
    final path = widget.book.originalFilePath;
    if (path == null) return;
    final res = await NativeChannelService.renderPdfPage(path, pageIndex, width: 1300);
    if (res != null && mounted && res['bytes'] is Uint8List) {
      setState(() {
        _pdfPageCache[pageIndex] = res['bytes'] as Uint8List;
      });
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
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _viewerMode == 0 && _totalPdfPages > 0
                          ? 'Pág. ${_currentPdfPage + 1} de $_totalPdfPages • Tocá cualquier línea para narrar'
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
                if (_viewerMode == 0 && _totalPdfPages > 0)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      if (!_autoFollowAudio) {
                        // Al volver a Sincronizado, reanuda el audio y viaja a la página sincronizada
                        _jumpToAudioPosition();
                        if (!_isPlaying) {
                          widget.player.play();
                          NativeChannelService.playLoFi();
                        }
                      } else {
                        // Al entrar a Modo Libre, pausa el audio y lofi de inmediato para que leas tranquilo sin conflicto ni lag
                        if (_isPlaying) {
                          widget.player.pause();
                          NativeChannelService.pauseLoFi();
                        }
                        setState(() => _autoFollowAudio = false);
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                            size: 14,
                            color: _autoFollowAudio ? const Color(0xFFF5A623) : Colors.white70,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _autoFollowAudio ? 'Sincronizado' : 'Modo Libre',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _autoFollowAudio ? const Color(0xFFF5A623) : Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.format_list_bulleted_rounded, color: Colors.white70),
                  tooltip: 'Capítulos',
                  onPressed: _showChapterSelector,
                ),
              ],
            ),
      body: Column(
        children: [
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

    return Stack(
      children: [
        PageView.builder(
          controller: _pdfPageController,
          scrollDirection: _isVerticalScroll ? Axis.vertical : Axis.horizontal,
          itemCount: _totalPdfPages,
          onPageChanged: (pageIdx) {
            setState(() {
              _currentPdfPage = pageIdx;
              // Si el usuario pasa de página manualmente lejos del audio, entra en Modo Libre automático
              if (!_isProgrammaticPageTurn && pageIdx != _audioSyncedPdfPage) {
                _autoFollowAudio = false;
              }
            });
            _preloadPdfPages([pageIdx - 1, pageIdx + 1, pageIdx + 2]);
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
            final bool isDarkTheme = _pdfColorTheme == 2;

            return InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.5,
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
                              ),
                            ),
                            // 2. Capa de subrayado sincronizado en vivo con el tono dorado de AudioMind (#F5A623)
                            if (highlights.activeLineRects.isNotEmpty ||
                                highlights.activeWordRect != null)
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: _PdfLiveHighlightPainter(
                                    lineNormRects: highlights.activeLineRects,
                                    wordNormRect: highlights.activeWordRect,
                                    isDarkPageTheme: isDarkTheme,
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
                            _pdfPageController?.jumpToPage(p);
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
            // Barra de iconos inferior estilo lector profesional (Capítulos | Brillo/Tema | Deslizador Págs | Modo Texto 'A' | Modo Audio 🎧)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.format_list_bulleted_rounded, color: Colors.white70),
                    tooltip: 'Capítulos',
                    onPressed: _showChapterSelector,
                  ),
                  IconButton(
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
                    icon: Icon(
                      Icons.text_fields_rounded,
                      color: _viewerMode == 1 ? const Color(0xFFF5A623) : Colors.white70,
                    ),
                    tooltip: 'Alternar PDF Original / Modo Texto',
                    onPressed: () {
                      setState(() {
                        _viewerMode = _viewerMode == 0 ? 1 : 0;
                      });
                    },
                  ),
                  IconButton(
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

/// Pinta el subrayado dorado suave sobre las líneas del párrafo actual y resalta con más intensidad la palabra exacta que se está pronunciando
class _PdfLiveHighlightPainter extends CustomPainter {
  final List<Rect> lineNormRects;
  final Rect? wordNormRect;
  final bool isDarkPageTheme;

  const _PdfLiveHighlightPainter({
    required this.lineNormRects,
    required this.wordNormRect,
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

    // 2. Resaltado más intenso para la palabra exacta que está diciendo el narrador en este milisegundo
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
        oldDelegate.isDarkPageTheme != isDarkPageTheme;
  }
}
