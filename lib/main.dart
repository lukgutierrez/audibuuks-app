import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_selector/file_selector.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:edge_tts/edge_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Instancia global única de AudioPlayer (requerido por just_audio_background)
final AudioPlayer globalAudioPlayer = AudioPlayer();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.lo.audiomind.channel.audio',
      androidNotificationChannelName: 'AudioMind Reproducción',
      androidNotificationOngoing: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    );
  } catch (e) {
    debugPrint('Background audio init notice: $e');
  }

  runApp(const AudioMindApp());
}

class AudioMindApp extends StatelessWidget {
  const AudioMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AudioMind',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: const Color(0xFFF5A623),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFF5A623),
          secondary: Color(0xFFFFC107),
          surface: Color(0xFF1E1E1E),
        ),
        fontFamily: GoogleFonts.inter().fontFamily,
        useMaterial3: true,
      ),
      home: const LibraryScreen(),
    );
  }
}

// ==========================================
// MODELOS DE DATOS, PROGRESO EXACTO AL SEGUNDO Y TIMESTAMPS DE KARAOKE
// ==========================================
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

class BookItem {
  final String id;
  final String title;
  final String author;
  final String coverTag;
  final String totalTime;
  final List<ChapterItem> chapters;
  String? coverImagePath;
  String? coverUrl;
  String? originalFilePath;
  String? fileType; // 'pdf' | 'epub' | 'sample'

  // Progreso persistente exacto (capítulo, párrafo y milisegundo exacto)
  int lastChapterIndex;
  int lastSegmentIndex;
  int lastPositionMs;
  int totalSegmentsInLastChapter;
  bool isFavorite;

  BookItem({
    required this.id,
    required this.title,
    required this.author,
    required this.coverTag,
    required this.totalTime,
    required this.chapters,
    this.coverImagePath,
    this.coverUrl,
    this.originalFilePath,
    this.fileType = 'pdf',
    this.lastChapterIndex = 0,
    this.lastSegmentIndex = 0,
    this.lastPositionMs = 0,
    this.totalSegmentsInLastChapter = 1,
    this.isFavorite = false,
  });

  int get estimatedBookTotalSeconds {
    return chapters.fold<int>(0, (sum, ch) => sum + ch.estimatedTotalSeconds);
  }

  double get overallProgress {
    if (chapters.isEmpty) return 0.0;
    final idx = lastChapterIndex.clamp(0, chapters.length - 1);
    final segFrac = totalSegmentsInLastChapter > 0
        ? (lastSegmentIndex / totalSegmentsInLastChapter).clamp(0.0, 1.0)
        : 0.0;
    final prog = (idx + segFrac) / chapters.length;
    return prog.clamp(0.0, 1.0);
  }

  bool get hasStarted =>
      lastChapterIndex > 0 || lastSegmentIndex > 0 || lastPositionMs > 2000;
  bool get isCompleted => overallProgress >= 0.96;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverTag': coverTag,
        'totalTime': totalTime,
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'coverImagePath': coverImagePath,
        'coverUrl': coverUrl,
        'originalFilePath': originalFilePath,
        'fileType': fileType,
        'lastChapterIndex': lastChapterIndex,
        'lastSegmentIndex': lastSegmentIndex,
        'lastPositionMs': lastPositionMs,
        'totalSegmentsInLastChapter': totalSegmentsInLastChapter,
        'isFavorite': isFavorite,
      };

  factory BookItem.fromJson(Map<String, dynamic> json) => BookItem(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String,
        coverTag: json['coverTag'] as String? ?? '📖',
        totalTime: json['totalTime'] as String,
        chapters: (json['chapters'] as List)
            .map((c) => ChapterItem.fromJson(c as Map<String, dynamic>))
            .toList(),
        coverImagePath: json['coverImagePath'] as String?,
        coverUrl: json['coverUrl'] as String?,
        originalFilePath: json['originalFilePath'] as String?,
        fileType: json['fileType'] as String? ?? 'pdf',
        lastChapterIndex: (json['lastChapterIndex'] as int?) ?? 0,
        lastSegmentIndex: (json['lastSegmentIndex'] as int?) ?? 0,
        lastPositionMs: (json['lastPositionMs'] as int?) ?? 0,
        totalSegmentsInLastChapter: (json['totalSegmentsInLastChapter'] as int?) ?? 1,
        isFavorite: (json['isFavorite'] as bool?) ?? false,
      );
}

// Libro precargado (Barbara Oakley) con su portada real
final sampleOakleyBook = BookItem(
  id: 'oakley_numeros',
  title: 'Abre tu mente a los números',
  author: 'Barbara Oakley',
  coverTag: '📖',
  totalTime: '6 h 45 m',
  coverUrl:
      'https://is1-ssl.mzstatic.com/image/thumb/Publication126/v4/ff/92/41/ff9241ca-71c8-41d3-7eda-7e802b99c890/9788490567180.jpg/600x600bb.jpg',
  chapters: [
    ChapterItem(
      id: 1,
      title: '01. Prefacio',
      subtitle: 'Págs. 1-4 • Por Jeffrey D. Karpicke',
      durationText: '3 min',
      textContent:
          'Este libro puede cambiar tu forma de percibir el aprendizaje. La ciencia cognitiva moderna ha demostrado que el cerebro no es una esponja rígida, sino una red maleable capaz de reconstruirse ante el esfuerzo bien dirigido. Aprender a aprender es la habilidad más potente que un ser humano puede desarrollar.',
    ),
    ChapterItem(
      id: 2,
      title: '02. Prólogo',
      subtitle: 'Págs. 5-9 • Por Terrence J. Sejnowski',
      durationText: '4 min',
      textContent:
          'Tu cerebro contiene miles de millones de sinapsis en constante comunicación. Cuando crees que estás bloqueado frente a un problema difícil, tu subconsciente sigue trabajando en modo difuso conectando ideas y recuerdos que antes parecían imposibles de enlazar.',
    ),
    ChapterItem(
      id: 3,
      title: '03. Nota al lector',
      subtitle: 'Págs. 10-14 • Preparando el camino',
      durationText: '4 min',
      textContent:
          'No importa si odiaste las matemáticas o si crees que empezás tarde. Las herramientas de este libro están diseñadas para cualquier persona que quiera dominar temas técnicos o abstractos a su propio ritmo, sin frustración.',
    ),
    ChapterItem(
      id: 4,
      title: '04. Capítulo 1: Abre la puerta',
      subtitle: 'Págs. 15-34 • Mi viaje hacia la ingeniería',
      durationText: '15 min',
      textContent:
          'De pequeña odiaba los números y suspendía sistemáticamente matemáticas y ciencias. Creía que mi cerebro estaba cableado solo para las letras y los idiomas extranjeros. A los veintiséis años decidí reiniciar mi mente y descubrir cómo funcionaba el engranaje profundo del aprendizaje.',
    ),
    ChapterItem(
      id: 5,
      title: '05. Capítulo 2: Escoge el camino fácil',
      subtitle: 'Págs. 35-58 • Modo enfocado y modo difuso',
      durationText: '22 min',
      textContent:
          'Cuando te concentras fijamente en un problema, activas el modo enfocado. Pero si te trabas, seguir apretando los dientes solo te encierra en el efecto Einstellung, un callejón sin salida neurológico. La solución llega cuando soltás y dejas que el modo difuso tome el mando.',
    ),
  ],
);

// ==========================================
// MOTOR DE LIMPIEZA Y HUMANIZACIÓN DE TEXTO PDF/EPUB PARA VOZ NATURAL
// ==========================================
String _sanitizeExtractedText(String raw) {
  var s = raw.replaceAll('\r\n', '\n');

  // 1. Unir palabras cortadas por guión al final de línea en PDFs ("pro-\nceso" -> "proceso")
  s = s.replaceAllMapped(
    RegExp(r'([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])-\s*\n\s*([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])'),
    (m) => '${m.group(1)}${m.group(2)}',
  );

  // 2. Separar palabras pegadas por minúscula seguida de mayúscula: "cansancioTraducción" -> "cansancio. Traducción"
  s = s.replaceAllMapped(
    RegExp(r'([a-záéíóúñü])([A-ZÁÉÍÓÚÑÜ])'),
    (m) => '${m.group(1)}. ${m.group(2)}',
  );

  // 3. Separar números pegados a letras o comas pegadas ("2010,MSB" -> "2010, MSB", "om1ª" -> "om 1ª")
  s = s.replaceAllMapped(
    RegExp(r'([0-9]),([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])'),
    (m) => '${m.group(1)}, ${m.group(2)}',
  );
  s = s.replaceAllMapped(
    RegExp(r'([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ]),([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])'),
    (m) => '${m.group(1)}, ${m.group(2)}',
  );
  s = s.replaceAllMapped(
    RegExp(r'([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])([0-9])'),
    (m) => '${m.group(1)} ${m.group(2)}',
  );
  s = s.replaceAllMapped(
    RegExp(r'([0-9])([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])'),
    (m) => '${m.group(1)} ${m.group(2)}',
  );

  // 4. Eliminar hileras de puntos de índices visuales
  s = s.replaceAll(RegExp(r'\.{3,}\s*\d*'), '. ')
       .replaceAll(RegExp(r'…+\s*\d*'), '. ');

  // 5. Unir saltos de línea simples dentro de un mismo párrafo para que el TTS no haga pausas robóticas a mitad de frase
  s = s.replaceAllMapped(
    RegExp(r'([^\.\!\?\:\n])\n([a-záéíóúñü0-9“"«\(])'),
    (m) => '${m.group(1)} ${m.group(2)}',
  );

  s = s.replaceAll(RegExp(r'[ \t]{2,}'), ' ')
       .replaceAll(RegExp(r'\n{3,}'), '\n\n')
       .trim();

  return s;
}

/// Detecta páginas de créditos legales, imprenta o copyright para saltarlas automáticamente
bool _isLegalCopyrightPage(String rawPageText) {
  final lower = rawPageText.toLowerCase();
  int matches = 0;
  if (lower.contains('isbn')) matches += 2;
  if (lower.contains('depósito legal') || lower.contains('deposito legal')) matches += 2;
  if (lower.contains('todos los derechos reservados') || lower.contains('all rights reserved')) matches += 2;
  if (lower.contains('diseño de cubierta') || lower.contains('diseno de cubierta') || lower.contains('diseño de portada')) matches += 2;
  if (lower.contains('printed in') || lower.contains('impreso en')) matches += 2;
  if (lower.contains('primera edición') || lower.contains('primera edicion')) matches += 1;
  if (lower.contains('editorial herder') || lower.contains('ediciones ') || lower.contains('d.r. ©') || lower.contains('copyright ©')) matches += 1;
  if (lower.contains('traducción de') || lower.contains('traduccion de') || lower.contains('título original') || lower.contains('titulo original')) matches += 1;

  final wordCount = rawPageText.split(RegExp(r'\s+')).length;
  if (matches >= 3 && wordCount < 350) return true;
  if (matches >= 4) return true;
  return false;
}

/// Prepara el texto específicamente para que el motor neuronal respire y entone como un narrador humano profesional
String _humanizeTextForNaturalSpeech(String text) {
  var s = _sanitizeExtractedText(text);
  // Limpiar comillas tipográficas y guiones que hacen tropezar al TTS
  s = s
      .replaceAll(RegExp(r'[“”«»"]'), '')
      .replaceAll('—', ', ')
      .replaceAll('–', ', ')
      // Transformar paréntesis en pausas suaves de coma para que la voz baje el tono naturalmente
      .replaceAll('(', ', ')
      .replaceAll(')', ', ')
      // Expandir abreviaturas comunes de libros en español
      .replaceAll(RegExp(r'\bpágs?\.\s*', caseSensitive: false), 'páginas ')
      .replaceAll(RegExp(r'\bcap\.\s*', caseSensitive: false), 'capítulo ')
      .replaceAll(RegExp(r'\bp\.\s*ej\.', caseSensitive: false), 'por ejemplo')
      .replaceAll(RegExp(r'\betc\.', caseSensitive: false), 'etcétera.')
      .replaceAll(RegExp(r'\bdr\.\s*', caseSensitive: false), 'doctor ')
      .replaceAll(RegExp(r'\bdra\.\s*', caseSensitive: false), 'doctora ')
      // Evitar comas dobles o espacios antes de signos
      .replaceAll(RegExp(r'\s+([,\.\;\:\!\?])'), r'$1')
      .replaceAll(RegExp(r',\s*,+'), ',')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.isEmpty ? 'Continuando lectura.' : s;
}

class _PdfIsolatePayload {
  final Uint8List pdfBytes;
  final SendPort sendPort;
  _PdfIsolatePayload(this.pdfBytes, this.sendPort);
}

bool _isTableOfContentsPage(String rawPageText) {
  final dotClusters = RegExp(r'\.{4,}|…{2,}').allMatches(rawPageText).length;
  final lower = rawPageText.toLowerCase();
  if (dotClusters >= 4) return true;
  if ((lower.contains('índice') || lower.contains('indice') || lower.contains('contenido')) &&
      dotClusters >= 2) {
    return true;
  }
  return false;
}

