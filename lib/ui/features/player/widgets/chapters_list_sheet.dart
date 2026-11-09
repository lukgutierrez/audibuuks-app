import 'package:flutter/material.dart';
import '../../../../data/services/offline_download_service.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';

class ChaptersListSheet extends StatefulWidget {
  final BookItem book;
  final ChapterItem currentChapter;
  final int currentSegmentIndex;
  final int totalSegmentsInCurrentChapter;
  final int bookPercent;
  final String selectedVoiceKey;
  final OfflineDownloadService downloadService;
  final ValueChanged<ChapterItem> onSelectChapter;
  final void Function(ChapterItem chapter, VoidCallback onNoteSaved) onOpenChapterNote;

  const ChaptersListSheet({
    super.key,
    required this.book,
    required this.currentChapter,
    required this.currentSegmentIndex,
    required this.totalSegmentsInCurrentChapter,
    required this.bookPercent,
    required this.selectedVoiceKey,
    required this.downloadService,
    required this.onSelectChapter,
    required this.onOpenChapterNote,
  });

  @override
  State<ChaptersListSheet> createState() => _ChaptersListSheetState();
}

class _ChaptersListSheetState extends State<ChaptersListSheet> {
  String _cleanNotePreview(String raw) {
    return raw
        .replaceAll('**', '')
        .replaceAll('__', '')
        .replaceAll(RegExp(r'^#\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final currentChIdx = widget.book.chapters
        .indexWhere((c) => c.id == widget.currentChapter.id);
    final int notesCount =
        widget.book.chapters.where((c) => c.hasNote).length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.76,
      minChildSize: 0.45,
      maxChildSize: 0.94,
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Capítulos (${widget.book.chapters.length})',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                    ),
                    if (notesCount > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5A623).withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFFF5A623).withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.sticky_note_2_rounded,
                              size: 13,
                              color: Color(0xFFF5A623),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$notesCount ${notesCount == 1 ? 'nota' : 'notas'}',
                              style: const TextStyle(
                                color: Color(0xFFF5A623),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: widget.downloadService,
                      builder: (ctx, _) {
                        final bookDl = widget.downloadService.getBookDownloadProgress(widget.book.id);
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
                              widget.downloadService.cancelDownload(widget.book.id, -1);
                            } else {
                              widget.downloadService.downloadEntireBook(
                                book: widget.book,
                                voiceKey: widget.selectedVoiceKey,
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
                        '${widget.bookPercent}%',
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
              final isCurrent = widget.currentChapter.id == ch.id;
              final isCompleted = currentChIdx != -1 && idx < currentChIdx;
              final double chProgress = isCurrent
                  ? (widget.totalSegmentsInCurrentChapter <= 0
                      ? 0.0
                      : ((widget.currentSegmentIndex + 1) / widget.totalSegmentsInCurrentChapter).clamp(0.0, 1.0))
                  : (isCompleted ? 1.0 : 0.0);
              final bool hasNote = ch.hasNote;

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: isCurrent
                      ? const Color(0xFFF5A623).withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isCurrent
                        ? const Color(0xFFF5A623).withValues(alpha: 0.5)
                        : (hasNote
                            ? const Color(0xFFF5A623).withValues(alpha: 0.28)
                            : Colors.white10),
                  ),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                            ? 'En curso • Párrafo ${widget.currentSegmentIndex + 1} de ${widget.totalSegmentsInCurrentChapter} (${(chProgress * 100).round()}%)'
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
                      const SizedBox(height: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          widget.onOpenChapterNote(
                            ch,
                            () {
                              if (mounted) {
                                setState(() {});
                              }
                            },
                          );
                        },
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: hasNote ? 7 : 5,
                          ),
                          decoration: BoxDecoration(
                            color: hasNote
                                ? const Color(0xFFF5A623).withValues(alpha: 0.16)
                                : Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: hasNote
                                  ? const Color(0xFFF5A623).withValues(alpha: 0.55)
                                  : Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          child: hasNote
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      ch.isNotePinned
                                          ? Icons.push_pin_rounded
                                          : Icons.sticky_note_2_rounded,
                                      size: 15,
                                      color: const Color(0xFFF5A623),
                                    ),
                                    const SizedBox(width: 7),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (ch.noteTitle != null &&
                                              ch.noteTitle!.trim().isNotEmpty &&
                                              ch.noteTitle!.trim() != ch.title.trim())
                                            Text(
                                              ch.noteTitle!.trim(),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Color(0xFFF5A623),
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          Text(
                                            _cleanNotePreview(ch.noteContent ?? ''),
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
                                    const SizedBox(width: 6),
                                    const Icon(
                                      Icons.edit_outlined,
                                      size: 14,
                                      color: Color(0xFFF5A623),
                                    ),
                                  ],
                                )
                              : const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.edit_note_rounded,
                                      size: 16,
                                      color: Color(0xFFF5A623),
                                    ),
                                    SizedBox(width: 5),
                                    Text(
                                      '+ Nota de sección',
                                      style: TextStyle(
                                        color: Color(0xFFF5A623),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                  trailing: AnimatedBuilder(
                    animation: widget.downloadService,
                    builder: (ctx, _) {
                      final p = widget.downloadService.getProgress(widget.book.id, ch.id);
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
                              future: widget.downloadService.isChapterFullyDownloaded(
                                bookId: widget.book.id,
                                chapter: ch,
                                voiceKey: widget.selectedVoiceKey,
                                language: widget.book.activeAudioLanguage,
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
                                      await widget.downloadService.deleteChapterDownload(
                                        bookId: widget.book.id,
                                        chapter: ch,
                                        voiceKey: widget.selectedVoiceKey,
                                        language: widget.book.activeAudioLanguage,
                                      );
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('Descarga eliminada: ${ch.title}'),
                                            backgroundColor: Colors.white12,
                                            behavior: SnackBarBehavior.floating,
                                            duration: const Duration(seconds: 1),
                                          ),
                                        );
                                      }
                                    } else {
                                      widget.downloadService.downloadChapter(
                                        bookId: widget.book.id,
                                        chapter: ch,
                                        voiceKey: widget.selectedVoiceKey,
                                        language: widget.book.activeAudioLanguage,
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
                    widget.onSelectChapter(ch);
                  },
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
