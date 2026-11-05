import 'chapter_item.dart';

class BookItem {
  final String id;
  final String title;
  final String author;
  final String coverTag;
  final String totalTime;
  final List<ChapterItem> chapters;
  String? coverImagePath;
  String? coverUrl;
  String? originalFilePath;
  String? fileType; // 'pdf' | 'epub' | 'sample'
  String detectedLanguage; // 'es' | 'en'
  String activeAudioLanguage; // 'es' | 'en'

  // Progreso persistente exacto (capítulo, párrafo y milisegundo exacto)
  int lastChapterIndex;
  int lastSegmentIndex;
  int lastPositionMs;
  int totalSegmentsInLastChapter;
  bool isFavorite;

  int? _cachedBookTotalSeconds;

  BookItem({
    required this.id,
    required this.title,
    required this.author,
    required this.coverTag,
    required this.totalTime,
    required this.chapters,
    this.coverImagePath,
    this.coverUrl,
    this.originalFilePath,
    this.fileType = 'pdf',
    this.detectedLanguage = 'es',
    this.activeAudioLanguage = 'es',
    this.lastChapterIndex = 0,
    this.lastSegmentIndex = 0,
    this.lastPositionMs = 0,
    this.totalSegmentsInLastChapter = 1,
    this.isFavorite = false,
  });

  int get estimatedBookTotalSeconds {
    _cachedBookTotalSeconds ??=
        chapters.fold<int>(0, (sum, ch) => sum + ch.estimatedTotalSeconds);
    return _cachedBookTotalSeconds!;
  }

  double get overallProgress {
    if (chapters.isEmpty) return 0.0;
    final idx = lastChapterIndex.clamp(0, chapters.length - 1);
    final segFrac = totalSegmentsInLastChapter > 0
        ? (lastSegmentIndex / totalSegmentsInLastChapter).clamp(0.0, 1.0)
        : 0.0;
    final prog = (idx + segFrac) / chapters.length;
    return prog.clamp(0.0, 1.0);
  }

  bool get hasStarted =>
      lastChapterIndex > 0 || lastSegmentIndex > 0 || lastPositionMs > 2000;
  bool get isCompleted => overallProgress >= 0.96;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverTag': coverTag,
        'totalTime': totalTime,
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'coverImagePath': coverImagePath,
        'coverUrl': coverUrl,
        'originalFilePath': originalFilePath,
        'fileType': fileType,
        'detectedLanguage': detectedLanguage,
        'activeAudioLanguage': activeAudioLanguage,
        'lastChapterIndex': lastChapterIndex,
        'lastSegmentIndex': lastSegmentIndex,
        'lastPositionMs': lastPositionMs,
        'totalSegmentsInLastChapter': totalSegmentsInLastChapter,
        'isFavorite': isFavorite,
      };

  factory BookItem.fromJson(Map<String, dynamic> json) => BookItem(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String,
        coverTag: json['coverTag'] as String? ?? '📖',
        totalTime: json['totalTime'] as String,
        chapters: (json['chapters'] as List)
            .map((c) => ChapterItem.fromJson(c as Map<String, dynamic>))
            .toList(),
        coverImagePath: json['coverImagePath'] as String?,
        coverUrl: json['coverUrl'] as String?,
        originalFilePath: json['originalFilePath'] as String?,
        fileType: json['fileType'] as String? ?? 'pdf',
        detectedLanguage: json['detectedLanguage'] as String? ?? 'es',
        activeAudioLanguage: json['activeAudioLanguage'] as String? ?? 'es',
        lastChapterIndex: (json['lastChapterIndex'] as int?) ?? 0,
        lastSegmentIndex: (json['lastSegmentIndex'] as int?) ?? 0,
        lastPositionMs: (json['lastPositionMs'] as int?) ?? 0,
        totalSegmentsInLastChapter: (json['totalSegmentsInLastChapter'] as int?) ?? 1,
        isFavorite: (json['isFavorite'] as bool?) ?? false,
      );
}
