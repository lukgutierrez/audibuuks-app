import 'dart:math';

class ChapterItem {
  final int id;
  final String title;
  final String subtitle;
  final String durationText;
  final String textContent;
  String? localAudioPath;

  ChapterItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.durationText,
    required this.textContent,
    this.localAudioPath,
  });

  int get estimatedTotalSeconds {
    final words = textContent.split(RegExp(r'\s+')).length;
    return max(15, ((words / 140.0) * 60).round());
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'durationText': durationText,
        'textContent': textContent,
        'localAudioPath': localAudioPath,
      };

  factory ChapterItem.fromJson(Map<String, dynamic> json) => ChapterItem(
        id: json['id'] as int,
        title: json['title'] as String,
        subtitle: json['subtitle'] as String,
        durationText: json['durationText'] as String,
        textContent: json['textContent'] as String,
        localAudioPath: json['localAudioPath'] as String?,
      );
}
