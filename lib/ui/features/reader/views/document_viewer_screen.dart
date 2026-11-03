import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../../../data/services/native_channel_service.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';

class DocumentViewerScreen extends StatefulWidget {
  final BookItem book;
  final AudioPlayer player;
  final int initialChapterIndex;
  final Function(int chapterIndex, int segmentIndex)? onSeekToPosition;

  const DocumentViewerScreen({
    super.key,
    required this.book,
    required this.player,
    this.initialChapterIndex = 0,
    this.onSeekToPosition,
  });

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late int _viewerMode; // 0 = PDF Original, 1 = Modo Lectura Texto / EPUB
  late int _activeChapterIndex;
  double _fontSize = 17.5;

  PageController? _pdfPageController;
  int _currentPdfPage = 0;
  int _totalPdfPages = 0;
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
    _hasLocalPdf = widget.book.fileType == 'pdf' &&
        widget.book.originalFilePath != null &&
        File(widget.book.originalFilePath!).existsSync();
    _viewerMode = _hasLocalPdf ? 0 : 1;

    _isPlaying = widget.player.playing;
    _playerSub = widget.player.playerStateStream.listen((state) {
      if (mounted) setState(() => _isPlaying = state.playing);
    });

    if (_hasLocalPdf) {
      _initPdfRenderer();
    }
  }

  @override
  void dispose() {
    _playerSub?.cancel();
    _pdfPageController?.dispose();
    super.dispose();
  }

  Future<void> _initPdfRenderer() async {
    final path = widget.book.originalFilePath!;
    setState(() => _isLoadingPdfPage = true);
    final res = await NativeChannelService.renderPdfPage(path, 0, width: 1080);
    if (res != null && mounted) {
      final total = (res['pageCount'] as int?) ?? 1;
      final bytes = res['bytes'] as Uint8List?;
      setState(() {
        _totalPdfPages = total;
        _isLoadingPdfPage = false;
        if (bytes != null) _pdfPageCache[0] = bytes;
      });
      _pdfPageController = PageController(initialPage: 0);
      _preloadPdfPages([1, 2]);
    } else if (mounted) {
      setState(() {
        _isLoadingPdfPage = false;
        _viewerMode = 1; // Fallback to text mode
      });
    }
  }

  Future<void> _loadPdfPage(int pageIndex) async {
    if (_pdfPageCache.containsKey(pageIndex)) return;
    final path = widget.book.originalFilePath;
    if (path == null) return;
    final res = await NativeChannelService.renderPdfPage(path, pageIndex, width: 1080);
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

  void _jumpToAudioChapter() {
    if (_viewerMode == 0 && _totalPdfPages > 0) {
      final ratio = _activeChapterIndex / max(1, widget.book.chapters.length);
      final targetPage = (ratio * _totalPdfPages).round().clamp(0, _totalPdfPages - 1);
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

  @override
  Widget build(BuildContext context) {
    final currentCh = widget.book.chapters[_activeChapterIndex];

    return Scaffold(
      backgroundColor: const Color(0xFF121316),
      appBar: AppBar(
        backgroundColor: const Color(0xFF191B20),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Text(
              _viewerMode == 0
                  ? 'PDF Original • Pág. ${_currentPdfPage + 1} de $_totalPdfPages'
                  : currentCh.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFF5A623), fontSize: 12),
            ),
          ],
        ),
        actions: [
          if (_hasLocalPdf)
            IconButton(
              icon: Icon(
                _viewerMode == 0 ? Icons.menu_book_rounded : Icons.picture_as_pdf_rounded,
                color: const Color(0xFFF5A623),
              ),
              tooltip: _viewerMode == 0 ? 'Modo Lectura Texto' : 'Modo PDF Original',
              onPressed: () {
                setState(() {
                  _viewerMode = _viewerMode == 0 ? 1 : 0;
                });
              },
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            color: const Color(0xFF221C14),
            child: Row(
              children: [
                const Icon(Icons.headphones_rounded, size: 16, color: Color(0xFFF5A623)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Audio en: ${widget.book.chapters[widget.book.lastChapterIndex.clamp(0, widget.book.chapters.length - 1)].title}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _jumpToAudioChapter,
                  child: const Text(
                    'Ir a esta parte',
                    style: TextStyle(
                      color: Color(0xFFF5A623),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _viewerMode == 0 && _hasLocalPdf
                ? _buildPdfViewer()
                : _buildTextReader(currentCh),
          ),
          _buildBottomBar(currentCh),
        ],
      ),
    );
  }

  Widget _buildPdfViewer() {
    if (_totalPdfPages == 0 || _isLoadingPdfPage) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFF5A623)),
      );
    }

    return PageView.builder(
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
          maxScale: 4.5,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
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
    );
  }

  Widget _buildTextReader(ChapterItem chapter) {
    final paragraphs = chapter.textContent
        .split('\n\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    final isSameChapterAsAudio = widget.book.lastChapterIndex == _activeChapterIndex;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: const Color(0xFF16181D),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${paragraphs.length} párrafos • ${chapter.durationText}',
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
            itemCount: paragraphs.length,
            itemBuilder: (context, pIdx) {
              final isCurrentAudioSegment =
                  isSameChapterAsAudio && widget.book.lastSegmentIndex == pIdx;
              final text = paragraphs[pIdx];

              return GestureDetector(
                onTap: () {
                  widget.onSeekToPosition?.call(_activeChapterIndex, pIdx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Reproduciendo desde párrafo ${pIdx + 1}...'),
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
                                'Narrando este párrafo ahora',
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
                  ? SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
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
            const SizedBox(width: 12),
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
                  'Capítulos del libro',
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
                      ch.durationText,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _activeChapterIndex = idx);
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