String? _detectChapterHeadingOnPage(String pageText) {
  final lines = pageText
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .take(6)
      .toList();
  if (lines.isEmpty) return null;

  final headingRegex = RegExp(
    r'^(?:CAP[ÍI]TULO\s+\d+|CAP[ÍI]TULO\s+[IVXLCDM]+|PARTE\s+\d+|PARTE\s+[IVXLCDM]+|PRIMERA\s+PARTE|SEGUNDA\s+PARTE|TERCERA\s+PARTE|CUARTA\s+PARTE|REGLA\s*#?\s*\d+|SECRETO\s*#?\s*\d+|D[ÍI]A\s+\d+|INTRODUCCI[ÓO]N|PR[ÓO]LOGO|PREFACIO|SINOPSIS|CONCLUSI[ÓO]N|EP[ÍI]LOGO)\b.*$',
    caseSensitive: false,
  );

  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.contains('....')) continue;
    if (headingRegex.hasMatch(line) && line.length < 90) {
      if (i + 1 < lines.length &&
          lines[i + 1].length < 75 &&
          !lines[i + 1].endsWith('.')) {
        return '$line: ${lines[i + 1]}';
      }
      return line;
    }
  }
  return null;
}

void _pdfExtractionIsolateEntry(_PdfIsolatePayload payload) {
  try {
    final pdfDocument = PdfDocument(inputBytes: payload.pdfBytes);
    final totalPages = pdfDocument.pages.count;

    payload.sendPort.send({
      'type': 'progress',
      'current': 0,
      'total': totalPages,
      'percent': 2,
    });

    final extractor = PdfTextExtractor(pdfDocument);
    final List<String> pageTexts = List.filled(totalPages, '');
    final List<String?> detectedHeadings = List.filled(totalPages, null);

    int reportInterval = max(1, totalPages ~/ 25);
    for (int p = 0; p < totalPages; p++) {
      final raw = extractor.extractText(startPageIndex: p, endPageIndex: p);
      if (!_isTableOfContentsPage(raw) && !_isLegalCopyrightPage(raw)) {
        final cleaned = _sanitizeExtractedText(raw);
        pageTexts[p] = cleaned;
        detectedHeadings[p] = _detectChapterHeadingOnPage(raw);
      }

      if (p % reportInterval == 0 || p == totalPages - 1) {
        final int pct = (((p + 1) / totalPages) * 90).round().clamp(3, 92);
        payload.sendPort.send({
          'type': 'progress',
          'current': p + 1,
          'total': totalPages,
          'percent': pct,
        });
      }
    }

    pdfDocument.dispose();

    final List<int> headingPages = [];
    for (int p = 0; p < totalPages; p++) {
      if (detectedHeadings[p] != null && pageTexts[p].length > 80) {
        if (headingPages.isEmpty || (p - headingPages.last) >= 2) {
          headingPages.add(p);
        }
      }
    }

    final List<Map<String, dynamic>> chapters = [];

    if (headingPages.length >= 2) {
      if (headingPages.first > 0) {
        final preText = pageTexts
            .sublist(0, headingPages.first)
            .where((t) => t.isNotEmpty)
            .join('\n\n')
            .trim();
        if (preText.length > 120) {
          final words = preText.split(RegExp(r'\s+')).length;
          final mins = max(1, (words / 140).round());
          chapters.add({
            'id': 1,
            'title': '01. Apertura y Presentación',
            'subtitle': 'Págs. 1-${headingPages.first}',
            'durationText': '$mins min',
            'textContent': preText,
          });
        }
      }

      for (int k = 0; k < headingPages.length; k++) {
        final int startP = headingPages[k];
        final int endP =
            (k + 1 < headingPages.length) ? headingPages[k + 1] - 1 : totalPages - 1;
        final String headingTitle = detectedHeadings[startP]!;
        final String combinedText = pageTexts
            .sublist(startP, endP + 1)
            .where((t) => t.isNotEmpty)
            .join('\n\n')
            .trim();

        if (combinedText.isNotEmpty) {
          final int pageSpan = endP - startP + 1;
          if (pageSpan > 24) {
            int partNum = 1;
            for (int sp = startP; sp <= endP; sp += 12) {
              final int se = min(sp + 11, endP);
              final partText = pageTexts
                  .sublist(sp, se + 1)
                  .where((t) => t.isNotEmpty)
                  .join('\n\n')
                  .trim();
              if (partText.isNotEmpty) {
                final words = partText.split(RegExp(r'\s+')).length;
                final mins = max(1, (words / 140).round());
                final id = chapters.length + 1;
                chapters.add({
                  'id': id,
                  'title':
                      '${id.toString().padLeft(2, '0')}. $headingTitle (Parte $partNum)',
                  'subtitle': 'Págs. ${sp + 1}-${se + 1}',
                  'durationText': '$mins min',
                  'textContent': partText,
                });
                partNum++;
              }
            }
          } else {
            final words = combinedText.split(RegExp(r'\s+')).length;
            final mins = max(1, (words / 140).round());
            final id = chapters.length + 1;
            chapters.add({
              'id': id,
              'title': '${id.toString().padLeft(2, '0')}. $headingTitle',
              'subtitle': 'Págs. ${startP + 1}-${endP + 1}',
              'durationText': '$mins min',
              'textContent': combinedText,
            });
          }
        }
      }
    } else {
      int step = (totalPages > 300)
          ? 10
          : (totalPages > 100)
              ? 8
              : (totalPages > 25 ? 5 : 2);
      if (step < 1) step = 1;

      for (int i = 0; i < totalPages; i += step) {
        final int end = min(i + step - 1, totalPages - 1);
        final blockText = pageTexts
            .sublist(i, end + 1)
            .where((t) => t.isNotEmpty)
            .join('\n\n')
            .trim();

        if (blockText.isNotEmpty) {
          final wordsCount = blockText.split(RegExp(r'\s+')).length;
          final estMinutes = max(1, (wordsCount / 140).round());
          final id = chapters.length + 1;

          chapters.add({
            'id': id,
            'title': 'Sección $id',
            'subtitle': 'Págs. ${i + 1}-${end + 1}',
            'durationText': '$estMinutes min',
            'textContent': blockText,
          });
        }
      }
    }

    payload.sendPort.send({
      'type': 'progress',
      'current': totalPages,
      'total': totalPages,
      'percent': 100,
    });

    payload.sendPort.send({
      'type': 'done',
      'total': totalPages,
      'chapters': chapters,
    });
  } catch (e) {
    payload.sendPort.send({
      'type': 'error',
      'message': e.toString(),
    });
  }
}

// ==========================================
// 4 PIEZAS DE MÚSICA INSTRUMENTAL CLÁSICA PURA Y ARMÓNICA (CERO RUIDO BLANCO)
// ==========================================
class AmbientTrackInfo {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;

  const AmbientTrackInfo({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
  });
}

const List<AmbientTrackInfo> kAmbientTracks = [
  AmbientTrackInfo(
    id: 'classical_adagio',
    title: 'Adagio en Piano Clásico',
    subtitle: 'Notas lentas y cristalinas estilo Erik Satie (Gymnopédie)',
    icon: Icons.piano_rounded,
  ),
  AmbientTrackInfo(
    id: 'debussy_harp',
    title: 'Preludio de Arpa & Piano',
    subtitle: 'Arpegios acústicos suaves y armónicos en Do Mayor',
    icon: Icons.music_note_rounded,
  ),
  AmbientTrackInfo(
    id: 'canon_chamber',
    title: 'Canon Armónico de Cámara',
    subtitle: 'Progresión clásica serena estilo Pachelbel para lectura',
    icon: Icons.library_music_rounded,
  ),
  AmbientTrackInfo(
    id: 'nocturne_calm',
    title: 'Nocturno Minimalista',
    subtitle: 'Piano íntimo y pausado estilo Ludovico Einaudi',
    icon: Icons.nights_stay_rounded,
  ),
];

class NativeChannelService {
  static const MethodChannel channel = MethodChannel('com.lo.audiomind/pdf_cover');
  static String currentTrackId = 'classical_adagio';

  static Future<void> initLoFi({
    String trackId = 'classical_adagio',
    bool autoStart = false,
  }) async {
    try {
      currentTrackId = trackId;
      final wavPath = await LoFiGenerator.ensureAmbientTrack(trackId);
      await channel.invokeMethod('initLoFi', {
        'path': wavPath,
        'autoStart': autoStart,
      });
    } catch (e) {
      debugPrint('initLoFi notice: $e');
    }
  }

  static Future<void> selectAndPlayTrack(
    String trackId,
    double volume, {
    required bool shouldPlayNow,
  }) async {
    try {
      currentTrackId = trackId;
      final wavPath = await LoFiGenerator.ensureAmbientTrack(trackId);
      await channel.invokeMethod('setLoFiVolume', {'volume': volume});
      await channel.invokeMethod('initLoFi', {
        'path': wavPath,
        'autoStart': shouldPlayNow && volume > 0,
      });
    } catch (e) {
      debugPrint('selectAndPlayTrack notice: $e');
    }
  }

  static Future<void> playLoFi() async {
    try {
      final wavPath = await LoFiGenerator.ensureAmbientTrack(currentTrackId);
      await channel.invokeMethod('playLoFi', {'path': wavPath});
    } catch (_) {}
  }

  static Future<void> pauseLoFi() async {
    try {
      await channel.invokeMethod('pauseLoFi');
    } catch (_) {}
  }

  static Future<void> setLoFiVolume(double volume) async {
    try {
      await channel.invokeMethod('setLoFiVolume', {'volume': volume});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> renderPdfPage(
    String path,
    int pageIndex, {
    int width = 1080,
  }) async {
    try {
      final res = await channel.invokeMethod('renderPdfPage', {
        'path': path,
        'pageIndex': pageIndex,
        'width': width,
      });
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      debugPrint('renderPdfPage notice: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>?> extractEpub(String path) async {
    try {
      final res = await channel.invokeMethod('extractEpub', {'path': path});
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      debugPrint('extractEpub notice: $e');
    }
    return null;
  }
}

/// Motor de extracción y estructuración nativa para libros .EPUB
class EpubProcessor {
  static Future<BookItem?> processEpubFile({
    required String filePath,
    required String bookId,
    required String originalFileName,
    required Function(int pct, String status, String detail) onProgress,
  }) async {
    onProgress(5, 'Leyendo archivo EPUB...', originalFileName);
    final res = await NativeChannelService.extractEpub(filePath);
    if (res == null) {
      throw Exception('No se pudo procesar la estructura interna del EPUB.');
    }

    onProgress(25, 'Extrayendo portada e índice...', 'Buscando portada original en alta definición');
    final Uint8List? coverBytes = res['coverBytes'] as Uint8List?;
    String? coverPath;
    if (coverBytes != null && coverBytes.isNotEmpty) {
      final docDir = await getApplicationDocumentsDirectory();
      final coversDir = Directory('${docDir.path}/covers');
      if (!await coversDir.exists()) await coversDir.create(recursive: true);
      final coverFile = File('${coversDir.path}/$bookId.jpg');
      await coverFile.writeAsBytes(coverBytes, flush: true);
      coverPath = coverFile.path;
    }

    final List<dynamic> rawChapters = (res['chaptersHtml'] as List<dynamic>?) ?? [];
    if (rawChapters.isEmpty) {
      throw Exception('El libro EPUB no contiene capítulos legibles.');
    }

    onProgress(45, 'Limpiando capítulos y formateando texto...', '0 / ${rawChapters.length}');
    final List<ChapterItem> chapters = [];
    int chId = 1;

    for (int i = 0; i < rawChapters.length; i++) {
      final String html = rawChapters[i].toString();
      final pct = 45 + ((i / rawChapters.length) * 45).round();
      onProgress(pct, 'Procesando capítulos...', 'Capítulo ${i + 1} de ${rawChapters.length}');

      String chapterTitle = _extractTitleFromHtml(html);
      String cleanText = _convertHtmlToCleanText(html);

      if (_isLegalCopyrightPage(cleanText) || cleanText.trim().length < 50) {
        continue;
      }

      if (chapterTitle.isEmpty) {
        chapterTitle = 'Capítulo ${chId.toString().padLeft(2, '0')}';
      } else if (!RegExp(r'^\d+').hasMatch(chapterTitle)) {
        chapterTitle = '${chId.toString().padLeft(2, '0')}. $chapterTitle';
      }

      final words = cleanText.split(RegExp(r'\s+')).length;
      final mins = max(1, (words / 140).round());

      if (words > 12000) {
        final paragraphs = cleanText.split('\n\n');
        List<String> partBuffer = [];
        int partWords = 0;
        int subPart = 1;

        for (final p in paragraphs) {
          final pWords = p.split(RegExp(r'\s+')).length;
          partBuffer.add(p);
          partWords += pWords;
          if (partWords >= 5000) {
            final partText = partBuffer.join('\n\n');
            final pMins = max(1, (partWords / 140).round());
            chapters.add(
              ChapterItem(
                id: chId++,
                title: '$chapterTitle (Parte $subPart)',
                subtitle: '$pMins min de narración',
                durationText: '$pMins min',
                textContent: partText,
              ),
            );
            partBuffer = [];
            partWords = 0;
            subPart++;
          }
        }
        if (partBuffer.isNotEmpty) {
          final partText = partBuffer.join('\n\n');
          final pMins = max(1, (partWords / 140).round());
          chapters.add(
            ChapterItem(
              id: chId++,
              title: subPart > 1 ? '$chapterTitle (Parte $subPart)' : chapterTitle,
              subtitle: '$pMins min de narración',
              durationText: '$pMins min',
              textContent: partText,
            ),
          );
        }
      } else {
        chapters.add(
          ChapterItem(
            id: chId++,
            title: chapterTitle,
            subtitle: '$mins min de narración',
            durationText: '$mins min',
            textContent: cleanText,
          ),
        );
      }
    }

    if (chapters.isEmpty) {
      throw Exception('No se encontró contenido narrativo en el libro EPUB.');
    }

    onProgress(95, 'Finalizando preparación de libro...', '${chapters.length} capítulos listos');

    String fileNameNoExt = originalFileName;
    if (fileNameNoExt.toLowerCase().endsWith('.epub')) {
      fileNameNoExt = fileNameNoExt.substring(0, fileNameNoExt.length - 5);
    }
    final cleanTitle = CoverHelper.cleanSearchTitle(fileNameNoExt);
    final int totalMins = chapters.fold<int>(0, (sum, c) => sum + (c.estimatedTotalSeconds ~/ 60));
    final String totalTimeFormatted = totalMins >= 60
        ? '${totalMins ~/ 60} h ${totalMins % 60} min'
        : '$totalMins min';

    String? coverUrl;
    if (coverPath == null) {
      coverUrl = await CoverHelper.fetchOnlineCoverUrl(cleanTitle);
    }

    return BookItem(
      id: bookId,
      title: cleanTitle,
      author: 'Libro EPUB Completo',
      coverTag: '📖',
      totalTime: totalTimeFormatted,
      chapters: chapters,
      coverImagePath: coverPath,
      coverUrl: coverUrl,
      originalFilePath: filePath,
      fileType: 'epub',
    );
  }

  static String _extractTitleFromHtml(String html) {
    final h1Match = RegExp(r'<h[1-3][^>]*>(.*?)</h[1-3]>', caseSensitive: false, dotAll: true).firstMatch(html);
    if (h1Match != null) {
      final t = _stripTagsAndEntities(h1Match.group(1) ?? '');
      if (t.trim().isNotEmpty && t.trim().length < 80) return t.trim();
    }
    final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
    if (titleMatch != null) {
      final t = _stripTagsAndEntities(titleMatch.group(1) ?? '');
      if (t.trim().isNotEmpty && !t.toLowerCase().contains('.xhtml') && t.trim().length < 80) {
        return t.trim();
      }
    }
    return '';
  }

  static String _convertHtmlToCleanText(String html) {
    var s = html
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(?:p|div|h[1-6]|li|blockquote)>', caseSensitive: false), '\n\n');

    s = _stripTagsAndEntities(s);
    return _sanitizeExtractedText(s);
  }

  static String _stripTagsAndEntities(String text) {
    var s = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '...')
        .replaceAll('&iexcl;', '¡')
        .replaceAll('&iquest;', '¿')
        .replaceAll('&aacute;', 'á')
        .replaceAll('&eacute;', 'é')
        .replaceAll('&iacute;', 'í')
        .replaceAll('&oacute;', 'ó')
        .replaceAll('&uacute;', 'ú')
        .replaceAll('&ntilde;', 'ñ')
        .replaceAll('&Aacute;', 'Á')
        .replaceAll('&Eacute;', 'É')
        .replaceAll('&Iacute;', 'Í')
        .replaceAll('&Oacute;', 'Ó')
        .replaceAll('&Uacute;', 'Ú')
        .replaceAll('&Ntilde;', 'Ñ');

    s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      try {
        final code = int.parse(m.group(1)!, radix: 16);
        return String.fromCharCode(code);
      } catch (_) {
        return '';
      }
    });

    s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      try {
        final code = int.parse(m.group(1)!);
        return String.fromCharCode(code);
      } catch (_) {
        return '';
      }
    });

