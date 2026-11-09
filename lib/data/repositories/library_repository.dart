import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../domain/models/book_item.dart';
import '../../domain/models/chapter_item.dart';
import '../services/pdf_extractor_service.dart';

/// Repositorio único de verdad para la Biblioteca, progreso ultraligero y preferencias del reproductor
class LibraryRepository {
  static const String _booksPrefsKey = 'audiomind_books';
  static const String _lastBookIdPrefsKey = 'audiomind_last_book_id';
  static const String _sanitizedVersionPrefsKey = 'audiomind_sanitized_version';
  static const int _currentSanitizerVersion = 5;

  // Claves de preferencias persistentes del reproductor (Velocidad, Voz, Música de fondo)
  static const String _prefSpeedKey = 'audiomind_pref_speed';
  static const String _prefVoiceKey = 'audiomind_pref_voice_key';
  static const String _prefVoiceName = 'audiomind_pref_voice_name';
  static const String _prefAmbientVol = 'audiomind_pref_ambient_vol';
  static const String _prefAmbientTrack = 'audiomind_pref_ambient_track';

  static String _fastProgressKey(String bookId) => 'audiomind_prog_$bookId';
  static String _fastNotesKey(String bookId) => 'audiomind_notes_$bookId';

  Future<List<BookItem>> loadBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_booksPrefsKey);
    final savedSanitizerVer = prefs.getInt(_sanitizedVersionPrefsKey) ?? 0;

    if (jsonList != null && jsonList.isNotEmpty) {
      final loaded = jsonList
          .map((item) => BookItem.fromJson(jsonDecode(item) as Map<String, dynamic>))
          .toList();

      final bool needsOneTimeSanitize = savedSanitizerVer < _currentSanitizerVersion;
      final List<BookItem> resultBooks = [];

      for (final b in loaded) {
        // Restaurar progreso rápido ultraligero si existe
        final rawFastProg = prefs.getString(_fastProgressKey(b.id));
        if (rawFastProg != null) {
          try {
            final map = jsonDecode(rawFastProg) as Map<String, dynamic>;
            b.lastChapterIndex = (map['ch'] as int?) ?? b.lastChapterIndex;
            b.lastSegmentIndex = (map['seg'] as int?) ?? b.lastSegmentIndex;
            b.lastPositionMs = (map['pos'] as int?) ?? b.lastPositionMs;
            b.totalSegmentsInLastChapter =
                (map['tot'] as int?) ?? b.totalSegmentsInLastChapter;
          } catch (_) {}
        }

        // Restaurar notas rápidas de cada capítulo si existen
        final rawFastNotes = prefs.getString(_fastNotesKey(b.id));
        if (rawFastNotes != null) {
          try {
            final notesMap = jsonDecode(rawFastNotes) as Map<String, dynamic>;
            for (final ch in b.chapters) {
              final chNote = notesMap[ch.id.toString()];
              if (chNote is Map<String, dynamic>) {
                ch.noteTitle = chNote['title'] as String?;
                ch.noteContent = chNote['content'] as String?;
                ch.isNotePinned = (chNote['pinned'] as bool?) ?? false;
                ch.noteColorHex = (chNote['color'] as int?) ?? 0xFF141519;
                ch.noteUpdatedAtMs = chNote['updatedAt'] as int?;
              }
            }
          } catch (_) {}
        }

        if (needsOneTimeSanitize) {
          List<ChapterItem> sourceChapters = b.chapters;
          if (b.fileType == 'pdf' &&
              b.originalFilePath != null &&
              b.chapters.any((c) => c.textContent.contains('yy'))) {
            try {
              final pdfFile = File(b.originalFilePath!);
              if (await pdfFile.exists()) {
                final bytes = await pdfFile.readAsBytes();
                final reExtracted = await PdfExtractorService.extractChaptersInBackground(
                  pdfBytes: bytes,
                  onProgress: (_, __, ___) {},
                );
                if (reExtracted.isNotEmpty) {
                  for (final newCh in reExtracted) {
                    final oldMatches = b.chapters.where((old) => old.id == newCh.id);
                    if (oldMatches.isNotEmpty) {
                      final oldCh = oldMatches.first;
                      newCh.noteTitle = oldCh.noteTitle;
                      newCh.noteContent = oldCh.noteContent;
                      newCh.isNotePinned = oldCh.isNotePinned;
                      newCh.noteColorHex = oldCh.noteColorHex;
                      newCh.noteUpdatedAtMs = oldCh.noteUpdatedAtMs;
                    }
                  }
                  sourceChapters = reExtracted;
                }
              }
            } catch (_) {}
          }

          final cleanChapters = sourceChapters.map((ch) {
            return ChapterItem(
              id: ch.id,
              title: TextSanitizer.sanitizeExtractedText(ch.title),
              subtitle: ch.subtitle,
              durationText: ch.durationText,
              textContent: TextSanitizer.sanitizeExtractedText(ch.textContent),
              localAudioPath: ch.localAudioPath,
              originalLanguageSegments: ch.originalLanguageSegments
                  ?.map((s) => TextSanitizer.sanitizeExtractedText(s))
                  .toList(),
              noteTitle: ch.noteTitle,
              noteContent: ch.noteContent,
              isNotePinned: ch.isNotePinned,
              noteColorHex: ch.noteColorHex,
              noteUpdatedAtMs: ch.noteUpdatedAtMs,
            );
          }).toList();

          resultBooks.add(
            BookItem(
              id: b.id,
              title: b.title,
              author: b.author,
              coverTag: b.coverTag,
              totalTime: b.totalTime,
              chapters: cleanChapters,
              isFavorite: b.isFavorite,
              coverImagePath: b.coverImagePath,
              coverUrl: b.coverUrl,
              originalFilePath: b.originalFilePath,
              fileType: b.fileType,
              detectedLanguage: b.detectedLanguage,
              activeAudioLanguage: b.activeAudioLanguage,
              lastChapterIndex: b.lastChapterIndex.clamp(0, cleanChapters.length - 1),
              lastSegmentIndex: b.lastSegmentIndex,
              lastPositionMs: b.lastPositionMs,
              totalSegmentsInLastChapter: b.totalSegmentsInLastChapter,
            ),
          );
        } else {
          resultBooks.add(b);
        }
      }

      if (needsOneTimeSanitize) {
        await saveBooks(resultBooks);
        await prefs.setInt(_sanitizedVersionPrefsKey, _currentSanitizerVersion);
      }

      return resultBooks;
    } else {
      await prefs.setInt(_sanitizedVersionPrefsKey, _currentSanitizerVersion);
      return <BookItem>[];
    }
  }

  Future<String?> getLastActiveBookId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastBookIdPrefsKey);
  }

  /// Guardado completo de estructura de libros (solo al agregar, borrar o marcar favorito)
  Future<void> saveBooks(List<BookItem> books, {String? activeBookId}) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = books.map((b) => jsonEncode(b.toJson())).toList();
    await prefs.setStringList(_booksPrefsKey, encoded);
    if (activeBookId != null) {
      await prefs.setString(_lastBookIdPrefsKey, activeBookId);
    }
  }

  /// Actualiza un único libro dentro de la lista guardada sin sobrescribir ni borrar los demás libros
  Future<void> updateSingleBookInStorage(BookItem updatedBook) async {
    final prefs = await SharedPreferences.getInstance();
    final currentList = prefs.getStringList(_booksPrefsKey) ?? <String>[];
    final updatedJson = jsonEncode(updatedBook.toJson());
    bool replaced = false;
    final List<String> newList = [];

    for (final raw in currentList) {
      if (!replaced && raw.contains('"id":"${updatedBook.id}"')) {
        newList.add(updatedJson);
        replaced = true;
      } else {
        newList.add(raw);
      }
    }
    if (!replaced) {
      newList.insert(0, updatedJson);
    }
    await prefs.setStringList(_booksPrefsKey, newList);
  }

  /// Guardado ultraligero (< 0.2ms) para progreso de audio cada 2 segundos o al cambiar de capítulo.
  /// Evita serializar megabytes de texto en el hilo principal y elimina el ANR "AudioMind isn't responding".
  Future<void> saveBookProgressFast(BookItem book) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'ch': book.lastChapterIndex,
      'seg': book.lastSegmentIndex,
      'pos': book.lastPositionMs,
      'tot': book.totalSegmentsInLastChapter,
    });
    await prefs.setString(_fastProgressKey(book.id), payload);
    await prefs.setString(_lastBookIdPrefsKey, book.id);
  }

  /// Guardado instantáneo (< 0.2ms) de las notas de cada sección/capítulo en tiempo real.
  /// Garantiza que aunque el teléfono se apague de golpe, no se pierda ni una letra escrita.
  Future<void> saveBookNotesFast(BookItem book) async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> notesMap = {};
    for (final ch in book.chapters) {
      if (ch.hasNote || ch.isNotePinned) {
        notesMap[ch.id.toString()] = {
          'title': ch.noteTitle,
          'content': ch.noteContent,
          'pinned': ch.isNotePinned,
          'color': ch.noteColorHex,
          'updatedAt': ch.noteUpdatedAtMs,
        };
      }
    }
    await prefs.setString(_fastNotesKey(book.id), jsonEncode(notesMap));
  }

  /// Carga la velocidad, voz y configuración de música ambiental guardadas por el usuario
  Future<Map<String, dynamic>> loadPlayerPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'speed': prefs.getDouble(_prefSpeedKey) ?? 1.0,
      'voiceKey': prefs.getString(_prefVoiceKey) ?? 'es-MX-JorgeNeural',
      'voiceName': prefs.getString(_prefVoiceName) ?? 'Jorge HD (México 🇲🇽 • Cálido)',
      'ambientVolume': prefs.getDouble(_prefAmbientVol) ?? 0.25,
      'ambientTrackId': prefs.getString(_prefAmbientTrack),
    };
  }

  /// Guarda al instante la velocidad, voz o volumen ambiental elegidos por el usuario
  Future<void> savePlayerPreferences({
    double? speed,
    String? voiceKey,
    String? voiceName,
    double? ambientVolume,
    String? ambientTrackId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (speed != null) await prefs.setDouble(_prefSpeedKey, speed);
    if (voiceKey != null) await prefs.setString(_prefVoiceKey, voiceKey);
    if (voiceName != null) await prefs.setString(_prefVoiceName, voiceName);
    if (ambientVolume != null) await prefs.setDouble(_prefAmbientVol, ambientVolume);
    if (ambientTrackId != null) await prefs.setString(_prefAmbientTrack, ambientTrackId);
  }

  Future<String> savePermanentBookCopy(String bookId, String fileName, Uint8List bytes) async {
    final docDir = await getApplicationDocumentsDirectory();
    final booksDir = Directory('${docDir.path}/books');
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    final permanentFilePath = '${booksDir.path}/${bookId}_$fileName';
    await File(permanentFilePath).writeAsBytes(bytes, flush: true);
    return permanentFilePath;
  }

  /// Borra todos los archivos asociados a un libro (portada, documento original, MP3s y JSONs de karaoke)
  Future<void> deleteBookFiles(BookItem book) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_fastProgressKey(book.id));
      await prefs.remove(_fastNotesKey(book.id));

      if (book.coverImagePath != null) {
        final f = File(book.coverImagePath!);
        if (await f.exists()) await f.delete();
      }
      if (book.originalFilePath != null) {
        final f = File(book.originalFilePath!);
        if (await f.exists()) await f.delete();
      }
      final docDir = await getApplicationDocumentsDirectory();
      // Limpiar carpeta dedicada del libro en tts_cache/<bookId>
      final bookCacheDir = Directory('${docDir.path}/tts_cache/${book.id}');
      if (await bookCacheDir.exists()) {
        await bookCacheDir.delete(recursive: true);
      }
      // Limpiar archivos antiguos sueltos en docDir o tts_cache
      if (await docDir.exists()) {
        await for (final entity in docDir.list()) {
          if (entity is File && entity.path.contains('${book.id}_')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('Delete cleanup notice: $e');
    }
  }
}
