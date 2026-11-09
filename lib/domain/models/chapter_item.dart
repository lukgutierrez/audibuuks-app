import 'dart:math';
import '../../core/utils/text_sanitizer.dart';

class ChapterItem {
  final int id;
  final String title;
  final String subtitle;
  final String durationText;
  final String textContent;
  String? localAudioPath;
  List<String>? originalLanguageSegments;
  String? noteTitle;
  String? noteContent;
  bool isNotePinned;
  int noteColorHex;
  int? noteUpdatedAtMs;

  int? _cachedEstimatedSeconds;
  List<String>? _cachedSegments;

  ChapterItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.durationText,
    required this.textContent,
    this.localAudioPath,
    this.originalLanguageSegments,
    this.noteTitle,
    this.noteContent,
    this.isNotePinned = false,
    this.noteColorHex = 0xFF141519,
    this.noteUpdatedAtMs,
  });

  bool get hasNote =>
      (noteContent != null && noteContent!.trim().isNotEmpty) ||
      (noteTitle != null &&
          noteTitle!.trim().isNotEmpty &&
          noteTitle!.trim() != title.trim());

  /// Calcula una única vez la duración estimada y la reutiliza en O(1) sin bloquear el hilo principal
  int get estimatedTotalSeconds {
    if (_cachedEstimatedSeconds != null) return _cachedEstimatedSeconds!;
    final words = textContent.split(RegExp(r'\s+')).length;
    _cachedEstimatedSeconds = max(15, ((words / 140.0) * 60).round());
    return _cachedEstimatedSeconds!;
  }

  /// Calcula una única vez los fragmentos del capítulo y los guarda en caché en memoria.
  /// Si se solicita idioma inglés y existen fragmentos originales, devuelve los fragmentos en inglés.
  List<String> getSegmentsForLanguage([String? lang]) {
    if (lang == 'en' && originalLanguageSegments != null && originalLanguageSegments!.isNotEmpty) {
      return originalLanguageSegments!;
    }
    if (_cachedSegments != null && _cachedSegments!.isNotEmpty) {
      return _cachedSegments!;
    }
    _cachedSegments = TextSanitizer.splitIntoSegments(textContent);
    return _cachedSegments!;
  }

  List<String> get segments => getSegmentsForLanguage('es');

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'durationText': durationText,
        'textContent': textContent,
        'localAudioPath': localAudioPath,
        'originalLanguageSegments': originalLanguageSegments,
        'noteTitle': noteTitle,
        'noteContent': noteContent,
        'isNotePinned': isNotePinned,
        'noteColorHex': noteColorHex,
        'noteUpdatedAtMs': noteUpdatedAtMs,
      };

  factory ChapterItem.fromJson(Map<String, dynamic> json) => ChapterItem(
        id: json['id'] as int,
        title: json['title'] as String,
        subtitle: json['subtitle'] as String,
        durationText: json['durationText'] as String,
        textContent: json['textContent'] as String,
        localAudioPath: json['localAudioPath'] as String?,
        originalLanguageSegments: (json['originalLanguageSegments'] as List?)
            ?.map((e) => e.toString())
            .toList(),
        noteTitle: json['noteTitle'] as String?,
        noteContent: json['noteContent'] as String?,
        isNotePinned: (json['isNotePinned'] as bool?) ?? false,
        noteColorHex: (json['noteColorHex'] as int?) ?? 0xFF141519,
        noteUpdatedAtMs: json['noteUpdatedAtMs'] as int?,
      );
}