    return s;
  }
}

/// Sintetizador acústico de notas de piano y arpa clásica con envolvente ADSR real (0% ruido)
class LoFiGenerator {
  static double _acousticPianoNote(double freq, double noteAge, double duration) {
    if (noteAge < 0 || noteAge > duration) return 0.0;
    // Ataque suave de fieltro de piano (35 ms) + caída exponencial natural de cuerda
    final double attack = (noteAge / 0.035).clamp(0.0, 1.0);
    final double release = ((duration - noteAge) / 0.25).clamp(0.0, 1.0);
    final double decay = exp(-noteAge * 1.65);
    final double env = attack * decay * release;

    // Fundamental pura + segundo y tercer armónico suaves de madera acústica
    final double f1 = sin(2 * pi * freq * noteAge);
    final double f2 = sin(2 * pi * (freq * 2.0) * noteAge) * 0.22 * exp(-noteAge * 2.8);
    final double f3 = sin(2 * pi * (freq * 3.0) * noteAge) * 0.06 * exp(-noteAge * 4.5);
    return (f1 + f2 + f3) * env;
  }

  static Future<String> ensureAmbientTrack(String trackId) async {
    final docDir = await getApplicationDocumentsDirectory();
    final wavFile = File('${docDir.path}/audiomind_classical_${trackId}_v3.wav');
    if (await wavFile.exists() && await wavFile.length() > 40000) {
      return wavFile.path;
    }

    const int sampleRate = 22050;
    const int seconds = 16;
    const int numSamples = sampleRate * seconds;
    const int numChannels = 1;
    const int byteRate = sampleRate * numChannels * 2;
    const int dataSize = numSamples * numChannels * 2;

    final bd = ByteData(44 + dataSize);
    bd.setUint8(0, 0x52);
    bd.setUint8(1, 0x49);
    bd.setUint8(2, 0x46);
    bd.setUint8(3, 0x46);
    bd.setUint32(4, 36 + dataSize, Endian.little);
    bd.setUint8(8, 0x57);
    bd.setUint8(9, 0x41);
    bd.setUint8(10, 0x56);
    bd.setUint8(11, 0x45);
    bd.setUint8(12, 0x66);
    bd.setUint8(13, 0x6D);
    bd.setUint8(14, 0x74);
    bd.setUint8(15, 0x20);
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, numChannels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, numChannels * 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    bd.setUint8(36, 0x64);
    bd.setUint8(37, 0x61);
    bd.setUint8(38, 0x74);
    bd.setUint8(39, 0x61);
    bd.setUint32(40, dataSize, Endian.little);

    // Progresiones de arpegios clásicos limpios (4 compases de 4 segundos = 16s loop perfecto)
    List<List<double>> bars;
    if (trackId == 'classical_adagio') {
      // Satie Gymnopédie (Sol Maj7 -> Re Maj7)
      bars = [
        [196.00, 246.94, 293.66, 369.99, 293.66, 246.94],
        [146.83, 220.00, 277.18, 329.63, 277.18, 220.00],
        [196.00, 246.94, 293.66, 392.00, 369.99, 293.66],
        [146.83, 220.00, 277.18, 369.99, 329.63, 220.00],
      ];
    } else if (trackId == 'debussy_harp') {
      // Preludio cristalino en Do Mayor / La Menor
      bars = [
        [261.63, 329.63, 392.00, 493.88, 523.25, 392.00],
        [220.00, 261.63, 329.63, 392.00, 440.00, 329.63],
        [174.61, 220.00, 261.63, 349.23, 392.00, 261.63],
        [196.00, 246.94, 293.66, 392.00, 329.63, 246.94],
      ];
    } else if (trackId == 'canon_chamber') {
      // Canon en Do (Do -> Sol -> La m -> Fa)
      bars = [
        [130.81, 196.00, 261.63, 329.63, 261.63, 196.00],
        [196.00, 246.94, 293.66, 392.00, 293.66, 246.94],
        [220.00, 261.63, 329.63, 440.00, 329.63, 261.63],
        [174.61, 220.00, 261.63, 349.23, 261.63, 220.00],
      ];
    } else {
      // Nocturno Minimalista (Einaudi - La menor -> Fa -> Do -> Sol)
      bars = [
        [220.00, 329.63, 440.00, 493.88, 523.25, 440.00],
        [174.61, 261.63, 349.23, 440.00, 392.00, 349.23],
        [261.63, 329.63, 392.00, 523.25, 493.88, 392.00],
        [196.00, 293.66, 392.00, 440.00, 392.00, 293.66],
      ];
    }

    for (int i = 0; i < numSamples; i++) {
      final double t = i / sampleRate;
      final int barIdx = ((t / 4.0).floor()) % bars.length;
      final double barTime = t % 4.0;
      final List<double> notes = bars[barIdx];

      double sample = 0.0;

      // Nota bajo de sostén suave durante todo el compás (4 segundos)
      sample += _acousticPianoNote(notes[0] * 0.5, barTime, 3.95) * 0.26;

      // Arpegio melódico nota por nota con pedal de resonancia (cada 0.66 segundos)
      const double stepSec = 4.0 / 6.0;
      for (int n = 0; n < notes.length; n++) {
        final double noteStart = n * stepSec;
        if (barTime >= noteStart) {
          final double age = barTime - noteStart;
          sample += _acousticPianoNote(notes[n], age, 4.0 - noteStart) * 0.30;
        }
      }

      final double total = sample.clamp(-0.88, 0.88);
      final int pcm = (total * 32767).round();
      bd.setInt16(44 + i * 2, pcm, Endian.little);
    }

    await wavFile.writeAsBytes(bd.buffer.asUint8List());
    return wavFile.path;
  }
}

class CoverHelper {
  static String cleanSearchTitle(String rawTitle) {
    var s = rawTitle
        .replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')
        .replaceAll(RegExp(r'_?oceanofpdf\.com_?', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'spanish[_ ]edition', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'libro[_ ]digital', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\(.*?\)'), ' ')
        .replaceAll(RegExp(r'\[.*?\]'), ' ')
        .replaceAll(RegExp(r'[-_ ]*cap(itulo)?[-_ ]*\d+.*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'^\d+[-_ ]+'), '')
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.isEmpty ? rawTitle : s;
  }

  static Future<List<Color>> extractCoverPalette(BookItem book) async {
    try {
      Uint8List? bytes;
      if (book.coverImagePath != null && File(book.coverImagePath!).existsSync()) {
        bytes = await File(book.coverImagePath!).readAsBytes();
      }
      if (bytes != null && bytes.isNotEmpty) {
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 24,
          targetHeight: 24,
        );
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data != null) {
          int r1 = 0, g1 = 0, b1 = 0, count1 = 0;
          int r2 = 0, g2 = 0, b2 = 0, count2 = 0;
          final u8 = data.buffer.asUint8List();
          final half = u8.length ~/ 2;
          for (int i = 0; i < u8.length - 4; i += 4) {
            final r = u8[i];
            final g = u8[i + 1];
            final b = u8[i + 2];
            final lum = (r * 299 + g * 587 + b * 114) ~/ 1000;
            if (lum > 22 && lum < 235) {
              if (i < half) {
                r1 += r;
                g1 += g;
                b1 += b;
                count1++;
              } else {
                r2 += r;
                g2 += g;
                b2 += b;
                count2++;
              }
            }
          }
          if (count1 > 0 && count2 > 0) {
            final c1 = HSLColor.fromColor(
              Color.fromARGB(255, r1 ~/ count1, g1 ~/ count1, b1 ~/ count1),
            );
            final c2 = HSLColor.fromColor(
              Color.fromARGB(255, r2 ~/ count2, g2 ~/ count2, b2 ~/ count2),
            );
            return [
              c1
                  .withSaturation((c1.saturation * 1.4).clamp(0.42, 0.85))
                  .withLightness(0.28)
                  .toColor(),
              c2
                  .withSaturation((c2.saturation * 1.4).clamp(0.38, 0.85))
                  .withLightness(0.18)
                  .toColor(),
            ];
          }
        }
      }
    } catch (_) {}

    final int h = book.title.hashCode.abs();
    final hue1 = (h % 360).toDouble();
    final hue2 = ((h ~/ 7) % 360).toDouble();
    return [
      HSLColor.fromAHSL(1.0, hue1, 0.58, 0.26).toColor(),
      HSLColor.fromAHSL(1.0, hue2, 0.62, 0.18).toColor(),
    ];
  }

  static Future<String?> fetchOnlineCoverUrl(String rawTitle) async {
    try {
      final query = cleanSearchTitle(rawTitle);
      final uri = Uri.parse(
        'https://itunes.apple.com/search?term=${Uri.encodeComponent(query)}&entity=ebook&limit=1',
      );
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          final art = results.first['artworkUrl100'] as String?;
          if (art != null && art.isNotEmpty) {
            return art.replaceAll('100x100bb', '600x600bb');
          }
        }
      }
    } catch (e) {
      debugPrint('Online cover lookup notice: $e');
    }
    return null;
  }

  static Uint8List? extractEmbeddedJpegFromPdf(Uint8List pdfBytes) {
    final limit = min(pdfBytes.length - 4, 1500000);
    int start = -1;
    for (int i = 0; i < limit; i++) {
      if (pdfBytes[i] == 0xFF && pdfBytes[i + 1] == 0xD8 && pdfBytes[i + 2] == 0xFF) {
        start = i;
        break;
      }
    }
    if (start == -1) return null;

    const endstreamBytes = [101, 110, 100, 115, 116, 114, 101, 97, 109];
    int endStreamPos = -1;
    final searchLimit = min(pdfBytes.length - endstreamBytes.length, start + 1200000);
    for (int i = start + 100; i < searchLimit; i++) {
      bool match = true;
      for (int j = 0; j < endstreamBytes.length; j++) {
        if (pdfBytes[i + j] != endstreamBytes[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        endStreamPos = i;
        break;
      }
    }

    if (endStreamPos != -1 && endStreamPos - start > 4000) {
      int actualEnd = endStreamPos;
      while (actualEnd > start &&
          (pdfBytes[actualEnd - 1] == 0x0A ||
              pdfBytes[actualEnd - 1] == 0x0D ||
              pdfBytes[actualEnd - 1] == 0x20)) {
        actualEnd--;
      }
      return Uint8List.sublistView(pdfBytes, start, actualEnd);
    }
    return null;
  }

  static Future<Map<String, String?>> resolveCoverForPdf({
    required String bookId,
    required String bookTitle,
    required Uint8List pdfBytes,
  }) async {
    final docDir = await getApplicationDocumentsDirectory();
    final coverFile = File('${docDir.path}/cover_$bookId.jpg');

    final embeddedJpeg = extractEmbeddedJpegFromPdf(pdfBytes);
    if (embeddedJpeg != null) {
      await coverFile.writeAsBytes(embeddedJpeg);
      return {'path': coverFile.path, 'url': null};
    }

    try {
      final tempPdf = File('${docDir.path}/temp_$bookId.pdf');
      await tempPdf.writeAsBytes(pdfBytes);
      final renderedBytes = await NativeChannelService.channel.invokeMethod<Uint8List>(
        'renderFirstPage',
        {'path': tempPdf.path},
      );
      if (await tempPdf.exists()) {
        await tempPdf.delete();
      }
      if (renderedBytes != null && renderedBytes.length > 1000) {
        await coverFile.writeAsBytes(renderedBytes);
        return {'path': coverFile.path, 'url': null};
      }
    } catch (e) {
      debugPrint('Native PdfRenderer notice: $e');
    }

    final onlineUrl = await fetchOnlineCoverUrl(bookTitle);
    if (onlineUrl != null) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(onlineUrl));
        final res = await req.close().timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final imgBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
          if (imgBytes.length > 1000) {
            await coverFile.writeAsBytes(imgBytes);
            return {'path': coverFile.path, 'url': onlineUrl};
          }
        }
      } catch (_) {}
    }

    return {'path': null, 'url': onlineUrl};
  }
}

