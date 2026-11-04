import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../data/repositories/library_repository.dart';
import '../../../../data/services/native_channel_service.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';

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
  late int _viewerMode; // 0 = PDF Original (con imágenes), 1 = Modo Lectura Texto
  late int _activeChapterIndex;
  double _fontSize = 17.5;

  // Filtro visual para las hojas del PDF: 0 = Original (Blanco), 1 = Sepia Cálido, 2 = Modo Noche Oscuro
  int _pdfColorTheme = 0;
  bool _immersiveFullscreen = false;
  bool _autoFollowAudio = true;

  PageController? _pdfPageController;
  int _currentPdfPage = 0;
  int _totalPdfPages = 0;
  int _audioSyncedPdfPage = 0;
  final Map<int, Uint8List> _pdfPageCache = {};
  bool _hasLocalPdf = false;
  bool _isLoadingPdfPage = false;

  // Estado en vivo del narrador mientras el visor está abierto
  late int _liveAudioChapterIndex;
  late int _liveAudioSegmentIndex;
  final ScrollController _textScrollController = ScrollController();
  final GlobalKey _activeTextSegmentKey = GlobalKey();

  StreamSubscription<PlayerState>? _playerSub;
  StreamSubscription<SequenceState?>? _sequenceSub;
  Timer? _liveSyncTimer;
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

    // Por defecto abrimos en Modo PDF Original (0) a menos que sea explícitamente un EPUB
    _viewerMode = (widget.book.fileType == 'epub') ? 1 : 0;

    _isPlaying = widget.player.playing;
    _playerSub = widget.player.playerStateStream.listen((state) {
      if (mounted && _isPlaying != state.playing) {
        setState(() => _isPlaying = state.playing);
      }
    });

    // Escucha cambios de párrafo/capítulo en tiempo real mientras se reproduce el audio
    _sequenceSub = widget.player.sequenceStateStream.listen((_) {
      _syncWithLiveBookProgress();
    });
    _liveSyncTimer = Timer.periodic(const Duration(milliseconds: 650), (_) {
      _syncWithLiveBookProgress();
    });

    if (_hasLocalPdf) {
      _initPdfRenderer();
    } else if (widget.book.fileType != 'epub') {
      _tryAutoLocatePdfOnDevice();
    }
  }

  @override
  void dispose() {
    _liveSyncTimer?.cancel();
    _playerSub?.cancel();
    _sequenceSub?.cancel();
    _pdfPageController?.dispose();
    _textScrollController.dispose();
    super.dispose();
  }

  /// Sincroniza en vivo el capítulo, párrafo y página del PDF a medida que el narrador avanza
  void _syncWithLiveBookProgress() {
    if (!mounted) return;
    final newChIdx = widget.book.lastChapterIndex.clamp(
      0,
      max<int>(0, widget.book.chapters.length - 1),
    );
    final newSegIdx = widget.book.lastSegmentIndex;

    if (newChIdx != _liveAudioChapterIndex || newSegIdx != _liveAudioSegmentIndex) {
      final prevSyncedPage = _audioSyncedPdfPage;
      final bool wasOnSyncedPage = (_currentPdfPage == prevSyncedPage);

      setState(() {
        _liveAudioChapterIndex = newChIdx;
        _liveAudioSegmentIndex = newSegIdx;
        if (_totalPdfPages > 0) {
          _audioSyncedPdfPage = _calculateExactAudioPdfPage(_totalPdfPages);
        }
      });

      // Si el usuario tiene activo el seguimiento en vivo y estaba en la página del audio,
      // avanzamos automáticamente la página del PDF cuando el narrador cruza de hoja.
      if (_viewerMode == 0 &&
          _autoFollowAudio &&
          wasOnSyncedPage &&
          _totalPdfPages > 0 &&
          _audioSyncedPdfPage != _currentPdfPage) {
        _pdfPageController?.animateToPage(
          _audioSyncedPdfPage,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      }

      // En Modo Texto, si sigue el audio, mantener el capítulo y hacer auto-scroll suave
      if (_viewerMode == 1 && _autoFollowAudio) {
        if (_activeChapterIndex != newChIdx) {
          setState(() => _activeChapterIndex = newChIdx);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _activeTextSegmentKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: 0.28,
            );
          }
        });
      }
    }
  }

  /// Extrae el rango de páginas reales [startPageZeroBased, endPageZeroBased] buscando tanto en title como en subtitle ("Capítulo 5: Págs. 41-50")
  List<int>? _parseChapterPageRange(ChapterItem ch) {
    final combined = '${ch.title} ${ch.subtitle}';
    final m = RegExp(r'Págs?\.\s*(\d+)(?:\s*-\s*(\d+))?', caseSensitive: false)
        .firstMatch(combined);
    if (m == null) return null;
    final start = (int.tryParse(m.group(1) ?? '') ?? 1) - 1;
    final end = (int.tryParse(m.group(2) ?? m.group(1) ?? '') ?? (start + 1)) - 1;
    return [max(0, start), max(0, end)];
  }

  /// Calcula la página exacta del PDF (0-based) donde está hablando el narrador ahora mismo
  int _calculateExactAudioPdfPage(int totalPages) {
    if (totalPages <= 0) return 0;
    final chIdx = _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];
    final segs = ch.segments;
    final totalSegs = max(1, segs.length);
    final segIdx = _liveAudioSegmentIndex.clamp(0, totalSegs - 1);

    final range = _parseChapterPageRange(ch);
    if (range != null) {
      final startP = range[0].clamp(0, totalPages - 1);
      final endP = range[1].clamp(startP, totalPages - 1);
      final pageSpan = max(1, endP - startP + 1);
      final pageOffset = ((segIdx / totalSegs) * pageSpan).floor().clamp(0, pageSpan - 1);
      return (startP + pageOffset).clamp(0, totalPages - 1);
    }

    // Fallback proporcional si el capítulo no tenía rango explícito en el título
    final segRatio = (segIdx / totalSegs).clamp(0.0, 0.999);
    final bookRatio = (chIdx + segRatio) / max(1, widget.book.chapters.length);
    return (bookRatio * totalPages).floor().clamp(0, totalPages - 1);
  }

  /// Devuelve el capítulo y el rango de índices de párrafos [startSeg, endSeg] que corresponden a una página del PDF (0-based)
  ({ int chapterIndex, ChapterItem chapter, int startSeg, int endSeg }) _resolveChapterAndSegmentsForPdfPage(
    int targetPage,
  ) {
    for (int i = 0; i < widget.book.chapters.length; i++) {
      final ch = widget.book.chapters[i];
      final range = _parseChapterPageRange(ch);
      if (range != null && targetPage >= range[0] && targetPage <= range[1]) {
        final segs = ch.segments;
        if (segs.isEmpty) {
          return (chapterIndex: i, chapter: ch, startSeg: 0, endSeg: 0);
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

    // Fallback proporcional si no hay etiqueta de páginas
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

  /// Inicia inmediatamente la narración en la página del PDF que estás mirando (o en un párrafo específico)
  void _playAudioFromPdfPage(int targetPage, {int? specificSegIdx}) {
    if (_totalPdfPages <= 0) return;
    final info = _resolveChapterAndSegmentsForPdfPage(targetPage);
    final targetSeg = specificSegIdx ?? info.startSeg;

    setState(() {
      _activeChapterIndex = info.chapterIndex;
      _liveAudioChapterIndex = info.chapterIndex;
      _liveAudioSegmentIndex = targetSeg;
      _audioSyncedPdfPage = targetPage;
      _autoFollowAudio = true;
    });

    widget.onSeekToPosition?.call(info.chapterIndex, targetSeg);

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '🔊 Narrando Pág. ${targetPage + 1} (${info.chapter.title} • Párr. ${targetSeg + 1})',
          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black),
        ),
        backgroundColor: const Color(0xFFF5A623),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1800),
      ),
    );
  }

  /// Abre un selector rápido con todos los párrafos de la página actual del PDF para elegir exactamente desde qué frase escuchar
  void _showPageParagraphPickerModal(int targetPage) {
    final info = _resolveChapterAndSegmentsForPdfPage(targetPage);
    final segs = info.chapter.segments;
    if (segs.isEmpty) return;

    // Mostramos los párrafos de esta página primero (resaltados), y el resto del capítulo debajo
    final int highlightStart = info.startSeg;
    final int highlightEnd = info.endSeg;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          minChildSize: 0.40,
          maxChildSize: 0.90,
          builder: (_, scrollController) {
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
                    children: [
                      const Icon(Icons.record_voice_over_rounded, color: Color(0xFFF5A623)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Narrar desde Pág. ${targetPage + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 17,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              'Tocá cualquier párrafo de ${info.chapter.title} para empezar ahí',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: segs.length,
                    itemBuilder: (ctx, idx) {
                      final bool isInThisPage = idx >= highlightStart && idx <= highlightEnd;
                      final bool isPlayingNow =
                          info.chapterIndex == _liveAudioChapterIndex &&
                          idx == _liveAudioSegmentIndex;

                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _playAudioFromPdfPage(targetPage, specificSegIdx: idx);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isPlayingNow
                                ? const Color(0xFFF5A623).withValues(alpha: 0.18)
                                : (isInThisPage
                                    ? Colors.white.withValues(alpha: 0.07)
                                    : Colors.white.withValues(alpha: 0.02)),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isPlayingNow
                                  ? const Color(0xFFF5A623)
                                  : (isInThisPage
                                      ? const Color(0xFFF5A623).withValues(alpha: 0.45)
                                      : Colors.white10),
                              width: isPlayingNow ? 1.5 : 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        isPlayingNow
                                            ? Icons.graphic_eq_rounded
                                            : Icons.play_circle_fill_rounded,
                                        size: 16,
                                        color: isPlayingNow || isInThisPage
                                            ? const Color(0xFFF5A623)
                                            : Colors.white54,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Párrafo ${idx + 1}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 12,
                                          color: isPlayingNow || isInThisPage
                                              ? const Color(0xFFF5A623)
                                              : Colors.white54,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (isInThisPage)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF5A623).withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        isPlayingNow ? 'Sonando ahora' : 'En Pág. ${targetPage + 1}',
                                        style: const TextStyle(
                                          color: Color(0xFFF5A623),
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                segs[idx],
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isInThisPage ? Colors.white : Colors.white70,
                                  fontSize: 13.5,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
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

  /// Modal rápido para escribir o saltar a cualquier número de página del PDF
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
            'Ir a la página',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
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
              child: const Text('Ir a página', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  /// Si el libro fue cargado en una versión anterior antes de guardar originalFilePath, busca automáticamente en books/
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

  /// Permite vincular en 1 toque el archivo PDF original para libros que habían sido importados en versiones viejas
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

    final res = await NativeChannelService.renderPdfPage(path, 0, width: 1250);
    if (res != null && mounted) {
      final total = (res['pageCount'] as int?) ?? 1;
      final firstBytes = res['bytes'] as Uint8List?;
      if (firstBytes != null) _pdfPageCache[0] = firstBytes;

      final targetAudioPage = _calculateExactAudioPdfPage(total);
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
    if (_pdfPageCache.containsKey(pageIndex)) return;
    final path = widget.book.originalFilePath;
    if (path == null) return;
    final res = await NativeChannelService.renderPdfPage(path, pageIndex, width: 1250);
    if (res != null && mounted && res['bytes'] is Uint8List) {
      setState(() {
        _pdfPageCache[pageIndex] = res['bytes'] as Uint8List;
      });
    }
  }

  void _preloadPdfPages(List<int> pages) {
    for (final p in pages) {
      if (p >= 0 && p < _totalPdfPages && !_pdfPageCache.containsKey(p)) {
        _loadPdfPage(p);
      }
    }
  }

  void _jumpToAudioPosition() {
    setState(() => _autoFollowAudio = true);
    if (_viewerMode == 0 && _totalPdfPages > 0) {
      final targetPage = _calculateExactAudioPdfPage(_totalPdfPages);
      setState(() => _audioSyncedPdfPage = targetPage);
      _pdfPageController?.animateToPage(
        targetPage,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      setState(() {
        _activeChapterIndex =
            _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1);
      });
    }
  }

  String _getLiveAudioSnippetText() {
    final chIdx = _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];
    final segs = ch.segments;
    if (segs.isEmpty) return ch.title;
    final sIdx = _liveAudioSegmentIndex.clamp(0, segs.length - 1);
    return segs[sIdx];
  }

  /// Devuelve el texto del primer párrafo estimado en la página que el usuario está explorando
  String _getPreviewTextForPdfPage(int pageIdx) {
    final info = _resolveChapterAndSegmentsForPdfPage(pageIdx);
    final segs = info.chapter.segments;
    if (segs.isEmpty) return info.chapter.title;
    return segs[info.startSeg.clamp(0, segs.length - 1)];
  }

  Widget _applyPdfThemeFilter(Widget child) {
    if (_pdfColorTheme == 1) {
      // Filtro Sepia Cálido (descansa la vista)
      return ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.94, 0.0, 0.0, 0, 0,
          0.0, 0.89, 0.0, 0, 0,
          0.0, 0.0, 0.76, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: child,
      );
    } else if (_pdfColorTheme == 2) {
      // Filtro Modo Noche Inteligente (invierte hoja blanca a carbón oscuro #141518 y letras a blanco cálido)
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

  @override
  Widget build(BuildContext context) {
    final currentCh = widget.book.chapters[_activeChapterIndex];
    final audioCh = widget.book.chapters[
        _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1)];
    final bool isViewingDifferentPdfPage =
        _viewerMode == 0 && _totalPdfPages > 0 && _currentPdfPage != _audioSyncedPdfPage;
    final bool isViewingDifferentTextChapter =
        _viewerMode == 1 && _activeChapterIndex != _liveAudioChapterIndex;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      appBar: _immersiveFullscreen
          ? null
          : AppBar(
              backgroundColor: const Color(0xFF16181D),
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              titleSpacing: 0,
              title: GestureDetector(
                onTap: _viewerMode == 0 ? _showJumpToPageDialog : _showChapterSelector,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            _viewerMode == 0 && _totalPdfPages > 0
                                ? 'Pág. ${_currentPdfPage + 1} de $_totalPdfPages'
                                : currentCh.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFF5A623),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.unfold_more_rounded,
                          size: 13,
                          color: Color(0xFFF5A623),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                if (_viewerMode == 0 && _hasLocalPdf)
                  IconButton(
                    tooltip: _pdfColorTheme == 0
                        ? 'Cambiar a Modo Sepia'
                        : (_pdfColorTheme == 1 ? 'Cambiar a Modo Noche' : 'Cambiar a PDF Original'),
                    icon: Icon(
                      _pdfColorTheme == 0
                          ? Icons.wb_sunny_outlined
                          : (_pdfColorTheme == 1
                              ? Icons.auto_awesome_mosaic_outlined
                              : Icons.dark_mode_rounded),
                      size: 20,
                      color: _pdfColorTheme == 0 ? Colors.white70 : const Color(0xFFF5A623),
                    ),
                    onPressed: () {
                      setState(() {
                        _pdfColorTheme = (_pdfColorTheme + 1) % 3;
                      });
                    },
                  ),
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildViewerModeButton(
                        mode: 0,
                        icon: Icons.picture_as_pdf_rounded,
                        label: 'PDF',
                      ),
                      _buildViewerModeButton(
                        mode: 1,
                        icon: Icons.subject_rounded,
                        label: 'Texto',
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.format_list_bulleted_rounded, color: Colors.white70),
                  tooltip: 'Capítulos y Páginas',
                  onPressed: _showChapterSelector,
                ),
              ],
            ),
      body: Column(
        children: [
          // Solo mostramos este banner superior si el usuario se adelantó o atrasó a otra página distinta del audio
          if (!_immersiveFullscreen &&
              (isViewingDifferentPdfPage || isViewingDifferentTextChapter))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: const BoxDecoration(
                color: Color(0xFF221C14),
                border: Border(bottom: BorderSide(color: Color(0x44F5A623))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.graphic_eq_rounded, size: 17, color: Color(0xFFF5A623)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _viewerMode == 0 && _totalPdfPages > 0
                          ? 'Audio sonando en Pág. ${_audioSyncedPdfPage + 1} (${audioCh.title})'
                          : 'Audio en: ${audioCh.title} (Párr. ${_liveAudioSegmentIndex + 1})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF5A623).withValues(alpha: 0.22),
                      foregroundColor: const Color(0xFFF5A623),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _jumpToAudioPosition,
                    icon: const Icon(Icons.my_location_rounded, size: 13),
                    label: Text(
                      _viewerMode == 0 && _totalPdfPages > 0
                          ? 'Volver a Pág. ${_audioSyncedPdfPage + 1}'
                          : 'Ir al audio',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _viewerMode == 0
                ? _buildPdfOriginalView()
                : _buildTextReader(currentCh),
          ),
          if (!_immersiveFullscreen) _buildBottomBar(currentCh),
        ],
      ),
    );
  }

  Widget _buildViewerModeButton({
    required int mode,
    required IconData icon,
    required String label,
  }) {
    final bool selected = _viewerMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() => _viewerMode = mode);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF5A623) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 13.5, color: selected ? Colors.black : Colors.white70),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.black : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPdfOriginalView() {
    if (_isLoadingPdfPage) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFF5A623)),
            SizedBox(height: 12),
            Text(
              'Renderizando páginas e imágenes originales del PDF...',
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
                  'Ver PDF Original con Imágenes y Gráficos',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.book.fileType == 'epub'
                      ? 'Este libro fue cargado en formato EPUB. Si tenés también la versión en PDF, podés vincularla acá o leerlo en la pestaña Texto.'
                      : 'Este libro fue importado antes de activar el guardado de páginas originales. Seleccioná el archivo PDF una sola vez para ver todas sus páginas e imágenes sincronizadas con el audio.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
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
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => setState(() => _viewerMode = 1),
                  child: const Text(
                    'Ver en Modo Texto Sincronizado',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final bool isOnSyncedPage = _currentPdfPage == _audioSyncedPdfPage;
    final String cardSnippet = isOnSyncedPage
        ? _getLiveAudioSnippetText()
        : _getPreviewTextForPdfPage(_currentPdfPage);
    final pageChapterInfo = _resolveChapterAndSegmentsForPdfPage(_currentPdfPage);
    final liveAudioCh = widget.book.chapters[
        _liveAudioChapterIndex.clamp(0, widget.book.chapters.length - 1)];

    return Stack(
      children: [
        GestureDetector(
          onTap: () {
            setState(() {
              _immersiveFullscreen = !_immersiveFullscreen;
            });
          },
          child: PageView.builder(
            controller: _pdfPageController,
            itemCount: _totalPdfPages,
            onPageChanged: (pageIdx) {
              setState(() {
                _currentPdfPage = pageIdx;
                _autoFollowAudio = (pageIdx == _audioSyncedPdfPage);
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
              return InteractiveViewer(
                minScale: 1.0,
                maxScale: 5.0,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      4,
                      4,
                      4,
                      _immersiveFullscreen ? 12 : 84,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _applyPdfThemeFilter(
                        Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Botón flotante para salir de pantalla completa cuando está en modo inmersivo
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
        // Panel flotante inferior en vivo: muestra el párrafo que suena o permite narrar la página explorada / elegir párrafo exacto
        if (!_immersiveFullscreen)
          Positioned(
            left: 10,
            right: 10,
            bottom: 8,
            child: GestureDetector(
              onTap: () => _showPageParagraphPickerModal(_currentPdfPage),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFF151310).withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isOnSyncedPage
                        ? const Color(0xFFF5A623)
                        : Colors.white24,
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.65),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isOnSyncedPage
                                    ? Icons.graphic_eq_rounded
                                    : Icons.menu_book_rounded,
                                size: 14,
                                color: const Color(0xFFF5A623),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  isOnSyncedPage
                                      ? 'Narrando en vivo (Pág. ${_currentPdfPage + 1} • Párr. ${_liveAudioSegmentIndex + 1}/${max(1, liveAudioCh.segments.length)}):'
                                      : 'Pág. ${_currentPdfPage + 1} (${pageChapterInfo.chapter.title}) • Tocá para elegir párrafo:',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFF5A623),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            cardSnippet,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              height: 1.28,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!isOnSyncedPage)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFF5A623),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          minimumSize: Size.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _playAudioFromPdfPage(_currentPdfPage),
                        icon: const Icon(Icons.play_arrow_rounded, size: 16),
                        label: Text(
                          'Narrar Pág. ${_currentPdfPage + 1}',
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                        ),
                      )
                    else
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFF5A623),
                          side: const BorderSide(color: Color(0x66F5A623)),
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                          minimumSize: Size.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => _showPageParagraphPickerModal(_currentPdfPage),
                        icon: const Icon(Icons.format_list_numbered_rounded, size: 15),
                        label: const Text(
                          'Párrafos',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
                    _autoFollowAudio = true;
                  });
                  widget.onSeekToPosition?.call(_activeChapterIndex, sIdx);
                  ScaffoldMessenger.of(context).clearSnackBars();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '🔊 Narrando desde párrafo ${sIdx + 1}...',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
                      ),
                      duration: const Duration(milliseconds: 1400),
                      behavior: SnackBarBehavior.floating,
                      backgroundColor: const Color(0xFFF5A623),
                    ),
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: EdgeInsets.all(isCurrentAudioSegment ? 16 : 0),
                  decoration: BoxDecoration(
                    color: isCurrentAudioSegment
                        ? const Color(0xFF261E14).withValues(alpha: 0.95)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: isCurrentAudioSegment
                        ? Border.all(color: const Color(0xFFF5A623), width: 1.4)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isCurrentAudioSegment)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.volume_up_rounded, size: 16, color: Color(0xFFF5A623)),
                              SizedBox(width: 6),
                              Text(
                                'Narrando ahora en vivo (Tocá otro párrafo para saltar)',
                                style: TextStyle(
                                  color: Color(0xFFF5A623),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: _fontSize,
                          height: 1.68,
                          color: isCurrentAudioSegment
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.88),
                          fontWeight: isCurrentAudioSegment ? FontWeight.w500 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar(ChapterItem currentCh) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF16181D),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: _viewerMode == 0 && _totalPdfPages > 0
                  ? Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.chevron_left_rounded, color: Colors.white70),
                          onPressed: _currentPdfPage > 0
                              ? () => _pdfPageController?.previousPage(
                                    duration: const Duration(milliseconds: 220),
                                    curve: Curves.easeOut,
                                  )
                              : null,
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3.5,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                              activeTrackColor: const Color(0xFFF5A623),
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
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.chevron_right_rounded, color: Colors.white70),
                          onPressed: _currentPdfPage + 1 < _totalPdfPages
                              ? () => _pdfPageController?.nextPage(
                                    duration: const Duration(milliseconds: 220),
                                    curve: Curves.easeOut,
                                  )
                              : null,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white70),
                          onPressed: _activeChapterIndex > 0
                              ? () => setState(() => _activeChapterIndex--)
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            currentCh.title,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded, color: Colors.white70),
                          onPressed: _activeChapterIndex + 1 < widget.book.chapters.length
                              ? () => setState(() => _activeChapterIndex++)
                              : null,
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFF5A623),
                foregroundColor: Colors.black,
              ),
              icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: () {
                if (_isPlaying) {
                  NativeChannelService.pauseLoFi();
                  widget.player.pause();
                } else {
                  widget.player.play();
                  NativeChannelService.playLoFi();
                }
              },
            ),
          ],
        ),
      ),
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
                  final isCurrent = idx == _activeChapterIndex;
                  final isAudioHere = idx == _liveAudioChapterIndex;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 15,
                      backgroundColor:
                          isCurrent ? const Color(0xFFF5A623) : const Color(0xFF2C2D32),
                      child: Text(
                        ch.id.toString(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isCurrent ? Colors.black : Colors.white70,
                        ),
                      ),
                    ),
                    title: Text(
                      ch.title,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? const Color(0xFFF5A623) : Colors.white,
                      ),
                    ),
                    subtitle: Text(
                      isAudioHere
                          ? '🔊 Sonando acá • ${ch.subtitle} • ${ch.durationText}'
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
