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
  });

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
    _cachedSegments ??= TextSanitizer.splitIntoSegments(textContent);
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
      );
}