class BookCoverWidget extends StatelessWidget {
  final BookItem book;
  final double width;
  final double height;
  final double borderRadius;

  const BookCoverWidget({
    super.key,
    required this.book,
    required this.width,
    required this.height,
    this.borderRadius = 12,
  });

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (book.coverImagePath != null && File(book.coverImagePath!).existsSync()) {
      content = Image.file(
        File(book.coverImagePath!),
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildEditorialFallback(),
      );
    } else if (book.coverUrl != null && book.coverUrl!.isNotEmpty) {
      content = Image.network(
        book.coverUrl!,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildEditorialFallback(),
      );
    } else {
      content = _buildEditorialFallback();
    }

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 22,
            spreadRadius: 2,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: content,
      ),
    );
  }

  Widget _buildEditorialFallback() {
    final cleanTitle = CoverHelper.cleanSearchTitle(book.title);
    return Container(
      width: width,
      height: height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF2C221E),
            Color(0xFF1A1412),
            Color(0xFF3A2818),
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: max(4, width * 0.07),
            child: Container(
              color: const Color(0xFFF5A623).withValues(alpha: 0.7),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(max(8, width * 0.12), 8, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  cleanTitle.toUpperCase(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: const Color(0xFFF5A623),
                    fontWeight: FontWeight.w800,
                    fontSize: max(8, width * 0.11),
                    height: 1.15,
                  ),
                ),
                Text(
                  book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: max(7, width * 0.085),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// PANTALLA PRINCIPAL: BIBLIOTECA CON PERSISTENCIA AL SEGUNDO
// ==========================================
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WidgetsBindingObserver {
  int _activeFilter = 0;
  final List<String> _filters = ['Todos', 'Continuar', 'Terminados', 'Favoritos'];
  List<BookItem> _books = [];
  bool _isLoading = true;

  bool _isProcessingPdf = false;
  int _processingPercent = 0;
  String _processingStatus = '';
  String _processingDetail = '';

  ChapterItem? _currentPlayingChapter;
  BookItem? _currentPlayingBook;
  bool _isPlaying = false;
  bool _userRequestedPause = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativeChannelService.initLoFi();
    globalAudioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
        });
      }
      if (!state.playing || _userRequestedPause) {
        NativeChannelService.pauseLoFi();
      }
    });
    _loadStoredBooksAndLastSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _saveBooks(activeBookId: _currentPlayingBook?.id);
      if (!globalAudioPlayer.playing) {
        _userRequestedPause = true;
        NativeChannelService.pauseLoFi();
      }
    }
  }

  Future<void> _loadStoredBooksAndLastSession() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList('audiomind_books');

    if (jsonList != null && jsonList.isNotEmpty) {
      final loaded = jsonList
          .map((item) => BookItem.fromJson(jsonDecode(item) as Map<String, dynamic>))
          .toList();
      for (final b in loaded) {
        if (b.id == 'oakley_numeros' && (b.coverUrl == null || b.coverUrl!.isEmpty)) {
          b.coverUrl = sampleOakleyBook.coverUrl;
        }
      }
      _books = loaded;
    } else {
      _books = [sampleOakleyBook];
      await _saveBooks();
    }

    final lastBookId = prefs.getString('audiomind_last_book_id');
    if (lastBookId != null && _books.isNotEmpty) {
      final matchIdx = _books.indexWhere((b) => b.id == lastBookId);
      if (matchIdx != -1) {
        final b = _books[matchIdx];
        final chIdx = b.lastChapterIndex.clamp(0, b.chapters.length - 1);
        _currentPlayingBook = b;
        _currentPlayingChapter = b.chapters[chIdx];
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
    _resolveMissingCovers();
  }

  Future<void> _resolveMissingCovers() async {
    bool updated = false;
    final docDir = await getApplicationDocumentsDirectory();

    for (final book in _books) {
      final hasLocal = book.coverImagePath != null && File(book.coverImagePath!).existsSync();
      if (!hasLocal) {
        String? url = book.coverUrl;
        url ??= await CoverHelper.fetchOnlineCoverUrl(book.title);
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

    if (updated && mounted) {
      setState(() {});
      await _saveBooks();
    }
  }

  Future<void> _saveBooks({String? activeBookId}) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _books.map((b) => jsonEncode(b.toJson())).toList();
    await prefs.setStringList('audiomind_books', jsonList);
    if (activeBookId != null) {
      await prefs.setString('audiomind_last_book_id', activeBookId);
    }
  }

  Future<void> _pickAndProcessDocument() async {
    try {
      final typeGroup = XTypeGroup(
        label: 'Libros y Documentos (PDF, EPUB)',
        extensions: const ['pdf', 'epub'],
        mimeTypes: const ['application/pdf', 'application/epub+zip'],
      );

      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;

      final isEpub = file.name.toLowerCase().endsWith('.epub');
      final isPdf = file.name.toLowerCase().endsWith('.pdf');

      if (!isEpub && !isPdf) {
        throw Exception('Formato no soportado. Por favor selecciona un archivo PDF o EPUB.');
      }

      setState(() {
        _isProcessingPdf = true;
        _processingPercent = 2;
        _processingStatus = isEpub ? 'Abriendo archivo EPUB...' : 'Abriendo archivo PDF...';
        _processingDetail = 'Iniciando escaneo inteligente de capítulos';
      });

      final bookId = 'book_${DateTime.now().millisecondsSinceEpoch}';
      final docDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${docDir.path}/books');
      if (!await booksDir.exists()) await booksDir.create(recursive: true);

      final permanentFilePath = '${booksDir.path}/${bookId}_${file.name}';
      final bytes = await file.readAsBytes();
      await File(permanentFilePath).writeAsBytes(bytes, flush: true);

      BookItem newBook;

      if (isEpub) {
        final epubBook = await EpubProcessor.processEpubFile(
          filePath: permanentFilePath,
          bookId: bookId,
          originalFileName: file.name,
          onProgress: (pct, status, detail) {
            if (mounted) {
              setState(() {
                _processingPercent = pct;
                _processingStatus = status;
                _processingDetail = detail;
              });
            }
          },
        );
        if (epubBook == null) {
          throw Exception('No se pudo procesar el contenido del libro EPUB.');
        }
        newBook = epubBook;
      } else {
        String fileName = file.name;
        if (fileName.toLowerCase().endsWith('.pdf')) {
          fileName = fileName.substring(0, fileName.length - 4);
        }
        final bookTitle = CoverHelper.cleanSearchTitle(fileName);

        setState(() {
          _processingPercent = 5;
          _processingStatus = 'Extrayendo portada del libro...';
          _processingDetail = bookTitle;
        });

        final coverData = await CoverHelper.resolveCoverForPdf(
          bookId: bookId,
          bookTitle: bookTitle,
          pdfBytes: bytes,
        );

        final receivePort = ReceivePort();
        final completer = Completer<List<ChapterItem>>();

        receivePort.listen((message) {
          if (message is Map) {
            final type = message['type'];
            if (type == 'progress') {
              final int current = message['current'] as int;
              final int total = message['total'] as int;
              final int pct = message['percent'] as int;
              if (mounted) {
                setState(() {
                  _processingPercent = pct;
                  _processingStatus = 'Detectando capítulos y limpiando texto...';
                  _processingDetail = 'Página $current de $total ($pct%)';
                });
              }
            } else if (type == 'done') {
              final rawList = message['chapters'] as List;
              final chapters = rawList
                  .map((c) => ChapterItem.fromJson(Map<String, dynamic>.from(c as Map)))
                  .toList();
              receivePort.close();
              if (!completer.isCompleted) completer.complete(chapters);
            } else if (type == 'error') {
              receivePort.close();
              if (!completer.isCompleted) {
                completer.completeError(Exception(message['message']));
              }
            }
          }
        });

        await Isolate.spawn(
          _pdfExtractionIsolateEntry,
          _PdfIsolatePayload(bytes, receivePort.sendPort),
        );

        final parsedChapters = await completer.future;

        if (parsedChapters.isEmpty) {
          throw Exception('No se pudo extraer texto seleccionable del PDF.');
        }

        final int totalMins = parsedChapters.fold<int>(
          0,
          (sum, ch) => sum + (ch.estimatedTotalSeconds ~/ 60),
        );
        final String totalTimeFormatted = totalMins >= 60
            ? '${totalMins ~/ 60} h ${totalMins % 60} min'
            : '$totalMins min';

        newBook = BookItem(
          id: bookId,
          title: bookTitle,
          author: 'Audiolibro Completo',
          coverTag: '📚',
          totalTime: totalTimeFormatted,
          chapters: parsedChapters,
          coverImagePath: coverData['path'],
          coverUrl: coverData['url'],
          originalFilePath: permanentFilePath,
          fileType: 'pdf',
        );
      }

      if (mounted) {
        setState(() {
          _processingPercent = 100;
          _processingStatus = '¡Completado al 100%!';
          _processingDetail = '${newBook.chapters.length} capítulos detectados y listos';
          _books.insert(0, newBook);
          _isProcessingPdf = false;
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));

      await _saveBooks(activeBookId: newBook.id);

      if (mounted && newBook.chapters.isNotEmpty) {
        _openPlayer(newBook, newBook.chapters.first, startSegment: 0, startPositionMs: 0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessingPdf = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al procesar libro: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _confirmDeleteBook(BookItem book) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 10),
            Text('¿Eliminar libro?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Text(
          '¿Seguro que deseas eliminar "${book.title}" de tu biblioteca? Se borrará el libro y los audios cacheados.',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteBook(book);
            },
            child: const Text('Eliminar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteBook(BookItem book) async {
    if (_currentPlayingBook?.id == book.id) {
      await globalAudioPlayer.stop();
      await NativeChannelService.pauseLoFi();
      setState(() {
        _currentPlayingBook = null;
        _currentPlayingChapter = null;
        _isPlaying = false;
        _userRequestedPause = true;
      });
    }

    setState(() {
      _books.removeWhere((b) => b.id == book.id);
    });
    await _saveBooks();

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

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${book.title}" eliminado de tu biblioteca'),
          backgroundColor: const Color(0xFF2C2D32),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openDocumentViewer(BookItem book, {int initialChapterIndex = 0}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentViewerScreen(
          book: book,
          player: globalAudioPlayer,
          initialChapterIndex: initialChapterIndex,
          onSeekToPosition: (chIdx, segIdx) {
            if (chIdx < 0 || chIdx >= book.chapters.length) return;
            final targetChapter = book.chapters[chIdx];
            _openPlayer(book, targetChapter, startSegment: segIdx, startPositionMs: 0);
          },
        ),
      ),
    );
  }

  void _openPlayer(
    BookItem book,
    ChapterItem chapter, {
    int? startSegment,
    int? startPositionMs,
  }) {
    final chIdx =
        book.chapters.indexWhere((c) => c.id == chapter.id).clamp(0, book.chapters.length - 1);
    final bool isSameSavedChapter = chIdx == book.lastChapterIndex;
    final int segToStart = startSegment ?? (isSameSavedChapter ? book.lastSegmentIndex : 0);
    final int posMsToStart =
        startPositionMs ?? (isSameSavedChapter ? book.lastPositionMs : 0);

    setState(() {
      _currentPlayingBook = book;
      _currentPlayingChapter = chapter;
    });
    _saveBooks(activeBookId: book.id);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          book: book,
          initialChapter: chapter,
          initialSegmentIndex: segToStart,
          initialPositionMs: posMsToStart,
          player: globalAudioPlayer,
          onProgressUpdated: (updatedChapter, segIdx, totalSegs, posMs) {
            final idx = book.chapters.indexWhere((c) => c.id == updatedChapter.id);
            if (idx != -1) {
              book.lastChapterIndex = idx;
              book.lastSegmentIndex = segIdx;
              book.lastPositionMs = posMs;
              book.totalSegmentsInLastChapter = max(1, totalSegs);
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _currentPlayingBook = book;
                  _currentPlayingChapter = updatedChapter;
                });
              }
              _saveBooks(activeBookId: book.id);
            });
          },
        ),
      ),
    );
  }

  List<BookItem> get _filteredBooks {
    if (_activeFilter == 1) {
      return _books.where((b) => b.hasStarted && !b.isCompleted).toList();
    } else if (_activeFilter == 2) {
      return _books.where((b) => b.isCompleted).toList();
    } else if (_activeFilter == 3) {
      return _books.where((b) => b.isFavorite).toList();
    }
    return _books;
  }

  @override
  Widget build(BuildContext context) {
    final visibleBooks = _filteredBooks;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Mi Biblioteca',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 25, letterSpacing: -0.5),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFF5A623),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _pickAndProcessDocument,
              icon: const Icon(Icons.add_circle_outline_rounded, size: 19),
              label: const Text(
                'Cargar PDF / EPUB',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: List.generate(_filters.length, (index) {
                    final isSelected = _activeFilter == index;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          _filters[index],
                          style: TextStyle(
                            color: isSelected ? Colors.black : Colors.white70,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: const Color(0xFFF5A623),
                        backgroundColor: const Color(0xFF1E1E1E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(
                            color: isSelected ? const Color(0xFFF5A623) : Colors.transparent,
                          ),
                        ),
                        onSelected: (val) {
                          setState(() => _activeFilter = index);
                        },
                      ),
                    );
                  }),
                ),
              ),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFF5A623)))
                    : visibleBooks.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.menu_book_rounded,
                                    size: 52, color: Colors.white24),
                                const SizedBox(height: 12),
                                const Text(
                                  'No hay libros en esta sección todavía',
                                  style: TextStyle(color: Colors.white54, fontSize: 15),
                                ),
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _pickAndProcessDocument,
                                  icon: const Icon(Icons.upload_file_rounded,
                                      color: Color(0xFFF5A623)),
                                  label: const Text(
                                    'Importar libro (PDF o EPUB)',
                                    style: TextStyle(color: Color(0xFFF5A623)),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                            itemCount: visibleBooks.length,
                            itemBuilder: (context, index) {
                              final book = visibleBooks[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: _buildBookCard(book),
                              );
                            },
                          ),
              ),
              if (_currentPlayingChapter != null && _currentPlayingBook != null)
                _buildMiniPlayer(_currentPlayingBook!, _currentPlayingChapter!),
            ],
          ),
          if (_isProcessingPdf)
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Center(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFF5A623), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF5A623).withValues(alpha: 0.15),
                        blurRadius: 24,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 84,
                            height: 84,
                            child: CircularProgressIndicator(
                              value: _processingPercent / 100.0,
                              color: const Color(0xFFF5A623),
                              backgroundColor: Colors.white12,
                              strokeWidth: 7,
                            ),
                          ),
                          Text(
                            '$_processingPercent%',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFFF5A623),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Text(
                        _processingStatus,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: _processingPercent / 100.0,
                          minHeight: 10,
                          color: const Color(0xFFF5A623),
                          backgroundColor: Colors.white12,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _processingDetail,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBookCard(BookItem book) {
    final int resumeChapIdx = book.lastChapterIndex.clamp(0, book.chapters.length - 1);
    final ChapterItem targetChapter = book.chapters[resumeChapIdx];
    final double prog = book.overallProgress;
    final int pct = (prog * 100).round();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1B1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: book.hasStarted
              ? const Color(0xFFF5A623).withValues(alpha: 0.35)
              : const Color(0xFF2C2C2C),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _openPlayer(
            book,
            targetChapter,
            startSegment: book.lastSegmentIndex,
            startPositionMs: book.lastPositionMs,
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    BookCoverWidget(
                      book: book,
                      width: 70,
                      height: 102,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  book.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    height: 1.2,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  setState(() => book.isFavorite = !book.isFavorite);
                                  _saveBooks();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(
                                    book.isFavorite
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_border_rounded,
                                    size: 20,
                                    color: book.isFavorite
                                        ? const Color(0xFFF5A623)
                                        : Colors.white38,
                                  ),
                                ),
                              ),
                              PopupMenuButton<String>(
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  Icons.more_vert_rounded,
                                  size: 20,
                                  color: Colors.white54,
                                ),
                                color: const Color(0xFF22242A),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  side: const BorderSide(color: Colors.white12),
                                ),
                                onSelected: (val) {
                                  if (val == 'view') {
                                    _openDocumentViewer(book);
                                  } else if (val == 'delete') {
                                    _confirmDeleteBook(book);
                                  }
                                },
                                itemBuilder: (ctx) => [
                                  PopupMenuItem(
                                    value: 'view',
                                    child: Row(
                                      children: [
                                        const Icon(Icons.auto_stories_rounded,
                                            color: Color(0xFFF5A623), size: 18),
                                        const SizedBox(width: 10),
                                        Text(
                                          book.fileType == 'epub'
                                              ? 'Ver / Leer EPUB'
                                              : 'Ver / Leer PDF',
                                          style: const TextStyle(fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_outline_rounded,
                                            color: Colors.redAccent, size: 18),
                                        SizedBox(width: 10),
                                        Text(
                                          'Eliminar libro',
                                          style: TextStyle(
                                              color: Colors.redAccent, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            book.author,
                            style: const TextStyle(color: Colors.white60, fontSize: 12.5),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF5A623).withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${book.chapters.length} caps',
                                  style: const TextStyle(
                                    color: Color(0xFFF5A623),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Icon(Icons.schedule, size: 14, color: Colors.white38),
                              const SizedBox(width: 4),
                              Text(
                                book.totalTime,
                                style: const TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(
                        Icons.play_circle_fill_rounded,
                        size: 46,
                        color: Color(0xFFF5A623),
                      ),
                      tooltip: book.hasStarted ? 'Continuar audiolibro' : 'Reproducir audiolibro',
                      onPressed: () => _openPlayer(
                        book,
                        targetChapter,
                        startSegment: book.lastSegmentIndex,
                        startPositionMs: book.lastPositionMs,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: max(0.02, prog),
                    minHeight: 5,
                    color: const Color(0xFFF5A623),
                    backgroundColor: Colors.white10,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        book.hasStarted
                            ? 'Retomar: ${targetChapter.title} (Párr. ${book.lastSegmentIndex + 1})'
                            : 'Listo para escuchar (${book.totalTime})',
                        style: TextStyle(
                          color: book.hasStarted ? Colors.white70 : Colors.white38,
                          fontSize: 11.5,
                          fontWeight: book.hasStarted ? FontWeight.w600 : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$pct% completado',
                      style: const TextStyle(
                        color: Color(0xFFF5A623),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniPlayer(BookItem book, ChapterItem chapter) {
    final double bookProg = book.overallProgress;

    return GestureDetector(
      onTap: () => _openPlayer(
        book,
        chapter,
        startSegment: book.lastSegmentIndex,
        startPositionMs: book.lastPositionMs,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF17181C),
          border: const Border(top: BorderSide(color: Color(0xFF2E3038))),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.65),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: max(0.02, bookProg),
                minHeight: 3,
                color: const Color(0xFFF5A623),
                backgroundColor: Colors.white12,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    BookCoverWidget(
                      book: book,
                      width: 44,
                      height: 60,
                      borderRadius: 8,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            chapter.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${book.title} • ${(bookProg * 100).round()}% del libro',
                            style: const TextStyle(color: Colors.white60, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _isPlaying
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_filled_rounded,
                        size: 42,
                        color: const Color(0xFFF5A623),
                      ),
                      onPressed: () {
                        if (globalAudioPlayer.audioSource == null) {
                          _openPlayer(
                            book,
                            chapter,
                            startSegment: book.lastSegmentIndex,
                            startPositionMs: book.lastPositionMs,
                          );
                        } else if (_isPlaying) {
                          _userRequestedPause = true;
                          NativeChannelService.pauseLoFi();
                          globalAudioPlayer.pause();
                        } else {
                          _userRequestedPause = false;
                          globalAudioPlayer.play();
                          NativeChannelService.playLoFi();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// PANTALLA REPRODUCTOR MINIMALISTA PREMIUM (KARAOKE DORADO/ÁMBAR + CLÁSICA ARMÓNICA + VOZ HD)
// ==========================================
class PlayerScreen extends StatefulWidget {
  final BookItem book;
  final ChapterItem initialChapter;
  final int initialSegmentIndex;
  final int initialPositionMs;
  final AudioPlayer player;
  final void Function(
    ChapterItem chapter,
    int segmentIndex,
    int totalSegments,
    int positionMs,
  )? onProgressUpdated;

  const PlayerScreen({
    super.key,
    required this.book,
    required this.initialChapter,
    this.initialSegmentIndex = 0,
    this.initialPositionMs = 0,
    required this.player,
    this.onProgressUpdated,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late ChapterItem _currentChapter;
  // 0 = Modo Portada (YouTube Premium), 1 = Modo Texto Karaoke Minimalista
  int _viewMode = 0;

  double _playbackSpeed = 1.0;
  double _ambientVolume = 0.25;
  String _selectedAmbientTrackId = NativeChannelService.currentTrackId;
  String _selectedVoiceKey = 'es-MX-JorgeNeural';
  String _selectedVoiceName = 'Jorge HD (México 🇲🇽)';

  bool _isPlaying = false;
  bool _userRequestedPause = false;
  double? _draggingSliderSec;
  bool _isSynthesizing = false;
  String _statusMessage = '';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  List<String> _segments = [];
  int _currentSegmentIndex = 0;
  int _synthesisGeneration = 0;
  int _lastSavedSecond = -1;

  final Map<String, List<WordTimingItem>> _segmentWordTimings = {};
  final Map<String, Future<File>> _inFlightSynthesis = {};
  final Map<int, GlobalKey> _segmentKeys = {};
  int _lastAutoScrolledSegment = -1;

  List<Color> _ambientColors = [
    const Color(0xFF3E2723),
    const Color(0xFF1B263B),
  ];
  late AnimationController _ambientAnimController;

  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  // Voces Neuronales HD de 96 kbps con prosodia cálida natural
  final Map<String, String> _voicesMap = {
    'es-MX-JorgeNeural': 'Jorge HD (México 🇲🇽 • Cálido)',
    'es-AR-TomasNeural': 'Tomás HD (Argentina 🇦🇷 • Natural)',
    'es-AR-ElenaNeural': 'Elena HD (Argentina 🇦🇷 • Suave)',
    'es-ES-TristanMultilingualNeural': 'Tristán DragonHD (Multilingüe 🎙️)',
    'es-ES-XimenaMultilingualNeural': 'Ximena DragonHD (Multilingüe 🎙️)',
    'es-CO-GonzaloNeural': 'Gonzalo HD (Colombia 🇨🇴 • Narrador)',
    'es-ES-AlvaroNeural': 'Álvaro HD (España 🇪🇸 • Profundo)',
    'es-MX-DaliaNeural': 'Dalia HD (México 🇲🇽 • Clara)',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentChapter = widget.initialChapter;
    _ambientAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 9),
    )..repeat(reverse: true);

    _loadCoverAmbientPalette();
    _setupAudioStreams();
    _startChapterPlayback(
      _currentChapter,
      startSegment: widget.initialSegmentIndex,
      initialSeekMs: widget.initialPositionMs,
    );
  }

  Future<void> _loadCoverAmbientPalette() async {
    final colors = await CoverHelper.extractCoverPalette(widget.book);
    if (mounted) {
      setState(() {
        _ambientColors = colors;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveExactPositionNow();
    _synthesisGeneration++;
    _ambientAnimController.dispose();
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _saveExactPositionNow();
      if (!_isPlaying) {
        NativeChannelService.pauseLoFi();
      }
    }
  }

  void _saveExactPositionNow() {
    widget.onProgressUpdated?.call(
      _currentChapter,
      _currentSegmentIndex,
      _segments.length,
      _position.inMilliseconds,
    );
  }

  void _setupAudioStreams() {
    _playerStateSub = widget.player.playerStateStream.listen((state) {
      if (!mounted) return;
      if (_userRequestedPause) {
        NativeChannelService.pauseLoFi();
        if (_isPlaying) {
          setState(() => _isPlaying = false);
        }
        return;
      }
      setState(() => _isPlaying = state.playing);

      // Sincronización estricta: si la voz se detiene o pausa, la música de fondo TAMBIÉN se detiene al instante
      if (state.playing && !_isSynthesizing && _ambientVolume > 0) {
        NativeChannelService.setLoFiVolume(_ambientVolume);
        NativeChannelService.playLoFi();
      } else {
        NativeChannelService.pauseLoFi();
      }

      if (state.processingState == ProcessingState.completed) {
        _onSegmentCompleted();
      }
    });

    _positionSub = widget.player.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
      // Guardar cada 2 segundos el progreso exacto para que al apagar el celu o cerrar la app retome ahí mismo
      final sec = pos.inSeconds;
      if (sec != _lastSavedSecond && sec % 2 == 0) {
        _lastSavedSecond = sec;
        _saveExactPositionNow();
      }
    });

    _durationSub = widget.player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
  }

  List<String> _splitIntoSegments(String rawText) {
    final cleaned = _sanitizeExtractedText(rawText)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return ['Capítulo listo para reproducir.'];

    final sentences = cleaned.split(RegExp(r'(?<=[.!?])\s+'));
    final List<String> result = [];
    StringBuffer current = StringBuffer();

    for (final sentence in sentences) {
      final sTrim = sentence.trim();
      if (sTrim.isEmpty) continue;
      if (current.length + sTrim.length > 420 && current.isNotEmpty) {
        result.add(current.toString().trim());
        current.clear();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(sTrim);
    }
    if (current.isNotEmpty) {
      result.add(current.toString().trim());
    }
    return result.isEmpty ? [cleaned] : result;
  }

  String _segmentKeyId(ChapterItem chapter, int segIdx, String voiceKey) {
    return '${widget.book.id}_ch${chapter.id}_s${segIdx}_${voiceKey}_hd96';
  }

  Future<File> _getSegmentFile(ChapterItem chapter, int segIdx, String voiceKey) async {
    final docDir = await getApplicationDocumentsDirectory();
    final key = _segmentKeyId(chapter, segIdx, voiceKey);
    return File('${docDir.path}/$key.mp3');
  }

  Future<File> _getSegmentWordsFile(ChapterItem chapter, int segIdx, String voiceKey) async {
    final docDir = await getApplicationDocumentsDirectory();
    final key = _segmentKeyId(chapter, segIdx, voiceKey);
    return File('${docDir.path}/$key.words.json');
  }

  Future<File> _synthesizeSegment(
    ChapterItem chapter,
    int segIdx,
    String text,
    String voiceKey,
  ) {
    final key = _segmentKeyId(chapter, segIdx, voiceKey);
    if (_inFlightSynthesis.containsKey(key)) {
      return _inFlightSynthesis[key]!;
    }

    final future = _doSynthesizeSegment(chapter, segIdx, text, voiceKey).whenComplete(() {
      _inFlightSynthesis.remove(key);
    });
    _inFlightSynthesis[key] = future;
    return future;
  }

  Future<File> _doSynthesizeSegment(
    ChapterItem chapter,
    int segIdx,
    String text,
    String voiceKey,
  ) async {
    final key = _segmentKeyId(chapter, segIdx, voiceKey);
    final finalFile = await _getSegmentFile(chapter, segIdx, voiceKey);
    final wordsFile = await _getSegmentWordsFile(chapter, segIdx, voiceKey);

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

    // Humanización gramatical y prosodia cálida (-3% ritmo pausado natural y -2Hz cuerpo de voz)
    final cleanSpeakText = _humanizeTextForNaturalSpeech(text);
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

  Future<void> _startChapterPlayback(
    ChapterItem chapter, {
    int startSegment = 0,
    int initialSeekMs = 0,
  }) async {
    _userRequestedPause = false;
    final gen = ++_synthesisGeneration;
    NativeChannelService.pauseLoFi();
    await widget.player.stop();

    final segs = _splitIntoSegments(chapter.textContent);
    _segmentKeys.clear();
    for (int i = 0; i < segs.length; i++) {
      _segmentKeys[i] = GlobalKey();
    }

    final int safeSeg = startSegment.clamp(0, max<int>(0, segs.length - 1)).toInt();
    setState(() {
      _currentChapter = chapter;
      _segments = segs;
      _currentSegmentIndex = safeSeg;
      _isSynthesizing = true;
      _statusMessage = 'Preparando voz HD (${_selectedVoiceName.split(' ').first})...';
    });

    widget.onProgressUpdated?.call(chapter, safeSeg, segs.length, initialSeekMs);
    await _playSegmentAtIndex(safeSeg, gen, seekToMs: initialSeekMs);
  }

  void _scrollToCurrentSegment(int index) {
    if (_viewMode != 1) return;
    if (_lastAutoScrolledSegment == index) return;
    _lastAutoScrolledSegment = index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _segmentKeys[index];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          alignment: 0.25,
        );
      }
    });
  }

  Future<void> _playSegmentAtIndex(int index, int gen, {int seekToMs = 0}) async {
    if (gen != _synthesisGeneration || !mounted) return;
    if (index < 0 || index >= _segments.length) return;

    setState(() {
      _currentSegmentIndex = index;
      _isSynthesizing = true;
    });
    widget.onProgressUpdated?.call(_currentChapter, index, _segments.length, seekToMs);
    _scrollToCurrentSegment(index);

    final voiceKey = _selectedVoiceKey;
    final chapter = _currentChapter;

    try {
      final audioFile = await _synthesizeSegment(
        chapter,
        index,
        _segments[index],
        voiceKey,
      );

      if (gen != _synthesisGeneration || !mounted) return;

      Uri? artUri;
      if (widget.book.coverImagePath != null &&
          File(widget.book.coverImagePath!).existsSync()) {
        artUri = Uri.file(widget.book.coverImagePath!);
      } else if (widget.book.coverUrl != null) {
        artUri = Uri.parse(widget.book.coverUrl!);
      }

      await widget.player.setAudioSource(
        AudioSource.uri(
          Uri.file(audioFile.path),
          tag: MediaItem(
            id: '${widget.book.id}_${chapter.id}_$index',
            album: widget.book.title,
            title: '${chapter.title} (${index + 1}/${_segments.length})',
            artist: widget.book.author,
            artUri: artUri,
          ),
        ),
      );

      if (seekToMs > 500) {
        await widget.player.seek(Duration(milliseconds: seekToMs));
      }

      await widget.player.setSpeed(_playbackSpeed);
      try {
        await widget.player.setPitch(1.0);
      } catch (_) {}

      setState(() {
        _isSynthesizing = false;
        _statusMessage = '';
      });

      if (_userRequestedPause || gen != _synthesisGeneration || !mounted) {
        return;
      }

      await widget.player.play();
      if (_ambientVolume > 0 && !_userRequestedPause) {
        NativeChannelService.setLoFiVolume(_ambientVolume);
        NativeChannelService.playLoFi();
      }

      _prefetchNextSegments(chapter, index + 1, voiceKey, gen);
    } catch (e) {
      if (!mounted || gen != _synthesisGeneration) return;
      if (index + 1 < _segments.length && !_userRequestedPause) {
        _playSegmentAtIndex(index + 1, gen);
        return;
      }
      setState(() {
        _isSynthesizing = false;
        _statusMessage = '';
      });
    }
  }

  Future<void> _prefetchNextSegments(
    ChapterItem chapter,
    int startIdx,
    String voiceKey,
    int gen,
  ) async {
    for (int i = startIdx; i < min(_segments.length, startIdx + 8); i++) {
      if (gen != _synthesisGeneration || !mounted || _userRequestedPause) return;
      try {
        await _synthesizeSegment(chapter, i, _segments[i], voiceKey);
      } catch (_) {}
    }
    if (startIdx + 3 >= _segments.length) {
      final chIdx = widget.book.chapters.indexWhere((c) => c.id == chapter.id);
      if (chIdx != -1 && chIdx + 1 < widget.book.chapters.length) {
        final nextCh = widget.book.chapters[chIdx + 1];
        final nextSegs = _splitIntoSegments(nextCh.textContent);
        for (int k = 0; k < min(2, nextSegs.length); k++) {
          if (gen != _synthesisGeneration || !mounted || _userRequestedPause) return;
          try {
            await _synthesizeSegment(nextCh, k, nextSegs[k], voiceKey);
          } catch (_) {}
        }
      }
    }
  }

  void _onSegmentCompleted() {
    if (_isSynthesizing) return;
    if (_currentSegmentIndex + 1 < _segments.length) {
      _playSegmentAtIndex(_currentSegmentIndex + 1, _synthesisGeneration);
    } else {
      final idx = widget.book.chapters.indexWhere((c) => c.id == _currentChapter.id);
      if (idx != -1 && idx + 1 < widget.book.chapters.length) {
        _startChapterPlayback(widget.book.chapters[idx + 1], startSegment: 0);
      } else {
        NativeChannelService.pauseLoFi();
      }
    }
  }

  Duration get _chapterElapsedPosition {
    if (_segments.isEmpty) return Duration.zero;
    final totalSec = _currentChapter.estimatedTotalSeconds;
    final secPerSeg = totalSec / _segments.length;
    final baseSec = (_currentSegmentIndex * secPerSeg).round();
    return Duration(seconds: baseSec + _position.inSeconds);
  }

  Duration get _fullBookTotalDuration {
    return Duration(seconds: max(60, widget.book.estimatedBookTotalSeconds));
  }

  Duration get _fullBookElapsedPosition {
    int secBefore = 0;
    for (final ch in widget.book.chapters) {
      if (ch.id == _currentChapter.id) break;
      secBefore += ch.estimatedTotalSeconds;
    }
    return Duration(seconds: secBefore + _chapterElapsedPosition.inSeconds);
  }

  void _seekAcrossFullBook(double targetSeconds) {
    _userRequestedPause = false;
    int acc = 0;
    for (final ch in widget.book.chapters) {
      final chSec = ch.estimatedTotalSeconds;
      if (targetSeconds <= acc + chSec || ch == widget.book.chapters.last) {
        final localSec = (targetSeconds - acc).clamp(0.0, chSec.toDouble());
        final localRatio = (localSec / max(1, chSec)).clamp(0.0, 0.999);
        final segs = _splitIntoSegments(ch.textContent);
        final targetSeg = (localRatio * segs.length).floor();
        if (ch.id == _currentChapter.id) {
          _playSegmentAtIndex(targetSeg, _synthesisGeneration);
        } else {
          _startChapterPlayback(ch, startSegment: targetSeg);
        }
        return;
      }
      acc += chSec;
    }
  }

  int _getActiveWordIndexForCurrentSegment(List<String> tokens) {
    if (tokens.isEmpty) return -1;
    final posMs = _position.inMilliseconds;
    final key = _segmentKeyId(_currentChapter, _currentSegmentIndex, _selectedVoiceKey);
    final timings = _segmentWordTimings[key];

    if (timings != null && timings.isNotEmpty) {
      int eventIdx = -1;
      for (int i = 0; i < timings.length; i++) {
        if (posMs >= timings[i].startMs - 40) {
          eventIdx = i;
        } else {
          break;
        }
      }
      if (eventIdx == -1) return 0;
      if (timings.length == tokens.length) {
        return eventIdx.clamp(0, tokens.length - 1);
      }
      final ratio = eventIdx / max(1, timings.length - 1);
      return (ratio * (tokens.length - 1)).round().clamp(0, tokens.length - 1);
    }

    final totalMs = max(1200, _duration.inMilliseconds);
    final progress = (posMs / totalMs).clamp(0.0, 0.999);
    int totalChars = 0;
    for (final t in tokens) {
      totalChars += t.length + 1;
    }
    final targetChar = (progress * totalChars).round();
    int running = 0;
    for (int i = 0; i < tokens.length; i++) {
      running += tokens[i].length + 1;
      if (running >= targetChar) return i;
    }
    return tokens.length - 1;
  }

  /// Escala de velocidades finas y naturales con preservación de tono (sin el 2.0x acelerado robótico)
  void _cycleSpeed() {
    final speeds = [0.9, 1.0, 1.1, 1.2, 1.35];
    final currentIdx = speeds.indexWhere((s) => (s - _playbackSpeed).abs() < 0.03);
    final nextIndex = (currentIdx + 1) % speeds.length;
    setState(() {
      _playbackSpeed = speeds[nextIndex];
    });
    widget.player.setSpeed(_playbackSpeed);
    try {
      widget.player.setPitch(1.0);
    } catch (_) {}
  }

  /// Pausa / Play sincronizado: detiene AMBOS (voz + música clásica de fondo) y guarda la posición exacta
  void _togglePlayPause() {
    if (_isSynthesizing) {
      _userRequestedPause = true;
      _synthesisGeneration++;
      NativeChannelService.pauseLoFi();
      widget.player.pause();
      setState(() {
        _isSynthesizing = false;
        _isPlaying = false;
        _statusMessage = 'Pausado';
      });
      _saveExactPositionNow();
      return;
    }

    if (_isPlaying) {
      _userRequestedPause = true;
      NativeChannelService.pauseLoFi();
      widget.player.pause();
      setState(() {
        _isPlaying = false;
      });
      _saveExactPositionNow();
    } else {
      _userRequestedPause = false;
      widget.player.play();
      if (_ambientVolume > 0) {
        NativeChannelService.setLoFiVolume(_ambientVolume);
        NativeChannelService.playLoFi();
      }
    }
  }

  void _showLoFiModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16181D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.65,
              minChildSize: 0.48,
              maxChildSize: 0.85,
              builder: (_, scrollController) {
                return ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 30),
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.piano_rounded, color: Color(0xFFF5A623), size: 24),
                            SizedBox(width: 10),
                            Text(
                              'Música Clásica Instrumental',
                              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                            ),
                          ],
                        ),
                        Switch(
                          value: _ambientVolume > 0,
                          activeThumbColor: const Color(0xFFF5A623),
                          onChanged: (enabled) {
                            final newVol = enabled ? 0.25 : 0.0;
                            setModalState(() {});
                            setState(() => _ambientVolume = newVol);
                            if (newVol > 0 && _isPlaying) {
                              NativeChannelService.selectAndPlayTrack(
                                _selectedAmbientTrackId,
                                newVol,
                                shouldPlayNow: true,
                              );
                            } else {
                              NativeChannelService.setLoFiVolume(newVol);
                              NativeChannelService.pauseLoFi();
                            }
                          },
                        ),
                      ],
                    ),
                    const Text(
                      'Arpegios acústicos puros de piano y arpa sin ruido de fondo. Se pausa automáticamente al pausar la lectura.',
                      style: TextStyle(color: Colors.white60, fontSize: 12.5),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                _ambientVolume > 0
                                    ? Icons.volume_up_rounded
                                    : Icons.volume_off_rounded,
                                color: const Color(0xFFF5A623),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _ambientVolume,
                                  min: 0.0,
                                  max: 1.0,
                                  activeColor: const Color(0xFFF5A623),
                                  inactiveColor: Colors.white12,
                                  onChanged: (val) {
                                    setModalState(() {});
                                    setState(() => _ambientVolume = val);
                                    NativeChannelService.setLoFiVolume(val);
                                    if (val > 0 && _isPlaying) {
                                      NativeChannelService.playLoFi();
                                    } else if (val == 0) {
                                      NativeChannelService.pauseLoFi();
                                    }
                                  },
                                ),
                              ),
                              SizedBox(
                                width: 46,
                                child: Text(
                                  '${(_ambientVolume * 100).round()}%',
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    color: Color(0xFFF5A623),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildVolumePresetChip('Silencio', 0.0, setModalState),
                              _buildVolumePresetChip('Sutil 15%', 0.15, setModalState),
                              _buildVolumePresetChip('Armónico 30%', 0.30, setModalState),
                              _buildVolumePresetChip('Envolvente 55%', 0.55, setModalState),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ...kAmbientTracks.map((track) {
                      final isSelected = _selectedAmbientTrackId == track.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            final vol = _ambientVolume > 0 ? _ambientVolume : 0.25;
                            setModalState(() {
                              _selectedAmbientTrackId = track.id;
                              _ambientVolume = vol;
                            });
                            setState(() {
                              _selectedAmbientTrackId = track.id;
                              _ambientVolume = vol;
                            });
                            NativeChannelService.selectAndPlayTrack(
                              track.id,
                              vol,
                              shouldPlayNow: _isPlaying,
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFFF5A623).withValues(alpha: 0.15)
                                  : Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFFF5A623)
                                    : Colors.white12,
                                width: isSelected ? 1.4 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 21,
                                  backgroundColor: isSelected
                                      ? const Color(0xFFF5A623)
                                      : Colors.white10,
                                  child: Icon(
                                    track.icon,
                                    color: isSelected ? Colors.black : Colors.white70,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        track.title,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                          color: isSelected
                                              ? const Color(0xFFF5A623)
                                              : Colors.white,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        track.subtitle,
                                        style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isSelected
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  color: isSelected
                                      ? const Color(0xFFF5A623)
                                      : Colors.white38,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildVolumePresetChip(String label, double val, StateSetter setModalState) {
    final bool active = (_ambientVolume - val).abs() < 0.04;
    return InkWell(
      onTap: () {
        setModalState(() {});
        setState(() => _ambientVolume = val);
        NativeChannelService.setLoFiVolume(val);
        if (val > 0 && _isPlaying) {
          NativeChannelService.playLoFi();
        } else if (val == 0) {
          NativeChannelService.pauseLoFi();
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFF5A623) : Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            color: active ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  void _showVoicesModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1B1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Narradores Neuronales HD (96 kbps)',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 4),
              const Text(
                'Entonación humana con pausas respiratorias naturales en español',
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: _voicesMap.entries.map((entry) {
                      final isSelected = _selectedVoiceKey == entry.key;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: isSelected
                              ? const Color(0xFFF5A623)
                              : const Color(0xFF2C2D32),
                          child: Icon(
                            Icons.record_voice_over,
                            color: isSelected ? Colors.black : Colors.white,
                          ),
                        ),
                        title: Text(
                          entry.value,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? const Color(0xFFF5A623) : Colors.white,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check_circle_rounded, color: Color(0xFFF5A623))
                            : null,
                        onTap: () {
                          setState(() {
                            _selectedVoiceKey = entry.key;
                            _selectedVoiceName = entry.value;
                          });
                          Navigator.pop(context);
                          _startChapterPlayback(
                            _currentChapter,
                            startSegment: _currentSegmentIndex,
                          );
                        },
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showChaptersModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF18191D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.70,
          minChildSize: 0.45,
          maxChildSize: 0.90,
          builder: (_, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Capítulos (${widget.book.chapters.length})',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const SizedBox(height: 4),
                Text(
                  'Duración total del libro: ${widget.book.totalTime}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                ...widget.book.chapters.map((ch) {
                  final isCurrent = _currentChapter.id == ch.id;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: isCurrent
                          ? const Color(0xFFF5A623)
                          : const Color(0xFF2A2A2A),
                      child: Text(
                        ch.id.toString().padLeft(2, '0'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isCurrent ? Colors.black : Colors.white70,
                        ),
                      ),
                    ),
                    title: Text(
                      ch.title,
                      style: TextStyle(
                        color: isCurrent ? const Color(0xFFF5A623) : Colors.white,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      ch.subtitle,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing: Text(
                      ch.durationText,
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _startChapterPlayback(ch, startSegment: 0);
                    },
                  );
                }),
              ],
            );
          },
        );
      },
    );
  }

  void _openDocumentViewer() {
    final curIdx = widget.book.chapters
        .indexWhere((c) => c.id == _currentChapter.id)
        .clamp(0, max<int>(0, widget.book.chapters.length - 1))
        .toInt();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentViewerScreen(
          book: widget.book,
          player: widget.player,
          initialChapterIndex: curIdx,
          onSeekToPosition: (chIdx, segIdx) {
            if (chIdx < 0 || chIdx >= widget.book.chapters.length) return;
            final targetCh = widget.book.chapters[chIdx];
            if (targetCh.id == _currentChapter.id) {
              _playSegmentAtIndex(segIdx, _synthesisGeneration);
            } else {
              _startChapterPlayback(targetCh, startSegment: segIdx);
            }
          },
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Container(
              height: 38,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildModePillButton(
                    index: 0,
                    icon: Icons.headphones_rounded,
                    label: 'Portada',
                  ),
                  _buildModePillButton(
                    index: 1,
                    icon: Icons.menu_book_rounded,
                    label: 'Texto',
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.auto_stories_rounded,
                      size: 24, color: Color(0xFFF5A623)),
                  tooltip:
                      'Ver libro original (${widget.book.fileType?.toUpperCase() ?? 'PDF'})',
                  onPressed: _openDocumentViewer,
                ),
                IconButton(
                  icon: const Icon(Icons.queue_music_rounded, size: 26, color: Colors.white),
                  tooltip: 'Capítulos',
                  onPressed: _showChaptersModal,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModePillButton({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final bool selected = _viewMode == index;
    return GestureDetector(
      onTap: () {
        setState(() {
          _viewMode = index;
          _lastAutoScrolledSegment = -1;
        });
        if (index == 1) {
          _scrollToCurrentSegment(_currentSegmentIndex);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF5A623) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? Colors.black : Colors.white60,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? Colors.black : Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// VISTA 1: MODO PORTADA YOUTUBE PREMIUM
  Widget _buildCoverModeView() {
    final activeTrack = kAmbientTracks.firstWhere(
      (t) => t.id == _selectedAmbientTrackId,
      orElse: () => kAmbientTracks.first,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxH = constraints.maxHeight;
        final double maxW = constraints.maxWidth;
        final double coverWidth = min(maxW * 0.72, maxH * 0.48).clamp(155.0, 285.0);
        final double coverHeight = (coverWidth * 1.38).clamp(205.0, 370.0);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 26),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: AnimatedScale(
                  scale: _isPlaying ? 1.0 : 0.94,
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutBack,
                  child: BookCoverWidget(
                    book: widget.book,
                    width: coverWidth,
                    height: coverHeight,
                    borderRadius: 18,
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: _showChaptersModal,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _currentChapter.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -0.4,
                              height: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 26),
                      ],
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _statusMessage.isNotEmpty
                        ? _statusMessage
                        : '${widget.book.title} • ${_currentChapter.subtitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: _statusMessage.isNotEmpty
                          ? const Color(0xFFF5A623)
                          : Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildYouTubeActionChip(
                          icon: Icons.record_voice_over_rounded,
                          label: _selectedVoiceName.split(' ').first,
                          active: true,
                          onTap: _showVoicesModal,
                        ),
                        const SizedBox(width: 8),
                        _buildYouTubeActionChip(
                          icon: activeTrack.icon,
                          label: _ambientVolume > 0
                              ? '${activeTrack.title.split(' ').first} ${(100 * _ambientVolume).round()}%'
                              : 'Clásica Off',
                          active: _ambientVolume > 0,
                          onTap: _showLoFiModal,
                        ),
                        const SizedBox(width: 8),
                        _buildYouTubeActionChip(
                          icon: Icons.menu_book_rounded,
                          label: 'Karaoke',
                          active: false,
                          onTap: () {
                            setState(() {
                              _viewMode = 1;
                              _lastAutoScrolledSegment = -1;
                            });
                            _scrollToCurrentSegment(_currentSegmentIndex);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildYouTubeActionChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFFF5A623).withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active ? const Color(0xFFF5A623).withValues(alpha: 0.55) : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? const Color(0xFFF5A623) : Colors.white70,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// VISTA 2: MODO TEXTO KARAOKE MINIMALISTA (SIN BARRAS EXTRAS Y SINCRONIZADO CON EL COLOR DORADO/ÁMBAR DE LOS BOTONES)
  Widget _buildKaraokeTextView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(_segments.length, (idx) {
          final bool isCurrentSeg = idx == _currentSegmentIndex;
          final String segText = _segments[idx];

          if (!isCurrentSeg) {
            return GestureDetector(
              key: _segmentKeys[idx],
              onTap: () => _playSegmentAtIndex(idx, _synthesisGeneration),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                child: Text(
                  segText,
                  style: TextStyle(
                    fontSize: 18,
                    height: 1.62,
                    color: idx < _currentSegmentIndex
                        ? Colors.white.withValues(alpha: 0.45)
                        : Colors.white.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            );
          }

          final List<String> tokens =
              segText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
          final int activeWordIdx = _getActiveWordIndexForCurrentSegment(tokens);

          return GestureDetector(
            key: _segmentKeys[idx],
            onTap: () => _playSegmentAtIndex(idx, _synthesisGeneration),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              margin: const EdgeInsets.symmetric(vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              decoration: BoxDecoration(
                // Caja sincronizada con la paleta oscura + ámbar dorado de los botones de la app
                color: const Color(0xFF231D14).withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFFF5A623).withValues(alpha: 0.55),
                  width: 1.3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFF5A623).withValues(alpha: 0.10),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(
                    fontFamily: GoogleFonts.inter().fontFamily,
                    fontSize: 18.5,
                    height: 1.65,
                  ),
                  children: List.generate(tokens.length, (wIdx) {
                    final bool isCurrentWord = wIdx == activeWordIdx;
                    final bool isPastWord = wIdx < activeWordIdx;
                    return TextSpan(
                      text: '${tokens[wIdx]}${wIdx < tokens.length - 1 ? ' ' : ''}',
                      style: TextStyle(
                        color: isCurrentWord
                            ? Colors.black
                            : (isPastWord
                                ? Colors.white.withValues(alpha: 0.95)
                                : Colors.white.withValues(alpha: 0.78)),
                        fontWeight: isCurrentWord ? FontWeight.w800 : FontWeight.w500,
                        backgroundColor: isCurrentWord
                            ? const Color(0xFFF5A623)
                            : Colors.transparent,
                      ),
                    );
                  }),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  /// Panel de controles inferior minimalista (sin el botón extra de la derecha)
  Widget _buildUnifiedBottomControls() {
    final Duration activeElapsed = _draggingSliderSec != null
        ? Duration(seconds: _draggingSliderSec!.round())
        : _fullBookElapsedPosition;
    final Duration activeTotal = _fullBookTotalDuration;

    final double maxSliderSec = max(1.0, activeTotal.inSeconds.toDouble());
    final double currentSliderSec = _draggingSliderSec != null
        ? _draggingSliderSec!.clamp(0.0, maxSliderSec)
        : activeElapsed.inSeconds.toDouble().clamp(0.0, maxSliderSec);

    final int remainingSec = max(0, activeTotal.inSeconds - activeElapsed.inSeconds);
    final int remMins = remainingSec ~/ 60;
    final String remainingLabel = remMins >= 60
        ? '${remMins ~/ 60}h ${remMins % 60}m restantes'
        : '${max(1, remMins)}m restantes';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101114).withValues(alpha: 0.95),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Indicador de capítulo limpio y centrado (como en tu Imagen 2 de referencia)
            GestureDetector(
              onTap: _showChaptersModal,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.format_list_bulleted_rounded,
                        size: 16, color: Color(0xFFF5A623)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _currentChapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: const Color(0xFFF5A623),
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: currentSliderSec,
                min: 0.0,
                max: maxSliderSec,
                onChangeStart: (val) {
                  setState(() {
                    _draggingSliderSec = val;
                  });
                },
                onChanged: (val) {
                  setState(() {
                    _draggingSliderSec = val;
                  });
                },
                onChangeEnd: (val) {
                  setState(() {
                    _draggingSliderSec = null;
                  });
                  _seekAcrossFullBook(val);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatDuration(activeElapsed),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  Text(
                    remainingLabel,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    _formatDuration(activeTotal),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded, size: 30, color: Colors.white),
                  tooltip: 'Párrafo anterior',
                  onPressed: () {
                    if (_currentSegmentIndex > 0) {
                      _playSegmentAtIndex(_currentSegmentIndex - 1, _synthesisGeneration);
                    } else {
                      final idx = widget.book.chapters
                          .indexWhere((c) => c.id == _currentChapter.id);
                      if (idx > 0) {
                        _startChapterPlayback(widget.book.chapters[idx - 1]);
                      }
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.replay_10_rounded, size: 30, color: Colors.white),
                  onPressed: () {
                    final newPos = _position - const Duration(seconds: 10);
                    widget.player.seek(newPos < Duration.zero ? Duration.zero : newPos);
                  },
                ),
                GestureDetector(
                  onTap: _togglePlayPause,
                  child: Container(
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5A623),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFF5A623).withValues(alpha: 0.35),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: _isSynthesizing
                        ? const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 3,
                              ),
                            ),
                          )
                        : Icon(
                            _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            size: 40,
                            color: Colors.black,
                          ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.forward_30_rounded, size: 30, color: Colors.white),
                  onPressed: () {
                    final newPos = _position + const Duration(seconds: 30);
                    if (newPos < _duration) {
                      widget.player.seek(newPos);
                    } else if (_currentSegmentIndex + 1 < _segments.length) {
                      _playSegmentAtIndex(_currentSegmentIndex + 1, _synthesisGeneration);
                    }
                  },
                ),
                InkWell(
                  onTap: _cycleSpeed,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      '${_playbackSpeed}x',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: Color(0xFFF5A623),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                InkWell(
                  onTap: _showLoFiModal,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _ambientVolume > 0
                          ? const Color(0xFFF5A623).withValues(alpha: 0.16)
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.piano_rounded,
                          color: _ambientVolume > 0 ? const Color(0xFFF5A623) : Colors.white54,
                          size: 17,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _ambientVolume > 0
                              ? '${(_ambientVolume * 100).round()}%'
                              : 'Off',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            color: _ambientVolume > 0 ? const Color(0xFFF5A623) : Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: _showVoicesModal,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFF5A623).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircleAvatar(
                          radius: 11,
                          backgroundColor: Color(0xFFF5A623),
                          child: Icon(Icons.record_voice_over, size: 13, color: Colors.black),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _selectedVoiceName.split(' • ').first,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, color: Colors.white70, size: 26),
                  tooltip: 'Siguiente párrafo',
                  onPressed: () {
                    if (_currentSegmentIndex + 1 < _segments.length) {
                      _playSegmentAtIndex(_currentSegmentIndex + 1, _synthesisGeneration);
                    } else {
                      final currentIndex =
                          widget.book.chapters.indexWhere((c) => c.id == _currentChapter.id);
                      if (currentIndex != -1 &&
                          currentIndex + 1 < widget.book.chapters.length) {
                        _startChapterPlayback(widget.book.chapters[currentIndex + 1]);
                      }
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0E11),
      body: AnimatedBuilder(
        animation: _ambientAnimController,
        builder: (context, child) {
          final double t = _ambientAnimController.value;
          final Color c1 = _ambientColors.first;
          final Color c2 = _ambientColors.last;

          final List<Color> bgGradient = _viewMode == 0
              ? [c1, c2, const Color(0xFF0D0E11)]
              : [
                  const Color(0xFF141311),
                  const Color(0xFF0E0E0F),
                  const Color(0xFF09090A),
                ];

          return Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(-0.8 + t * 1.2, -1.0),
                      end: Alignment(0.8 - t * 1.2, 1.0),
                      colors: bgGradient,
                      stops: const [0.0, 0.52, 1.0],
                    ),
                  ),
                ),
              ),
              if (_viewMode == 0)
                Positioned(
                  top: 60 + (t * 45),
                  left: 30 + ((1 - t) * 50),
                  right: 30 + (t * 50),
                  child: IgnorePointer(
                    child: Container(
                      height: 280,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: c1.withValues(alpha: 0.55),
                            blurRadius: 110,
                            spreadRadius: 35,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Column(
                children: [
                  _buildTopBar(),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      child: _viewMode == 0
                          ? _buildCoverModeView()
                          : _buildKaraokeTextView(),
                    ),
                  ),
                  _buildUnifiedBottomControls(),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatDuration(Duration d) {
    final totalMinutes = d.inMinutes;
    if (totalMinutes >= 60) {
      final h = totalMinutes ~/ 60;
      final m = (totalMinutes % 60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    final minutes = totalMinutes.toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

// ==========================================
// VISOR INTEGRADO DE DOCUMENTOS (PDF ORIGINAL + LECTOR EPUB / TEXTO)
// ==========================================
class DocumentViewerScreen extends StatefulWidget {
  final BookItem book;
  final AudioPlayer player;
  final int initialChapterIndex;
  final Function(int chapterIndex, int segmentIndex)? onSeekToPosition;

  const DocumentViewerScreen({
    super.key,
    required this.book,
    required this.player,
    this.initialChapterIndex = 0,
    this.onSeekToPosition,
  });

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late int _viewerMode; // 0 = PDF Original, 1 = Modo Lectura Texto / EPUB
  late int _activeChapterIndex;
  double _fontSize = 17.5;

  PageController? _pdfPageController;
  int _currentPdfPage = 0;
  int _totalPdfPages = 0;
  final Map<int, Uint8List> _pdfPageCache = {};
  bool _hasLocalPdf = false;
  bool _isLoadingPdfPage = false;

  StreamSubscription<PlayerState>? _playerSub;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _activeChapterIndex = widget.initialChapterIndex.clamp(0, max(0, widget.book.chapters.length - 1));
    _hasLocalPdf = widget.book.fileType == 'pdf' &&
        widget.book.originalFilePath != null &&
        File(widget.book.originalFilePath!).existsSync();
    _viewerMode = _hasLocalPdf ? 0 : 1;

    _isPlaying = widget.player.playing;
    _playerSub = widget.player.playerStateStream.listen((state) {
      if (mounted) setState(() => _isPlaying = state.playing);
    });

    if (_hasLocalPdf) {
      _initPdfRenderer();
    }
  }

  @override
  void dispose() {
    _playerSub?.cancel();
    _pdfPageController?.dispose();
    super.dispose();
  }

  Future<void> _initPdfRenderer() async {
    final path = widget.book.originalFilePath!;
    setState(() => _isLoadingPdfPage = true);
    final res = await NativeChannelService.renderPdfPage(path, 0, width: 1080);
    if (res != null && mounted) {
      final total = (res['pageCount'] as int?) ?? 1;
      final bytes = res['bytes'] as Uint8List?;
      setState(() {
        _totalPdfPages = total;
        _isLoadingPdfPage = false;
        if (bytes != null) _pdfPageCache[0] = bytes;
      });
      _pdfPageController = PageController(initialPage: 0);
      _preloadPdfPages([1, 2]);
    } else if (mounted) {
      setState(() {
        _isLoadingPdfPage = false;
        _viewerMode = 1; // Fallback to text mode
      });
    }
  }

  Future<void> _loadPdfPage(int pageIndex) async {
    if (_pdfPageCache.containsKey(pageIndex)) return;
    final path = widget.book.originalFilePath;
    if (path == null) return;
    final res = await NativeChannelService.renderPdfPage(path, pageIndex, width: 1080);
    if (res != null && mounted && res['bytes'] is Uint8List) {
      setState(() {
        _pdfPageCache[pageIndex] = res['bytes'] as Uint8List;
      });
    }
  }

  void _preloadPdfPages(List<int> pages) {
    for (final p in pages) {
      if (p >= 0 && p < _totalPdfPages && !_pdfPageCache.containsKey(p)) {
        _loadPdfPage(p);
      }
    }
  }

  void _jumpToAudioChapter() {
    if (_viewerMode == 0 && _totalPdfPages > 0) {
      // Estimar página en base al capítulo
      final ratio = _activeChapterIndex / max(1, widget.book.chapters.length);
      final targetPage = (ratio * _totalPdfPages).round().clamp(0, _totalPdfPages - 1);
      _pdfPageController?.animateToPage(
        targetPage,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      setState(() {
        _activeChapterIndex = widget.book.lastChapterIndex.clamp(0, widget.book.chapters.length - 1);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentCh = widget.book.chapters[_activeChapterIndex];

    return Scaffold(
      backgroundColor: const Color(0xFF121316),
      appBar: AppBar(
        backgroundColor: const Color(0xFF191B20),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            Text(
              _viewerMode == 0
                  ? 'PDF Original • Pág. ${_currentPdfPage + 1} de $_totalPdfPages'
                  : currentCh.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFF5A623), fontSize: 12),
            ),
          ],
        ),
        actions: [
          if (_hasLocalPdf)
            IconButton(
              icon: Icon(
                _viewerMode == 0 ? Icons.menu_book_rounded : Icons.picture_as_pdf_rounded,
                color: const Color(0xFFF5A623),
              ),
              tooltip: _viewerMode == 0 ? 'Modo Lectura Texto' : 'Modo PDF Original',
              onPressed: () {
                setState(() {
                  _viewerMode = _viewerMode == 0 ? 1 : 0;
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.format_list_bulleted_rounded, color: Colors.white70),
            tooltip: 'Seleccionar capítulo',
            onPressed: _showChapterSelector,
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner indicador de sincronización con el audiolibro
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            color: const Color(0xFF221C14),
            child: Row(
              children: [
                const Icon(Icons.headphones_rounded, size: 16, color: Color(0xFFF5A623)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Audio en: ${widget.book.chapters[widget.book.lastChapterIndex.clamp(0, widget.book.chapters.length - 1)].title}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _jumpToAudioChapter,
                  child: const Text(
                    'Ir a esta parte',
                    style: TextStyle(
                      color: Color(0xFFF5A623),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _viewerMode == 0 && _hasLocalPdf
                ? _buildPdfViewer()
                : _buildTextReader(currentCh),
          ),
          _buildBottomBar(currentCh),
        ],
      ),
    );
  }

  Widget _buildPdfViewer() {
    if (_totalPdfPages == 0 || _isLoadingPdfPage) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFF5A623)),
      );
    }

    return PageView.builder(
      controller: _pdfPageController,
      itemCount: _totalPdfPages,
      onPageChanged: (pageIdx) {
        setState(() => _currentPdfPage = pageIdx);
        _preloadPdfPages([pageIdx - 1, pageIdx + 1, pageIdx + 2]);
      },
      itemBuilder: (context, pageIdx) {
        final bytes = _pdfPageCache[pageIdx];
        if (bytes == null) {
          _loadPdfPage(pageIdx);
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFF5A623)),
          );
        }
        return InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.5,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTextReader(ChapterItem chapter) {
    final paragraphs = chapter.textContent
        .split('\n\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    final isSameChapterAsAudio = widget.book.lastChapterIndex == _activeChapterIndex;

    return Column(
      children: [
        // Barra de control de tamaño de fuente
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: const Color(0xFF16181D),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${paragraphs.length} párrafos • ${chapter.durationText}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.text_decrease_rounded, size: 20, color: Colors.white70),
                    onPressed: () {
                      if (_fontSize > 13) setState(() => _fontSize -= 1.5);
                    },
                  ),
                  Text(
                    '${_fontSize.round()}',
                    style: const TextStyle(
                      color: Color(0xFFF5A623),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.text_increase_rounded, size: 20, color: Colors.white70),
                    onPressed: () {
                      if (_fontSize < 28) setState(() => _fontSize += 1.5);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
            itemCount: paragraphs.length,
            itemBuilder: (context, pIdx) {
              final isCurrentAudioSegment =
                  isSameChapterAsAudio && widget.book.lastSegmentIndex == pIdx;
              final text = paragraphs[pIdx];

              return GestureDetector(
                onTap: () {
                  widget.onSeekToPosition?.call(_activeChapterIndex, pIdx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Reproduciendo desde párrafo ${pIdx + 1}...'),
                      duration: const Duration(milliseconds: 1400),
                      behavior: SnackBarBehavior.floating,
                      backgroundColor: const Color(0xFFF5A623),
                    ),
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: EdgeInsets.all(isCurrentAudioSegment ? 16 : 0),
                  decoration: BoxDecoration(
                    color: isCurrentAudioSegment
                        ? const Color(0xFF261E14).withValues(alpha: 0.95)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: isCurrentAudioSegment
                        ? Border.all(color: const Color(0xFFF5A623), width: 1.4)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isCurrentAudioSegment)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.volume_up_rounded, size: 16, color: Color(0xFFF5A623)),
                              SizedBox(width: 6),
                              Text(
                                'Narrando este párrafo ahora',
                                style: TextStyle(
                                  color: Color(0xFFF5A623),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: _fontSize,
                          height: 1.68,
                          color: isCurrentAudioSegment ? Colors.white : Colors.white.withValues(alpha: 0.88),
                          fontWeight: isCurrentAudioSegment ? FontWeight.w500 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar(ChapterItem currentCh) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF191B20),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: _viewerMode == 0 && _totalPdfPages > 0
                  ? SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        activeTrackColor: const Color(0xFFF5A623),
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        value: _currentPdfPage.toDouble().clamp(0.0, max(0.0, _totalPdfPages - 1.0)),
                        min: 0.0,
                        max: max(0.0, _totalPdfPages - 1.0),
                        onChanged: (val) {
                          final p = val.round();
                          _pdfPageController?.jumpToPage(p);
                        },
                      ),
                    )
                  : Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white70),
                          onPressed: _activeChapterIndex > 0
                              ? () => setState(() => _activeChapterIndex--)
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            currentCh.title,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded, color: Colors.white70),
                          onPressed: _activeChapterIndex + 1 < widget.book.chapters.length
                              ? () => setState(() => _activeChapterIndex++)
                              : null,
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFF5A623),
                foregroundColor: Colors.black,
              ),
              icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: () {
                if (_isPlaying) {
                  NativeChannelService.pauseLoFi();
                  widget.player.pause();
                } else {
                  widget.player.play();
                  NativeChannelService.playLoFi();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showChapterSelector() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF181A1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          minChildSize: 0.40,
          maxChildSize: 0.85,
          builder: (_, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Capítulos del libro',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const SizedBox(height: 12),
                ...widget.book.chapters.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final ch = entry.value;
                  final isCurrent = idx == _activeChapterIndex;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: isCurrent ? const Color(0xFFF5A623) : const Color(0xFF2C2D32),
                      child: Text(
                        ch.id.toString(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isCurrent ? Colors.black : Colors.white70,
                        ),
                      ),
                    ),
                    title: Text(
                      ch.title,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? const Color(0xFFF5A623) : Colors.white,
                      ),
                    ),
                    subtitle: Text(
                      ch.durationText,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _activeChapterIndex = idx);
                    },
                  );
                }),
              ],
            );
          },
        );
      },
    );
  }
}
