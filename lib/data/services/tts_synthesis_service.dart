import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:edge_tts/edge_tts.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../domain/models/chapter_item.dart';
import '../../domain/models/word_timing_item.dart';

/// Servicio dedicado a la síntesis neuronal Edge-TTS y caché inteligente estilo YouTube Music.
/// Incluye timeouts estrictos para redes móviles (LTE/4G) inestables, reintentos automáticos
/// y memoria RAM acotada (LRU) para rendimiento fluido en celulares de gama baja y media.
class TtsSynthesisService {
  // Mapa LRU acotado a máximo 80 segmentos en RAM para no saturar celulares de gama baja/media
  final LinkedHashMap<String, List<WordTimingItem>> _segmentWordTimings =
      LinkedHashMap<String, List<WordTimingItem>>();
  final Map<String, Future<File>> _inFlightSynthesis = {};
  static bool _oldCachePurged = false;
  static String? _cachedDocDirPath;

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

  Future<String> _getDocDirPath() async {
    if (_cachedDocDirPath != null) return _cachedDocDirPath!;
    final dir = await getApplicationDocumentsDirectory();
    _cachedDocDirPath = dir.path;
    return _cachedDocDirPath!;
  }

  String segmentKeyId(String bookId, ChapterItem chapter, int segIdx, String voiceKey) {
    return '${bookId}_ch${chapter.id}_s${segIdx}_${voiceKey}_hd96_v3';
  }

  void _putTimingsInRamCache(String key, List<WordTimingItem> timings) {
    _segmentWordTimings.remove(key);
    _segmentWordTimings[key] = timings;
    while (_segmentWordTimings.length > 80) {
      _segmentWordTimings.remove(_segmentWordTimings.keys.first);
    }
  }

  /// Limpia de forma asíncrona (sin bloquear el hilo UI) los audios viejos (_hd96)
  Future<void> purgeLegacyCacheIfNeeded() async {
    if (_oldCachePurged) return;
    _oldCachePurged = true;
    try {
      final docPath = await _getDocDirPath();
      final docDir = Directory(docPath);
      if (!await docDir.exists()) return;
      await for (final entity in docDir.list()) {
        if (entity is File &&
            (entity.path.endsWith('_hd96.mp3') || entity.path.endsWith('_hd96.words.json'))) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
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

  Future<Directory> _getBookCacheDir(String bookId) async {
    final docPath = await _getDocDirPath();
    final dir = Directory('$docPath/tts_cache/$bookId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _getSegmentFile(String bookId, String key) async {
    final docPath = await _getDocDirPath();
    // Compatibilidad con segmentos ya guardados en docDir raíz y nueva carpeta organizada por libro
    final legacyFile = File('$docPath/$key.mp3');
    if (await legacyFile.exists()) return legacyFile;
    final bookDir = await _getBookCacheDir(bookId);
    return File('${bookDir.path}/$key.mp3');
  }

  Future<File> _getSegmentWordsFile(String bookId, String key) async {
    final docPath = await _getDocDirPath();
    final legacyWords = File('$docPath/$key.words.json');
    if (await legacyWords.exists()) return legacyWords;
    final bookDir = await _getBookCacheDir(bookId);
    return File('${bookDir.path}/$key.words.json');
  }

  /// Verifica rápido si este párrafo ya está descargado en la caché del celular (estilo YouTube Music)
  Future<bool> isSegmentCached({
    required String bookId,
    required ChapterItem chapter,
    required int segIdx,
    required String voiceKey,
  }) async {
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey);
    final file = await _getSegmentFile(bookId, key);
    return await file.exists() && await file.length() > 800;
  }

  Future<File> synthesizeSegment({
    required String bookId,
    required ChapterItem chapter,
    required int segIdx,
    required String text,
    required String voiceKey,
  }) {
    unawaited(purgeLegacyCacheIfNeeded());
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey);
    if (_inFlightSynthesis.containsKey(key)) {
      return _inFlightSynthesis[key]!;
    }

    final future = _doSynthesizeWithRetry(bookId, key, text, voiceKey).whenComplete(() {
      _inFlightSynthesis.remove(key);
    });
    _inFlightSynthesis[key] = future;
    return future;
  }

  Future<File> _doSynthesizeWithRetry(
    String bookId,
    String key,
    String text,
    String voiceKey,
  ) async {
    // 1. Si ya está en caché local en disco, devolver en 0ms sin tocar internet
    final finalFile = await _getSegmentFile(bookId, key);
    final wordsFile = await _getSegmentWordsFile(bookId, key);

    if (await finalFile.exists() && await finalFile.length() > 800) {
      if (!_segmentWordTimings.containsKey(key) && await wordsFile.exists()) {
        try {
          final rawJson = await wordsFile.readAsString();
          final list = (jsonDecode(rawJson) as List)
              .map((e) => WordTimingItem.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          _putTimingsInRamCache(key, list);
        } catch (_) {}
      }
      return finalFile;
    }

    // 2. Si no está en disco, descargar en streaming con timeout estricto (evita loading infinito en LTE inestable)
    Object? lastError;
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        return await _downloadSegmentFromEdgeTts(
          finalFile: finalFile,
          wordsFile: wordsFile,
          key: key,
          text: text,
          voiceKey: voiceKey,
        ).timeout(const Duration(seconds: 14));
      } catch (e) {
        lastError = e;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
      }
    }
    throw lastError ?? TimeoutException('Conexión inestable al sintetizar audio');
  }

  Future<File> _downloadSegmentFromEdgeTts({
    required File finalFile,
    required File wordsFile,
    required String key,
    required String text,
    required String voiceKey,
  }) async {
    final cleanSpeakText = TextSanitizer.humanizeTextForNaturalSpeech(text);
    final tempFile = File('${finalFile.path}.tmp');

    final tts = Communicate(
      text: cleanSpeakText,
      voice: voiceKey,
      rate: '-4%',
      pitch: '-2Hz',
      volume: '+0%',
      wordBoundary: true,
    );

    final audioBuilder = BytesBuilder(copy: false);
    final List<WordTimingItem> timings = [];

    // Timeout de 9 segundos entre paquetes del stream: si el 4G/LTE se corta en ruta, corta rápido para poder reintentar
    await for (final event in tts.stream().timeout(const Duration(seconds: 9))) {
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
      throw Exception('Audio incompleto recibido de la red');
    }

    await tempFile.writeAsBytes(bytes, flush: true);
    if (await finalFile.exists()) {
      await finalFile.delete();
    }
    final savedMp3 = await tempFile.rename(finalFile.path);

    if (timings.isNotEmpty) {
      _putTimingsInRamCache(key, timings);
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
