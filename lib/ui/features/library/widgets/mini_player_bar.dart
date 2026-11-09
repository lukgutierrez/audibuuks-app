import 'dart:math';
import 'package:flutter/material.dart';

import '../../../../data/services/audio_player_service.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';
import '../../../shared/widgets/book_cover_widget.dart';

class MiniPlayerBar extends StatelessWidget {
  final BookItem book;
  final ChapterItem chapter;
  final bool isPlaying;
  final VoidCallback onOpenPlayer;
  final VoidCallback onTogglePlayPause;

  const MiniPlayerBar({
    super.key,
    required this.book,
    required this.chapter,
    required this.isPlaying,
    required this.onOpenPlayer,
    required this.onTogglePlayPause,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: audioPlayerService,
      builder: (context, _) {
        final double bookProg = book.overallProgress;
        final int segIdx = book.lastSegmentIndex + 1;
        final int totalSegs = max(1, book.totalSegmentsInLastChapter);
        final bool timerActive = audioPlayerService.isSleepTimerActive;
        final String timerLabel = audioPlayerService.sleepTimerBadgeText;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpenPlayer,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF17181C),
              border: const Border(top: BorderSide(color: Color(0xFF2E3038))),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.65),
                  blurRadius: 16,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: max(0.02, bookProg),
                    minHeight: 3,
                    color: const Color(0xFFF5A623),
                    backgroundColor: Colors.white12,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        BookCoverWidget(
                          book: book,
                          width: 44,
                          height: 60,
                          borderRadius: 8,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      chapter.title,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (timerActive) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF5A623).withValues(alpha: 0.18),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: const Color(0xFFF5A623).withValues(alpha: 0.5),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.bedtime_rounded,
                                            size: 11,
                                            color: Color(0xFFF5A623),
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            timerLabel,
                                            style: const TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFFF5A623),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${book.title} • Párr. $segIdx/$totalSegs (${(bookProg * 100).round()}%)',
                                style: const TextStyle(color: Colors.white60, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_circle_filled_rounded
                                : Icons.play_circle_filled_rounded,
                            size: 42,
                            color: const Color(0xFFF5A623),
                          ),
                          onPressed: onTogglePlayPause,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
