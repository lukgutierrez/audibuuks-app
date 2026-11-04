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

  PageController? _pdfPageController;
  int _currentPdfPage = 0;
  int _totalPdfPages = 0;
  int _audioSyncedPdfPage = 0;
  final Map<int, Uint8List> _pdfPageCache = {};
  bool _hasLocalPdf = false;
  bool _isLoadingPdfPage = false;

  StreamSubscription<PlayerState>? _playerSub;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _activeChapterIndex = widget.initialChapterIndex.clamp(
      0,
      max<int>(0, widget.book.chapters.length - 1),
    );
    _hasLocalPdf = widget.book.originalFilePath != null &&
        widget.book.originalFilePath!.toLowerCase().endsWith('.pdf') &&
        File(widget.book.originalFilePath!).existsSync();

    // Por defecto abrimos en Modo PDF Original (0) a menos que sea explícitamente un EPUB
    _viewerMode = (widget.book.fileType == 'epub') ? 1 : 0;

    _isPlaying = widget.player.playing;
    _playerSub = widget.player.playerStateStream.listen((state) {
      if (mounted) setState(() => _isPlaying = state.playing);
    });

    if (_hasLocalPdf) {
      _initPdfRenderer();
    } else if (widget.book.fileType != 'epub') {
      _tryAutoLocatePdfOnDevice();
    }
  }

  @override
  void dispose() {
    _playerSub?.cancel();
    _pdfPageController?.dispose();
    super.dispose();
  }

  /// Extrae el rango de páginas reales [startPageZeroBased, endPageZeroBased] del subtítulo del capítulo ("Págs. 12-23")
  List<int>? _parseChapterPageRange(ChapterItem ch) {
    final m = RegExp(r'Págs?\.\s*(\d+)(?:\s*-\s*(\d+))?', caseSensitive: false)
        .firstMatch(ch.subtitle);
    if (m == null) return null;
    final start = (int.tryParse(m.group(1) ?? '') ?? 1) - 1;
    final end = (int.tryParse(m.group(2) ?? m.group(1) ?? '') ?? (start + 1)) - 1;
    return [max(0, start), max(0, end)];
  }

  /// Calcula la página exacta del PDF donde está hablando el narrador ahora mismo
  int _calculateExactAudioPdfPage(int totalPages) {
    if (totalPages <= 0) return 0;
    final chIdx = widget.book.lastChapterIndex.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];

    final segIdx = widget.activeSegmentIndex ?? widget.book.lastSegmentIndex;
    final totalSegs = max(
      1,
      widget.totalSegmentsInChapter ??
          (widget.book.totalSegmentsInLastChapter > 0
              ? widget.book.totalSegmentsInLastChapter
              : ch.segments.length),
    );
    final segRatio = (segIdx / max(1, totalSegs - 1)).clamp(0.0, 1.0);

    final range = _parseChapterPageRange(ch);
    if (range != null) {
      final startP = range[0].clamp(0, totalPages - 1);
      final endP = range[1].clamp(startP, totalPages - 1);
      final exactP = startP + (segRatio * (endP - startP)).round();
      return exactP.clamp(0, totalPages - 1);
    }

    // Fallback proporcional si el capítulo no tenía rango explícito
    final bookRatio =
        (chIdx + segRatio) / max(1, widget.book.chapters.length);
    return (bookRatio * (totalPages - 1)).round().clamp(0, totalPages - 1);
  }

  /// Dado un número de página del PDF (0-based), encuentra el capítulo y párrafo correspondiente para narrar desde ahí
  void _playAudioFromCurrentPdfPage() {
    if (_totalPdfPages <= 0) return;
    final targetPage = _currentPdfPage;

    for (int i = 0; i < widget.book.chapters.length; i++) {
      final ch = widget.book.chapters[i];
      final range = _parseChapterPageRange(ch);
      if (range != null && targetPage >= range[0] && targetPage <= range[1]) {
        final pageSpan = max(1, range[1] - range[0] + 1);
        final pageOffsetRatio = ((targetPage - range[0]) / pageSpan).clamp(0.0, 0.95);
        final segs = ch.segments;
        final targetSeg =
            (pageOffsetRatio * segs.length).floor().clamp(0, max<int>(0, segs.length - 1));

        widget.onSeekToPosition?.call(i, targetSeg);
        setState(() {
          _activeChapterIndex = i;
          _audioSyncedPdfPage = targetPage;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Narrando desde Pág. ${targetPage + 1} (${ch.title}, párr. ${targetSeg + 1})',
            ),
            backgroundColor: const Color(0xFFF5A623),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }
    }

    // Si no encontró por etiqueta de página, buscar proporcionalmente
    final ratio = targetPage / max(1, _totalPdfPages - 1);
    final chIdx = (ratio * widget.book.chapters.length)
        .floor()
        .clamp(0, widget.book.chapters.length - 1);
    widget.onSeekToPosition?.call(chIdx, 0);
    setState(() {
      _activeChapterIndex = chIdx;
      _audioSyncedPdfPage = targetPage;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Narrando desde Pág. ${targetPage + 1} (${widget.book.chapters[chIdx].title})'),
        backgroundColor: const Color(0xFFF5A623),
        behavior: SnackBarBehavior.floating,
      ),
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

    final res = await NativeChannelService.renderPdfPage(path, 0, width: 1200);
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
    final res = await NativeChannelService.renderPdfPage(path, pageIndex, width: 1200);
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
            widget.book.lastChapterIndex.clamp(0, widget.book.chapters.length - 1);
      });
    }
  }

  String _getCurrentAudioSnippetText() {
    if (widget.currentSpokenSnippet != null && widget.currentSpokenSnippet!.isNotEmpty) {
      return widget.currentSpokenSnippet!;
    }
    final chIdx = widget.book.lastChapterIndex.clamp(0, widget.book.chapters.length - 1);
    final ch = widget.book.chapters[chIdx];
    final segs = ch.segments;
    if (segs.isEmpty) return ch.title;
    final sIdx = (widget.activeSegmentIndex ?? widget.book.lastSegmentIndex)
        .clamp(0, segs.length - 1);
    return segs[sIdx];
  }

  @override
  Widget build(BuildContext context) {
    final currentCh = widget.book.chapters[_activeChapterIndex];
    final audioCh = widget.book.chapters[
        widget.book.lastChapterIndex.clamp(0, widget.book.chapters.length - 1)];

    return Scaffold(
      backgroundColor: const Color(0xFF121316),
      appBar: AppBar(
        backgroundColor: const Color(0xFF191B20),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            Text(
              _viewerMode == 0 && _totalPdfPages > 0
                  ? 'PDF Original • Pág. ${_currentPdfPage + 1} de $_totalPdfPages'
                  : currentCh.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFF5A623), fontSize: 11.5),
            ),
          ],
        ),
        actions: [
          // Selector siempre visible: PDF Original vs Texto
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
            tooltip: 'Seleccionar capítulo',
            onPressed: _showChapterSelector,
          ),
        ],
      ),
      body: Column(
        children: [
          // Barra superior de sincronización exacta Audio <-> Página PDF
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF221C14),
              border: Border(bottom: BorderSide(color: Color(0x44F5A623))),
            ),
            child: Row(
              children: [
                const Icon(Icons.graphic_eq_rounded, size: 18, color: Color(0xFFF5A623)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _viewerMode == 0 && _totalPdfPages > 0
                        ? 'Audio en Pág. ${_audioSyncedPdfPage + 1} • ${audioCh.title}'
                        : 'Audio en: ${audioCh.title} (Párr. ${widget.book.lastSegmentIndex + 1})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF5A623).withValues(alpha: 0.2),
                    foregroundColor: const Color(0xFFF5A623),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _jumpToAudioPosition,
                  icon: const Icon(Icons.my_location_rounded, size: 14),
                  label: Text(
                    _viewerMode == 0 && _totalPdfPages > 0
                        ? 'Ir a Pág. ${_audioSyncedPdfPage + 1}'
                        : 'Ir al audio',
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
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
          _buildBottomBar(currentCh),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF5A623) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: selected ? Colors.black : Colors.white70),
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

    final bool isOnSyncedPage = (_currentPdfPage - _audioSyncedPdfPage).abs() <= 1;
    final String snippet = _getCurrentAudioSnippetText();

    return Stack(
      children: [
        PageView.builder(
          controller: _pdfPageController,
          itemCount: _totalPdfPages,
          onPageChanged: (pageIdx) {
            setState(() => _currentPdfPage = pageIdx);
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
                  padding: const EdgeInsets.fromLTRB(6, 6, 6, 86),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        // Tarjeta flotante inferior que muestra exactamente qué frase está leyendo el narrador en esta página
        Positioned(
          left: 12,
          right: 12,
          bottom: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF171410).withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isOnSyncedPage
                    ? const Color(0xFFF5A623)
                    : Colors.white24,
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
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
                                ? Icons.subtitles_rounded
                                : Icons.touch_app_rounded,
                            size: 14,
                            color: const Color(0xFFF5A623),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            isOnSyncedPage
                                ? 'Narrando en esta sección (Pág. ${_currentPdfPage + 1}):'
                                : 'Estás viendo la Pág. ${_currentPdfPage + 1} (Audio en Pág. ${_audioSyncedPdfPage + 1})',
                            style: const TextStyle(
                              color: Color(0xFFF5A623),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF5A623),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _playAudioFromCurrentPdfPage,
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text(
                    'Leer esta pág.',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextReader(ChapterItem chapter) {
    final segments = chapter.segments;
    final isSameChapterAsAudio = widget.book.lastChapterIndex == _activeChapterIndex;
    final activeSeg = widget.activeSegmentIndex ?? widget.book.lastSegmentIndex;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: const Color(0xFF16181D),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${segments.length} fragmentos • ${chapter.subtitle}',
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
            itemCount: segments.length,
            itemBuilder: (context, sIdx) {
              final isCurrentAudioSegment = isSameChapterAsAudio && activeSeg == sIdx;
              final text = segments[sIdx];

              return GestureDetector(
                onTap: () {
                  widget.onSeekToPosition?.call(_activeChapterIndex, sIdx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Reproduciendo desde fragmento ${sIdx + 1}...'),
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
                                'Narrando este párrafo ahora (Tocá otro para saltar)',
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF191B20),
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
            const SizedBox(width: 8),
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
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
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
                      '${ch.subtitle} • ${ch.durationText}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
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
