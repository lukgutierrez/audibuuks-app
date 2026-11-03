import 'dart:math';
import 'package:flutter/material.dart';

import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';
import '../../../shared/widgets/book_cover_widget.dart';

class BookCard extends StatelessWidget {
  final BookItem book;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onViewDocument;
  final VoidCallback onDelete;

  const BookCard({
    super.key,
    required this.book,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onViewDocument,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final int resumeChapIdx = book.lastChapterIndex.clamp(0, book.chapters.length - 1);
    final ChapterItem targetChapter = book.chapters[resumeChapIdx];
    final double prog = book.overallProgress;
    final int pct = (prog * 100).round();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1B1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: book.hasStarted
              ? const Color(0xFFF5A623).withValues(alpha: 0.35)
              : const Color(0xFF2C2C2C),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    BookCoverWidget(
                      book: book,
                      width: 70,
                      height: 102,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  book.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    height: 1.2,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              GestureDetector(
                                onTap: onToggleFavorite,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(
                                    book.isFavorite
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                    size: 20,
                                    color: book.isFavorite
                                        ? const Color(0xFFF5A623)
                                        : Colors.white38,
                                  ),
                                ),
                              ),
                              PopupMenuButton<String>(
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  Icons.more_vert_rounded,
                                  size: 20,
                                  color: Colors.white54,
                                ),
                                color: const Color(0xFF22242A),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  side: const BorderSide(color: Colors.white12),
                                ),
                                onSelected: (val) {
                                  if (val == 'view') {
                                    onViewDocument();
                                  } else if (val == 'delete') {
                                    onDelete();
                                  }
                                },
                                itemBuilder: (ctx) => [
                                  PopupMenuItem(
                                    value: 'view',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.auto_stories_rounded,
                                            color: Color(0xFFF5A623), size: 18),
                                        const SizedBox(width: 10),
                                        Text(
                                          book.fileType == 'epub'
                                              ? 'Ver / Leer EPUB'
                                              : 'Ver / Leer PDF',
                                          style: const TextStyle(fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_outline_rounded,
                                            color: Colors.redAccent, size: 18),
                                        SizedBox(width: 10),
                                        Text(
                                          'Eliminar libro',
                                          style: TextStyle(
                                              color: Colors.redAccent, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            book.author,
                            style: const TextStyle(color: Colors.white60, fontSize: 12.5),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF5A623).withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${book.chapters.length} caps',
                                  style: const TextStyle(
                                    color: Color(0xFFF5A623),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Icon(Icons.schedule, size: 14, color: Colors.white38),
                              const SizedBox(width: 4),
                              Text(
                                book.totalTime,
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.play_circle_fill_rounded,
                        size: 46,
                        color: Color(0xFFF5A623),
                      ),
                      tooltip: book.hasStarted ? 'Continuar audiolibro' : 'Reproducir audiolibro',
                      onPressed: onTap,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: max(0.02, prog),
                    minHeight: 5,
                    color: const Color(0xFFF5A623),
                    backgroundColor: Colors.white10,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        book.hasStarted
                            ? 'Retomar: ${targetChapter.title} (Párr. ${book.lastSegmentIndex + 1})'
                            : 'Listo para escuchar (${book.totalTime})',
                        style: TextStyle(
                          color: book.hasStarted ? Colors.white70 : Colors.white38,
                          fontSize: 11.5,
                          fontWeight: book.hasStarted ? FontWeight.w600 : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$pct% completado',
                      style: const TextStyle(
                        color: Color(0xFFF5A623),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
