class WordTimingItem {
  final int startMs;
  final int endMs;
  final String word;

  const WordTimingItem({
    required this.startMs,
    required this.endMs,
    required this.word,
  });

  Map<String, dynamic> toJson() => {
        's': startMs,
        'e': endMs,
        'w': word,
      };

  factory WordTimingItem.fromJson(Map<String, dynamic> json) => WordTimingItem(
        startMs: json['s'] as int,
        endMs: json['e'] as int,
        word: json['w'] as String,
      );
}
