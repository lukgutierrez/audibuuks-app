import 'chapter_item.dart';

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
  fileType: 'sample',
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
