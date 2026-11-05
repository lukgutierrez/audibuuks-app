import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../data/repositories/library_repository.dart';
import '../../../../data/services/audio_player_service.dart';
import '../../../../data/services/book_translation_service.dart';
import '../../../../data/services/cover_service.dart';
import '../../../../data/services/epub_processor_service.dart';
import '../../../../data/services/native_channel_service.dart';
import '../../../../data/services/pdf_extractor_service.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';
import '../../player/views/player_screen.dart';
import '../../reader/views/document_viewer_screen.dart';
import '../widgets/book_card.dart';
import '../widgets/mini_player_bar.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WidgetsBindingObserver {
  final LibraryRepository _repository = LibraryRepository();

  int _activeFilter = 0;
  final List<String> _filters = ['Todos', 'Continuar', 'Terminados', 'Favoritos'];
  List<BookItem> _books = [];
  bool _isLoading = true;

  bool _isProcessingPdf = false;
  int _processingPercent = 0;
  String _processingStatus = '';
  String _processingDetail = '';

  ChapterItem? _currentPlayingChapter;
  BookItem? _currentPlayingBook;
  bool _isPlaying = false;
  bool _userRequestedPause = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativeChannelService.initLoFi();
    globalAudioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
        });
      }
      if (!state.playing || _userRequestedPause) {
        NativeChannelService.pauseLoFi();
      }
    });
    _loadStoredBooksAndLastSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      if (_currentPlayingBook != null) {
        _repository.saveBookProgressFast(_currentPlayingBook!);
      }
      if (!globalAudioPlayer.playing) {
        _userRequestedPause = true;
        NativeChannelService.pauseLoFi();
      }
    }
  }

  Future<void> _loadStoredBooksAndLastSession() async {
    _books = await _repository.loadBooks();
    final lastBookId = await _repository.getLastActiveBookId();

    if (lastBookId != null && _books.isNotEmpty) {
      final matchIdx = _books.indexWhere((b) => b.id == lastBookId);
      if (matchIdx != -1) {
        final b = _books[matchIdx];
        final chIdx = b.lastChapterIndex.clamp(0, b.chapters.length - 1);
        _currentPlayingBook = b;
        _currentPlayingChapter = b.chapters[chIdx];
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
    _resolveMissingCovers();
  }

  Future<void> _resolveMissingCovers() async {
    bool updated = false;
    final docDir = await getApplicationDocumentsDirectory();

    for (final book in _books) {
      final hasLocal = book.coverImagePath != null && File(book.coverImagePath!).existsSync();
      if (!hasLocal) {
        String? url = book.coverUrl;
        url ??= await CoverService.fetchOnlineCoverUrl(book.title);
        if (url != null && url.isNotEmpty) {
          book.coverUrl = url;
          try {
            final coverFile = File('${docDir.path}/cover_${book.id}.jpg');
            final client = HttpClient();
            final req = await client.getUrl(Uri.parse(url));
            final res = await req.close().timeout(const Duration(seconds: 5));
            if (res.statusCode == 200) {
              final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
              if (bytes.length > 1000) {
                await coverFile.writeAsBytes(bytes);
                book.coverImagePath = coverFile.path;
              }
            }
          } catch (_) {}
          updated = true;
        }
      }
    }

    if (updated && mounted) {
      setState(() {});
      await _saveBooks();
    }
  }

  Future<void> _saveBooks({String? activeBookId}) async {
    await _repository.saveBooks(_books, activeBookId: activeBookId);
  }

  Future<void> _pickAndProcessDocument() async {
    try {
      const typeGroup = XTypeGroup(
        label: 'Libros y Documentos (PDF, EPUB)',
        extensions: ['pdf', 'epub'],
        mimeTypes: ['application/pdf', 'application/epub+zip'],
      );

      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;

      final isEpub = file.name.toLowerCase().endsWith('.epub');
      final isPdf = file.name.toLowerCase().endsWith('.pdf');

      if (!isEpub && !isPdf) {
        throw Exception('Formato no soportado. Por favor selecciona un archivo PDF o EPUB.');
      }

      setState(() {
        _isProcessingPdf = true;
        _processingPercent = 2;
        _processingStatus = isEpub ? 'Abriendo archivo EPUB...' : 'Abriendo archivo PDF...';
        _processingDetail = 'Iniciando escaneo inteligente de capítulos';
      });

      final bookId = 'book_${DateTime.now().millisecondsSinceEpoch}';
      final docDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${docDir.path}/books');
      if (!await booksDir.exists()) await booksDir.create(recursive: true);

      final permanentFilePath = '${booksDir.path}/${bookId}_${file.name}';
      final bytes = await file.readAsBytes();
      await File(permanentFilePath).writeAsBytes(bytes, flush: true);

      BookItem newBook;

      if (isEpub) {
        final epubBook = await EpubProcessorService.processEpubFile(
          filePath: permanentFilePath,
          bookId: bookId,
          originalFileName: file.name,
          onProgress: (pct, status, detail) {
            if (mounted) {
              setState(() {
                _processingPercent = pct;
                _processingStatus = status;
                _processingDetail = detail;
              });
            }
          },
        );
        if (epubBook == null) {
          throw Exception('No se pudo procesar el contenido del libro EPUB.');
        }

        final sampleText = epubBook.chapters.take(3).map((c) => c.textContent).join(' ');
        final detectedLang = BookTranslationService.detectLanguage(sampleText);
        var finalChapters = List<ChapterItem>.from(epubBook.chapters);
        var activeLang = detectedLang;
        bool triggerBackgroundTranslation = false;

        if (detectedLang == 'en' && mounted) {
          final wantTranslate = await _askTranslateOrKeepOriginal();
          if (wantTranslate == true) {
            activeLang = 'es';
            // Traducir por adelantado el 50% de los capítulos en la pantalla de carga
            final initialTarget = max(1, (finalChapters.length * 0.50).ceil());
            for (int i = 0; i < initialTarget && i < finalChapters.length; i++) {
              final pct = 60 + (((i + 1) / initialTarget) * 35).round();
              if (mounted) {
                setState(() {
                  _processingPercent = pct.clamp(60, 95);
                  _processingStatus = 'Traduciendo al español: Cap. ${i + 1} de $initialTarget (50% del libro)...';
                  _processingDetail = '${finalChapters[i].title} • Listo para escuchar';
                });
              }
              final translated = await BookTranslationService.translateSingleChapter(finalChapters[i]);
              finalChapters[i] = translated;
            }
            triggerBackgroundTranslation = true;
          }
        }

        newBook = BookItem(
          id: epubBook.id,
          title: epubBook.title,
          author: epubBook.author,
          coverTag: activeLang == 'en' ? '🇺🇸' : epubBook.coverTag,
          totalTime: epubBook.totalTime,
          chapters: finalChapters,
          coverImagePath: epubBook.coverImagePath,
          coverUrl: epubBook.coverUrl,
          originalFilePath: epubBook.originalFilePath,
          fileType: 'epub',
          detectedLanguage: detectedLang,
          activeAudioLanguage: activeLang,
        );

        if (triggerBackgroundTranslation) {
          BookTranslationService.startBackgroundBookTranslation(newBook);
        }
      } else {
        String fileName = file.name;
        if (fileName.toLowerCase().endsWith('.pdf')) {
          fileName = fileName.substring(0, fileName.length - 4);
        }
        final bookTitle = CoverService.cleanSearchTitle(fileName);

        setState(() {
          _processingPercent = 5;
          _processingStatus = 'Extrayendo portada del libro...';
          _processingDetail = bookTitle;
        });

        final coverData = await CoverService.resolveCoverForPdf(
          bookId: bookId,
          bookTitle: bookTitle,
          pdfBytes: bytes,
        );

        final receivePort = ReceivePort();
        final completer = Completer<List<ChapterItem>>();

        receivePort.listen((message) {
          if (message is Map) {
            final type = message['type'];
            if (type == 'progress') {
              final int current = message['current'] as int;
              final int total = message['total'] as int;
              final int pct = message['percent'] as int;
              if (mounted) {
                setState(() {
                  _processingPercent = pct;
                  _processingStatus = 'Detectando capítulos y limpiando texto...';
                  _processingDetail = 'Página $current de $total ($pct%)';
                });
              }
            } else if (type == 'done') {
              final rawList = message['chapters'] as List;
              final chapters = rawList
                  .map((c) => ChapterItem.fromJson(Map<String, dynamic>.from(c as Map)))
                  .toList();
              receivePort.close();
              if (!completer.isCompleted) completer.complete(chapters);
            } else if (type == 'error') {
              receivePort.close();
              if (!completer.isCompleted) {
                completer.completeError(Exception(message['message']));
              }
            }
          }
        });

        await Isolate.spawn(
          PdfExtractorService.pdfExtractionIsolateEntry,
          PdfIsolatePayload(bytes, receivePort.sendPort),
        );

        final parsedChapters = await completer.future;

        if (parsedChapters.isEmpty) {
          throw Exception('No se pudo extraer texto seleccionable del PDF.');
        }

        // 1. Detectar idioma del libro
        final sampleText = parsedChapters.take(3).map((c) => c.textContent).join(' ');
        final detectedLang = BookTranslationService.detectLanguage(sampleText);

        var finalChapters = List<ChapterItem>.from(parsedChapters);
        String activeLang = detectedLang;
        bool triggerBackgroundTranslation = false;

        // 2. Si es inglés, preguntar al usuario si desea traducir al español o mantener en inglés
        if (detectedLang == 'en' && mounted) {
          final wantTranslate = await _askTranslateOrKeepOriginal();
          if (wantTranslate == true) {
            activeLang = 'es';
            // Traducir por adelantado el 50% de los capítulos en la pantalla de carga
            final initialTarget = max(1, (finalChapters.length * 0.50).ceil());
            for (int i = 0; i < initialTarget && i < finalChapters.length; i++) {
              final pct = 60 + (((i + 1) / initialTarget) * 35).round();
              if (mounted) {
                setState(() {
                  _processingPercent = pct.clamp(60, 95);
                  _processingStatus = 'Traduciendo al español: Cap. ${i + 1} de $initialTarget (50% del libro)...';
                  _processingDetail = '${finalChapters[i].title} • Listo para escuchar';
                });
              }
              final translated = await BookTranslationService.translateSingleChapter(finalChapters[i]);
              finalChapters[i] = translated;
            }
            triggerBackgroundTranslation = true;
          } else {
            activeLang = 'en';
          }
        }

        final int totalMins = finalChapters.fold<int>(
          0,
          (sum, ch) => sum + (ch.estimatedTotalSeconds ~/ 60),
        );
        final String totalTimeFormatted = totalMins >= 60
            ? '${totalMins ~/ 60} h ${totalMins % 60} min'
            : '$totalMins min';

        newBook = BookItem(
          id: bookId,
          title: bookTitle,
          author: 'Audiolibro Completo',
          coverTag: activeLang == 'en' ? '🇺🇸' : '📚',
          totalTime: totalTimeFormatted,
          chapters: finalChapters,
          coverImagePath: coverData['path'],
          coverUrl: coverData['url'],
          originalFilePath: permanentFilePath,
          fileType: 'pdf',
          detectedLanguage: detectedLang,
          activeAudioLanguage: activeLang,
        );

        if (triggerBackgroundTranslation) {
          BookTranslationService.startBackgroundBookTranslation(newBook);
        }
      }

      if (mounted) {
        setState(() {
          _processingPercent = 100;
          _processingStatus = '¡Completado al 100%!';
          _processingDetail = '${newBook.chapters.length} capítulos detectados y listos';
          _books.insert(0, newBook);
          _isProcessingPdf = false;
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));

      await _saveBooks(activeBookId: newBook.id);

      if (mounted && newBook.chapters.isNotEmpty) {
        _openPlayer(newBook, newBook.chapters.first, startSegment: 0, startPositionMs: 0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessingPdf = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al procesar libro: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<bool?> _askTranslateOrKeepOriginal() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Text('🌐 ', style: TextStyle(fontSize: 24)),
            Expanded(
              child: Text(
                'Libro en Inglés Detectado',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white),
              ),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hemos detectado que el texto original está en inglés. ¿Cómo deseas disfrutar este libro?',
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            SizedBox(height: 16),
            Text(
              '• Traducir a Español: Narración y texto en español con voces latinas/españolas.\n• Idioma Original (Inglés): Narración fluida en inglés con voces nativas de EE.UU./UK.',
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.3),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            child: const Text('🇺🇸 Mantener en Inglés'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEAA036),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            child: const Text('🇪🇸 Traducir a Español', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteBook(BookItem book) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 10),
            Text('¿Eliminar libro?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Text(
          '¿Seguro que deseas eliminar "${book.title}" de tu biblioteca? Se borrará el libro y los audios cacheados.',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteBook(book);
            },
            child: const Text('Eliminar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteBook(BookItem book) async {
    if (_currentPlayingBook?.id == book.id) {
      await globalAudioPlayer.stop();
      await NativeChannelService.pauseLoFi();
      setState(() {
        _currentPlayingBook = null;
        _currentPlayingChapter = null;
        _isPlaying = false;
        _userRequestedPause = true;
      });
    }

    setState(() {
      _books.removeWhere((b) => b.id == book.id);
    });
    await _saveBooks();
    await _repository.deleteBookFiles(book);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${book.title}" eliminado de tu biblioteca'),
          backgroundColor: const Color(0xFF2C2D32),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openDocumentViewer(BookItem book, {int? initialChapterIndex}) {
    final chIdx = (initialChapterIndex ?? book.lastChapterIndex)
        .clamp(0, max<int>(0, book.chapters.length - 1));
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentViewerScreen(
          book: book,
          player: globalAudioPlayer,
          initialChapterIndex: chIdx,
          activeSegmentIndex: book.lastSegmentIndex,
          totalSegmentsInChapter: book.totalSegmentsInLastChapter,
          onBookFileLinked: () {
            setState(() {});
            _saveBooks();
          },
          onSeekToPosition: (targetChIdx, segIdx) {
            if (targetChIdx < 0 || targetChIdx >= book.chapters.length) return;
            final targetChapter = book.chapters[targetChIdx];
            _openPlayer(book, targetChapter, startSegment: segIdx, startPositionMs: 0);
          },
        ),
      ),
    );
  }

  void _openPlayer(
    BookItem book,
    ChapterItem chapter, {
    int? startSegment,
    int? startPositionMs,
  }) {
    final chIdx =
        book.chapters.indexWhere((c) => c.id == chapter.id).clamp(0, book.chapters.length - 1);
    final bool isSameSavedChapter = chIdx == book.lastChapterIndex;
    final int segToStart = startSegment ?? (isSameSavedChapter ? book.lastSegmentIndex : 0);
    final int posMsToStart =
        startPositionMs ?? (isSameSavedChapter ? book.lastPositionMs : 0);

    setState(() {
      _currentPlayingBook = book;
      _currentPlayingChapter = chapter;
    });
    _repository.saveBookProgressFast(book);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          book: book,
          initialChapter: chapter,
          initialSegmentIndex: segToStart,
          initialPositionMs: posMsToStart,
          player: globalAudioPlayer,
          onProgressUpdated: (updatedChapter, segIdx, totalSegs, posMs) {
            final idx = book.chapters.indexWhere((c) => c.id == updatedChapter.id);
            final bool chapterOrSegChanged =
                idx != book.lastChapterIndex || segIdx != book.lastSegmentIndex;
            if (idx != -1) {
              book.lastChapterIndex = idx;
              book.lastSegmentIndex = segIdx;
              book.lastPositionMs = posMs;
              book.totalSegmentsInLastChapter = max(1, totalSegs);
            }
            _repository.saveBookProgressFast(book);
            if (chapterOrSegChanged) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _currentPlayingBook = book;
                    _currentPlayingChapter = updatedChapter;
                  });
                }
              });
            }
          },
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  List<BookItem> get _filteredBooks {
    if (_activeFilter == 1) {
      return _books.where((b) => b.hasStarted && !b.isCompleted).toList();
    } else if (_activeFilter == 2) {
      return _books.where((b) => b.isCompleted).toList();
    } else if (_activeFilter == 3) {
      return _books.where((b) => b.isFavorite).toList();
    }
    return _books;
  }

  @override
  Widget build(BuildContext context) {
    final visibleBooks = _filteredBooks;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Mi Biblioteca',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 25, letterSpacing: -0.5),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFF5A623),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _pickAndProcessDocument,
              icon: const Icon(Icons.add_circle_outline_rounded, size: 19),
              label: const Text(
                'Cargar PDF / EPUB',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: List.generate(_filters.length, (index) {
                    final isSelected = _activeFilter == index;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          _filters[index],
                          style: TextStyle(
                            color: isSelected ? Colors.black : Colors.white70,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: const Color(0xFFF5A623),
                        backgroundColor: const Color(0xFF1E1E1E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(
                            color: isSelected ? const Color(0xFFF5A623) : Colors.transparent,
                          ),
                        ),
                        onSelected: (val) {
                          setState(() => _activeFilter = index);
                        },
                      ),
                    );
                  }),
                ),
              ),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFF5A623)))
                    : visibleBooks.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.menu_book_rounded,
                                    size: 52, color: Colors.white24),
                                const SizedBox(height: 12),
                                const Text(
                                  'No hay libros en esta sección todavía',
                                  style: TextStyle(color: Colors.white54, fontSize: 15),
                                ),
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _pickAndProcessDocument,
                                  icon: const Icon(Icons.upload_file_rounded,
                                      color: Color(0xFFF5A623)),
                                  label: const Text(
                                    'Importar libro (PDF o EPUB)',
                                    style: TextStyle(color: Color(0xFFF5A623)),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                            itemCount: visibleBooks.length,
                            itemBuilder: (context, index) {
                              final book = visibleBooks[index];
                              final resumeChapIdx =
                                  book.lastChapterIndex.clamp(0, book.chapters.length - 1);
                              final targetChapter = book.chapters[resumeChapIdx];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: BookCard(
                                  book: book,
                                  onTap: () => _openPlayer(
                                    book,
                                    targetChapter,
                                    startSegment: book.lastSegmentIndex,
                                    startPositionMs: book.lastPositionMs,
                                  ),
                                  onToggleFavorite: () {
                                    setState(() => book.isFavorite = !book.isFavorite);
                                    _saveBooks();
                                  },
                                  onViewDocument: () => _openDocumentViewer(book),
                                  onDelete: () => _confirmDeleteBook(book),
                                ),
                              );
                            },
                          ),
              ),
              if (_currentPlayingChapter != null && _currentPlayingBook != null)
                MiniPlayerBar(
                  book: _currentPlayingBook!,
                  chapter: _currentPlayingChapter!,
                  isPlaying: _isPlaying,
                  onOpenPlayer: () => _openPlayer(
                    _currentPlayingBook!,
                    _currentPlayingChapter!,
                    startSegment: _currentPlayingBook!.lastSegmentIndex,
                    startPositionMs: _currentPlayingBook!.lastPositionMs,
                  ),
                  onTogglePlayPause: () {
                    if (globalAudioPlayer.audioSource == null) {
                      _openPlayer(
                        _currentPlayingBook!,
                        _currentPlayingChapter!,
                        startSegment: _currentPlayingBook!.lastSegmentIndex,
                        startPositionMs: _currentPlayingBook!.lastPositionMs,
                      );
                    } else if (_isPlaying) {
                      _userRequestedPause = true;
                      NativeChannelService.pauseLoFi();
                      globalAudioPlayer.pause();
                    } else {
                      _userRequestedPause = false;
                      globalAudioPlayer.play();
                      NativeChannelService.playLoFi();
                    }
                  },
                ),
            ],
          ),
          if (_isProcessingPdf)
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Center(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFF5A623), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF5A623).withValues(alpha: 0.15),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 84,
                            height: 84,
                            child: CircularProgressIndicator(
                              value: _processingPercent / 100.0,
                              color: const Color(0xFFF5A623),
                              backgroundColor: Colors.white12,
                              strokeWidth: 7,
                            ),
                          ),
                          Text(
                            '$_processingPercent%',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFFF5A623),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Text(
                        _processingStatus,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: _processingPercent / 100.0,
                          minHeight: 10,
                          color: const Color(0xFFF5A623),
                          backgroundColor: Colors.white12,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _processingDetail,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
