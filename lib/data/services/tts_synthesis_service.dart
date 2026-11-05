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

/// Servicio Singleton dedicado a la síntesis neuronal Edge-TTS y caché inteligente estilo YouTube Music.
/// Comparte en memoria los tiempos palabra por palabra entre el Reproductor y el Visor PDF en vivo.
class TtsSynthesisService {
  static final TtsSynthesisService _instance = TtsSynthesisService._internal();
  factory TtsSynthesisService() => _instance;
  TtsSynthesisService._internal();

  // Mapa LRU acotado a máximo 100 segmentos en RAM para compartir timings instantáneamente con el PDF en vivo
  final LinkedHashMap<String, List<WordTimingItem>> _segmentWordTimings =
      LinkedHashMap<String, List<WordTimingItem>>();
  final Map<String, Future<File>> _inFlightSynthesis = {};
  static bool _oldCachePurged = false;
  static String? _cachedDocDirPath;

  static const Map<String, String> voicesMap = {
    // Español
    'es-MX-JorgeNeural': 'Jorge HD (México 🇲🇽 • Cálido)',
    'es-AR-TomasNeural': 'Tomás HD (Argentina 🇦🇷 • Natural)',
    'es-AR-ElenaNeural': 'Elena HD (Argentina 🇦🇷 • Suave)',
    'es-ES-TristanMultilingualNeural': 'Tristán DragonHD (Multilingüe 🎙️)',
    'es-ES-XimenaMultilingualNeural': 'Ximena DragonHD (Multilingüe 🎙️)',
    'es-CO-GonzaloNeural': 'Gonzalo HD (Colombia 🇨🇴 • Narrador)',
    'es-ES-AlvaroNeural': 'Álvaro HD (España 🇪🇸 • Profundo)',
    'es-MX-DaliaNeural': 'Dalia HD (México 🇲🇽 • Clara)',
    // Inglés (English Neuronal HD)
    'en-US-GuyNeural': 'Guy HD (EE. UU. 🇺🇸 • Cálido y narrativo)',
    'en-US-AriaNeural': 'Aria HD (EE. UU. 🇺🇸 • Clara y expresiva)',
    'en-US-ChristopherNeural': 'Christopher HD (EE. UU. 🇺🇸 • Profundo)',
    'en-GB-RyanNeural': 'Ryan HD (Reino Unido 🇬🇧 • Elegante británico)',
    'en-GB-SoniaNeural': 'Sonia HD (Reino Unido 🇬🇧 • Suave)',
  };

  Future<String> _getDocDirPath() async {
    if (_cachedDocDirPath != null) return _cachedDocDirPath!;
    final dir = await getApplicationDocumentsDirectory();
    _cachedDocDirPath = dir.path;
    return _cachedDocDirPath!;
  }

  String segmentKeyId(String bookId, ChapterItem chapter, int segIdx, String voiceKey, {String? text}) {
    // Si se pasa el texto del segmento, incluir un hash de los primeros 40 caracteres normalizados
    // para evitar reproducir audios cacheados del idioma anterior (por ejemplo, inglés antes de traducir a español).
    final textHash = (text != null && text.trim().isNotEmpty)
        ? '_h${text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase().hashCode.abs().toRadixString(16)}'
        : '';
    final langTag = voiceKey.startsWith('en-') ? 'en' : 'es';
    return '${bookId}_ch${chapter.id}_s${segIdx}_${voiceKey}_${langTag}$textHash\_hd96_v4';
  }

  void _putTimingsInRamCache(String key, List<WordTimingItem> timings) {
    _segmentWordTimings.remove(key);
    _segmentWordTimings[key] = timings;
    while (_segmentWordTimings.length > 100) {
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
    String voiceKey, {
    String? text,
  }) {
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey, text: text);
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

  Future<File> getSegmentFilePublic(String bookId, String key) => _getSegmentFile(bookId, key);
  Future<File> getSegmentWordsFilePublic(String bookId, String key) => _getSegmentWordsFile(bookId, key);

  /// Verifica rápido si este párrafo ya está descargado en la caché del celular (estilo YouTube Music)
  Future<bool> isSegmentCached({
    required String bookId,
    required ChapterItem chapter,
    required int segIdx,
    required String voiceKey,
    String? text,
  }) async {
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey, text: text);
    final file = await _getSegmentFile(bookId, key);
    return await file.exists() && await file.length() > 400;
  }

  Future<File> synthesizeSegment({
    required String bookId,
    required ChapterItem chapter,
    required int segIdx,
    required String text,
    required String voiceKey,
  }) {
    unawaited(purgeLegacyCacheIfNeeded());
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey, text: text);
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

    if (await finalFile.exists() && await finalFile.length() > 400) {
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

    // 2. Si no está en disco, descargar en streaming con 3 intentos rápidos e invisibles para el usuario
    Object? lastError;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        return await _downloadSegmentFromEdgeTts(
          finalFile: finalFile,
          wordsFile: wordsFile,
          key: key,
          text: text,
          voiceKey: voiceKey,
        ).timeout(const Duration(seconds: 15));
      } catch (e) {
        lastError = e;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
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
    String cleanSpeakText = TextSanitizer.humanizeTextForNaturalSpeech(text).trim();
    if (cleanSpeakText.isEmpty) {
      cleanSpeakText = '.';
    }
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

    await for (final event in tts.stream().timeout(const Duration(seconds: 10))) {
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
    if (bytes.length < 128) {
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
