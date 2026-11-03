import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/book_item.dart';
import '../services/cover_service.dart';

/// Repositorio único de verdad para la Biblioteca de libros y sus archivos en disco
class LibraryRepository {
  static const String _booksPrefsKey = 'audiomind_books';
  static const String _lastBookIdPrefsKey = 'audiomind_last_book_id';

  Future<List<BookItem>> loadBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_booksPrefsKey);

    if (jsonList != null && jsonList.isNotEmpty) {
      final loaded = jsonList
          .map((item) => BookItem.fromJson(jsonDecode(item) as Map<String, dynamic>))
          .toList();
      for (final b in loaded) {
        if (b.id == 'oakley_numeros' && (b.coverUrl == null || b.coverUrl!.isEmpty)) {
          b.coverUrl = sampleOakleyBook.coverUrl;
        }
      }
      return loaded;
    } else {
      final initial = [sampleOakleyBook];
      await saveBooks(initial);
      return initial;
    }
  }

  Future<String?> getLastActiveBookId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastBookIdPrefsKey);
  }

  Future<void> saveBooks(List<BookItem> books, {String? activeBookId}) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = books.map((b) => jsonEncode(b.toJson())).toList();
    await prefs.setStringList(_booksPrefsKey, encoded);
    if (activeBookId != null) {
      await prefs.setString(_lastBookIdPrefsKey, activeBookId);
    }
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

  Future<bool> resolveMissingCovers(List<BookItem> books) async {
    bool updated = false;
    final docDir = await getApplicationDocumentsDirectory();

    for (final book in books) {
      final hasLocal = book.coverImagePath != null && File(book.coverImagePath!).existsSync();
      if (!hasLocal) {
        String? url = book.coverUrl;
        url ??= await CoverService.fetchOnlineCoverUrl(book.title);
        if (url != null && url.isNotEmpty) {
          book.coverUrl = url;
          try {
            final coverFile = File('${docDir.path}/cover_${book.id}.jpg');
            final client = HttpClient();
            final req = await client.getUrl(Uri.parse(url));
            final res = await req.close().timeout(const Duration(seconds: 5));
            if (res.statusCode == 200) {
              final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
              if (bytes.length > 1000) {
                await coverFile.writeAsBytes(bytes);
                book.coverImagePath = coverFile.path;
              }
            }
          } catch (_) {}
          updated = true;
        }
      }
    }
    if (updated) {
      await saveBooks(books);
    }
    return updated;
  }

  /// Borra todos los archivos asociados a un libro (portada, documento original, MP3s y JSONs de karaoke)
  Future<void> deleteBookFiles(BookItem book) async {
    try {
      if (book.coverImagePath != null) {
        final f = File(book.coverImagePath!);
        if (await f.exists()) await f.delete();
      }
      if (book.originalFilePath != null) {
        final f = File(book.originalFilePath!);
        if (await f.exists()) await f.delete();
      }
      final docDir = await getApplicationDocumentsDirectory();
      // Limpiar MP3s y words.json sintetizados en docDir
      if (await docDir.exists()) {
        final list = docDir.listSync();
        for (final entity in list) {
          if (entity is File && entity.path.contains('${book.id}_')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
      // Limpiar carpeta tts_cache si existe
      final cacheDir = Directory('${docDir.path}/tts_cache');
      if (await cacheDir.exists()) {
        final list = cacheDir.listSync();
        for (final entity in list) {
          if (entity is File && entity.path.contains(book.id)) {
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
