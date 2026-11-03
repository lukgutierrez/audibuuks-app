import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../../data/services/cover_service.dart';
import '../../../domain/models/book_item.dart';

class BookCoverWidget extends StatelessWidget {
  final BookItem book;
  final double width;
  final double height;
  final double borderRadius;

  const BookCoverWidget({
    super.key,
    required this.book,
    required this.width,
    required this.height,
    this.borderRadius = 12,
  });

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (book.coverImagePath != null && File(book.coverImagePath!).existsSync()) {
      content = Image.file(
        File(book.coverImagePath!),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildEditorialFallback(),
      );
    } else if (book.coverUrl != null && book.coverUrl!.isNotEmpty) {
      content = Image.network(
        book.coverUrl!,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildEditorialFallback(),
      );
    } else {
      content = _buildEditorialFallback();
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 22,
            spreadRadius: 2,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: content,
      ),
    );
  }

  Widget _buildEditorialFallback() {
    final cleanTitle = CoverService.cleanSearchTitle(book.title);
    return Container(
      width: width,
      height: height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF2C221E),
            Color(0xFF1A1412),
            Color(0xFF3A2818),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: max(4, width * 0.07),
            child: Container(
              color: const Color(0xFFF5A623).withValues(alpha: 0.7),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(max(8, width * 0.12), 8, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  cleanTitle.toUpperCase(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: const Color(0xFFF5A623),
                    fontWeight: FontWeight.w800,
                    fontSize: max(8, width * 0.11),
                    height: 1.15,
                  ),
                ),
                Text(
                  book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: max(7, width * 0.085),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
