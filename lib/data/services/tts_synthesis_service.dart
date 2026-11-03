import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:edge_tts/edge_tts.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../domain/models/chapter_item.dart';
import '../../domain/models/word_timing_item.dart';

/// Servicio dedicado a la síntesis neuronal Edge-TTS y caché de audio/palabras en disco
class TtsSynthesisService {
  final Map<String, List<WordTimingItem>> _segmentWordTimings = {};
  final Map<String, Future<File>> _inFlightSynthesis = {};

  static const Map<String, String> voicesMap = {
    'es-MX-JorgeNeural': 'Jorge HD (México 🇲🇽 • Cálido)',
    'es-AR-TomasNeural': 'Tomás HD (Argentina 🇦🇷 • Natural)',
    'es-AR-ElenaNeural': 'Elena HD (Argentina 🇦🇷 • Suave)',
    'es-ES-TristanMultilingualNeural': 'Tristán DragonHD (Multilingüe 🎙️)',
    'es-ES-XimenaMultilingualNeural': 'Ximena DragonHD (Multilingüe 🎙️)',
    'es-CO-GonzaloNeural': 'Gonzalo HD (Colombia 🇨🇴 • Narrador)',
    'es-ES-AlvaroNeural': 'Álvaro HD (España 🇪🇸 • Profundo)',
    'es-MX-DaliaNeural': 'Dalia HD (México 🇲🇽 • Clara)',
  };

  String segmentKeyId(String bookId, ChapterItem chapter, int segIdx, String voiceKey) {
    return '${bookId}_ch${chapter.id}_s${segIdx}_${voiceKey}_hd96';
  }

  List<WordTimingItem>? getWordTimings(
    String bookId,
    ChapterItem chapter,
    int segIdx,
    String voiceKey,
  ) {
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey);
    return _segmentWordTimings[key];
  }

  Future<File> _getSegmentFile(String key) async {
    final docDir = await getApplicationDocumentsDirectory();
    return File('${docDir.path}/$key.mp3');
  }

  Future<File> _getSegmentWordsFile(String key) async {
    final docDir = await getApplicationDocumentsDirectory();
    return File('${docDir.path}/$key.words.json');
  }

  Future<File> synthesizeSegment({
    required String bookId,
    required ChapterItem chapter,
    required int segIdx,
    required String text,
    required String voiceKey,
  }) {
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey);
    if (_inFlightSynthesis.containsKey(key)) {
      return _inFlightSynthesis[key]!;
    }

    final future = _doSynthesizeSegment(key, text, voiceKey).whenComplete(() {
      _inFlightSynthesis.remove(key);
    });
    _inFlightSynthesis[key] = future;
    return future;
  }

  Future<File> _doSynthesizeSegment(
    String key,
    String text,
    String voiceKey,
  ) async {
    final finalFile = await _getSegmentFile(key);
    final wordsFile = await _getSegmentWordsFile(key);

    if (await finalFile.exists() && await finalFile.length() > 800) {
      if (!_segmentWordTimings.containsKey(key) && await wordsFile.exists()) {
        try {
          final rawJson = await wordsFile.readAsString();
          final list = (jsonDecode(rawJson) as List)
              .map((e) => WordTimingItem.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          _segmentWordTimings[key] = list;
        } catch (_) {}
      }
      return finalFile;
    }

    final cleanSpeakText = TextSanitizer.humanizeTextForNaturalSpeech(text);
    final tempFile = File('${finalFile.path}.tmp');

    final tts = Communicate(
      text: cleanSpeakText,
      voice: voiceKey,
      rate: '-3%',
      pitch: '-2Hz',
      volume: '+0%',
      wordBoundary: true,
    );

    final audioBuilder = BytesBuilder(copy: false);
    final List<WordTimingItem> timings = [];

    await for (final event in tts.stream()) {
      if (event is AudioDataEvent) {
        audioBuilder.add(event.data);
      } else if (event is WordBoundaryEvent) {
        final int startMs = event.offset ~/ 10000;
        final int durMs = max(80, event.duration ~/ 10000);
        timings.add(
          WordTimingItem(
            startMs: startMs,
            endMs: startMs + durMs,
            word: event.text,
          ),
        );
      }
    }

    final bytes = audioBuilder.toBytes();
    if (bytes.length < 256) {
      throw Exception('Audio vacío recibido del servidor');
    }

    await tempFile.writeAsBytes(bytes, flush: true);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    final savedMp3 = await tempFile.rename(finalFile.path);

    if (timings.isNotEmpty) {
      _segmentWordTimings[key] = timings;
      try {
        await wordsFile.writeAsString(
          jsonEncode(timings.map((t) => t.toJson()).toList()),
          flush: true,
        );
      } catch (_) {}
    }

    return savedMp3;
  }
}
