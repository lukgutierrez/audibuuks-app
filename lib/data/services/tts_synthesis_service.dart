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

  // Mapa LRU acotado a máximo 120 segmentos en RAM para compartir timings instantáneamente con el PDF en vivo
  final LinkedHashMap<String, List<WordTimingItem>> _segmentWordTimings =
      LinkedHashMap<String, List<WordTimingItem>>();
  // Índice secundario sin hash de texto para garantizar hits incluso si un consumidor no pasa `text:`
  final LinkedHashMap<String, List<WordTimingItem>> _segmentWordTimingsByBase =
      LinkedHashMap<String, List<WordTimingItem>>();

  final Map<String, Future<File>> _inFlightSynthesis = {};
  final Set<String> _createdBookDirs = {};
  final Set<String> _knownCachedKeys = {};
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

  String _baseTimingKey(String bookId, int chapterId, int segIdx, String voiceKey) {
    final langTag = voiceKey.startsWith('en-') ? 'en' : 'es';
    return '${bookId}_ch${chapterId}_s${segIdx}_${voiceKey}_$langTag';
  }

  String segmentKeyId(
    String bookId,
    ChapterItem chapter,
    int segIdx,
    String voiceKey, {
    String? text,
  }) {
    final textHash = (text != null && text.trim().isNotEmpty)
        ? '_h${text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase().hashCode.abs().toRadixString(16)}'
        : '';
    final langTag = voiceKey.startsWith('en-') ? 'en' : 'es';
    return '${bookId}_ch${chapter.id}_s${segIdx}_${voiceKey}_$langTag${textHash}_hd96_v5';
  }

  void _putTimingsInRamCache(
    String key,
    List<WordTimingItem> timings, {
    String? baseKey,
  }) {
    _segmentWordTimings.remove(key);
    _segmentWordTimings[key] = timings;
    while (_segmentWordTimings.length > 120) {
      _segmentWordTimings.remove(_segmentWordTimings.keys.first);
    }

    if (baseKey != null) {
      _segmentWordTimingsByBase.remove(baseKey);
      _segmentWordTimingsByBase[baseKey] = timings;
      while (_segmentWordTimingsByBase.length > 120) {
        _segmentWordTimingsByBase.remove(_segmentWordTimingsByBase.keys.first);
      }
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
    final exact = _segmentWordTimings[key];
    if (exact != null) return exact;

    final baseKey = _baseTimingKey(bookId, chapter.id, segIdx, voiceKey);
    return _segmentWordTimingsByBase[baseKey];
  }

  Future<Directory> _getBookCacheDir(String bookId) async {
    final docPath = await _getDocDirPath();
    final dirPath = '$docPath/tts_cache/$bookId';
    final dir = Directory(dirPath);
    if (!_createdBookDirs.contains(dirPath)) {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _createdBookDirs.add(dirPath);
    }
    return dir;
  }

  /// Devuelve en una única llamada al sistema operativo los nombres de archivos MP3 válidos en caché para un libro.
  /// Evita cientos/miles de llamadas secuenciales a `File.exists()` durante descargas y apertura de lista de capítulos.
  Future<Set<String>> getCachedKeysForBook(String bookId) async {
    final Set<String> keys = {};
    try {
      final docPath = await _getDocDirPath();
      final bookDir = Directory('$docPath/tts_cache/$bookId');
      if (await bookDir.exists()) {
        await for (final entity in bookDir.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.mp3')) {
            final len = await entity.length();
            if (len > 400) {
              final name = entity.uri.pathSegments.isNotEmpty
                  ? entity.uri.pathSegments.last
                  : entity.path.split(Platform.pathSeparator).last;
              final key = name.substring(0, name.length - 4);
              keys.add(key);
              _knownCachedKeys.add(key);
            }
          }
        }
      }
    } catch (_) {}
    return keys;
  }

  void markKeyRemovedFromCache(String key) {
    _knownCachedKeys.remove(key);
    _segmentWordTimings.remove(key);
  }

  Future<File> _getSegmentFile(String bookId, String key) async {
    final bookDir = await _getBookCacheDir(bookId);
    final primaryFile = File('${bookDir.path}/$key.mp3');
    if (_knownCachedKeys.contains(key) || await primaryFile.exists()) {
      return primaryFile;
    }
    final docPath = await _getDocDirPath();
    final legacyFile = File('$docPath/$key.mp3');
    if (await legacyFile.exists()) return legacyFile;
    return primaryFile;
  }

  Future<File> _getSegmentWordsFile(String bookId, String key) async {
    final bookDir = await _getBookCacheDir(bookId);
    final primaryWords = File('${bookDir.path}/$key.words.json');
    if (await primaryWords.exists()) return primaryWords;
    final docPath = await _getDocDirPath();
    final legacyWords = File('$docPath/$key.words.json');
    if (await legacyWords.exists()) return legacyWords;
    return primaryWords;
  }

  Future<File> getSegmentFilePublic(String bookId, String key) => _getSegmentFile(bookId, key);
  Future<File> getSegmentWordsFilePublic(String bookId, String key) =>
      _getSegmentWordsFile(bookId, key);

  /// Verifica rápido si este párrafo ya está descargado en la caché del celular (estilo YouTube Music)
  Future<bool> isSegmentCached({
    required String bookId,
    required ChapterItem chapter,
    required int segIdx,
    required String voiceKey,
    String? text,
  }) async {
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey, text: text);
    if (_knownCachedKeys.contains(key)) {
      final file = await _getSegmentFile(bookId, key);
      if (await file.exists() && await file.length() > 400) {
        return true;
      }
      _knownCachedKeys.remove(key);
      return false;
    }
    final file = await _getSegmentFile(bookId, key);
    final ok = await file.exists() && await file.length() > 400;
    if (ok) {
      _knownCachedKeys.add(key);
    }
    return ok;
  }

  /// Elimina un archivo de caché corrupto/incompleto para forzar una resíntesis limpia y evitar trabas
  Future<void> invalidateCorruptedSegment({
    required String bookId,
    required ChapterItem chapter,
    required int segIdx,
    required String voiceKey,
    String? text,
  }) async {
    final key = segmentKeyId(bookId, chapter, segIdx, voiceKey, text: text);
    _knownCachedKeys.remove(key);
    _segmentWordTimings.remove(key);
    _segmentWordTimingsByBase.remove(_baseTimingKey(bookId, chapter.id, segIdx, voiceKey));
    try {
      final mp3 = await _getSegmentFile(bookId, key);
      if (await mp3.exists()) await mp3.delete();
    } catch (_) {}
    try {
      final words = await _getSegmentWordsFile(bookId, key);
      if (await words.exists()) await words.delete();
    } catch (_) {}
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
    final baseKey = _baseTimingKey(bookId, chapter.id, segIdx, voiceKey);

    if (_inFlightSynthesis.containsKey(key)) {
      return _inFlightSynthesis[key]!;
    }

    final future = _doSynthesizeWithRetry(
      bookId: bookId,
      key: key,
      baseKey: baseKey,
      text: text,
      voiceKey: voiceKey,
    ).whenComplete(() {
      _inFlightSynthesis.remove(key);
    });
    _inFlightSynthesis[key] = future;
    return future;
  }

  Future<File> _doSynthesizeWithRetry({
    required String bookId,
    required String key,
    required String baseKey,
    required String text,
    required String voiceKey,
  }) async {
    // 1. Si ya está en caché local en disco, devolver en 0ms sin tocar internet
    final finalFile = await _getSegmentFile(bookId, key);
    final wordsFile = await _getSegmentWordsFile(bookId, key);

    if (await finalFile.exists() && await finalFile.length() > 400) {
      _knownCachedKeys.add(key);
      if (!_segmentWordTimings.containsKey(key) && await wordsFile.exists()) {
        try {
          final rawJson = await wordsFile.readAsString();
          final list = (jsonDecode(rawJson) as List)
              .map((e) => WordTimingItem.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          _putTimingsInRamCache(key, list, baseKey: baseKey);
        } catch (_) {}
      }
      return finalFile;
    }

    // 2. Si no está en disco, descargar con 2 intentos rápidos fail-fast (evita congelar 45s en una conexión muerta)
    Object? lastError;
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        return await _downloadSegmentFromEdgeTts(
          finalFile: finalFile,
          wordsFile: wordsFile,
          key: key,
          baseKey: baseKey,
          text: text,
          voiceKey: voiceKey,
        ).timeout(const Duration(seconds: 13));
      } catch (e) {
        lastError = e;
        if (attempt < 2) {
          await Future<void>.delayed(Duration(milliseconds: 280 * attempt));
        }
      }
    }
    throw lastError ?? TimeoutException('Conexión inestable al sintetizar audio');
  }

  /// Valida que los bytes recibidos correspondan a un stream MP3 real (ID3 o frame sync MPEG)
  bool _isValidMp3Bytes(Uint8List bytes) {
    if (bytes.length < 256) return false;
    // Cabecera ID3v2 ("ID3")
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true;
    // Frame sync MPEG (11 bits en 1: 0xFF seguido de 0xE0..0xFF) en los primeros 64 bytes
    final scanLimit = min(bytes.length - 1, 64);
    for (int i = 0; i < scanLimit; i++) {
      if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) {
        return true;
      }
    }
    return false;
  }

  Future<File> _downloadSegmentFromEdgeTts({
    required File finalFile,
    required File wordsFile,
    required String key,
    required String baseKey,
    required String text,
    required String voiceKey,
  }) async {
    String cleanSpeakText = TextSanitizer.humanizeTextForNaturalSpeech(text).trim();
    if (cleanSpeakText.isEmpty) {
      cleanSpeakText = '.';
    }
    final tempFile = File('${finalFile.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');

    try {
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

      await for (final event in tts.stream().timeout(const Duration(seconds: 8))) {
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
      if (!_isValidMp3Bytes(bytes)) {
        throw Exception('Audio incompleto o inválido recibido de la red');
      }

      await tempFile.writeAsBytes(bytes, flush: true);
      if (await finalFile.exists()) {
        try {
          await finalFile.delete();
        } catch (_) {}
      }
      final savedMp3 = await tempFile.rename(finalFile.path);
      _knownCachedKeys.add(key);

      if (timings.isNotEmpty) {
        _putTimingsInRamCache(key, timings, baseKey: baseKey);
        try {
          await wordsFile.writeAsString(
            jsonEncode(timings.map((t) => t.toJson()).toList()),
            flush: true,
          );
        } catch (_) {}
      }

      return savedMp3;
    } catch (e) {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
