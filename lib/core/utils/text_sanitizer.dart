class TextSanitizer {
  /// Limpia texto extraído de PDF o EPUB (une guiones cortados, separa palabras pegadas, limpia índices)
  static String sanitizeExtractedText(String raw) {
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
    s = s
        .replaceAll(RegExp(r'\.{3,}\s*\d*'), '. ')
        .replaceAll(RegExp(r'…+\s*\d*'), '. ');

    // 5. Unir saltos de línea simples dentro de un mismo párrafo para que el TTS no haga pausas robóticas a mitad de frase
    s = s.replaceAllMapped(
      RegExp(r'([^\.\!\?\:\n])\n([a-záéíóúñü0-9“"«\(])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    s = s
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    return s;
  }

  /// Detecta páginas de créditos legales, imprenta o copyright para saltarlas automáticamente
  static bool isLegalCopyrightPage(String rawPageText) {
    final lower = rawPageText.toLowerCase();
    int matches = 0;
    if (lower.contains('isbn')) matches += 2;
    if (lower.contains('depósito legal') || lower.contains('deposito legal')) matches += 2;
    if (lower.contains('todos los derechos reservados') || lower.contains('all rights reserved')) {
      matches += 2;
    }
    if (lower.contains('diseño de cubierta') ||
        lower.contains('diseno de cubierta') ||
        lower.contains('diseño de portada')) {
      matches += 2;
    }
    if (lower.contains('printed in') || lower.contains('impreso en')) matches += 2;
    if (lower.contains('primera edición') || lower.contains('primera edicion')) matches += 1;
    if (lower.contains('editorial herder') ||
        lower.contains('ediciones ') ||
        lower.contains('d.r. ©') ||
        lower.contains('copyright ©')) {
      matches += 1;
    }
    if (lower.contains('traducción de') ||
        lower.contains('traduccion de') ||
        lower.contains('título original') ||
        lower.contains('titulo original')) {
      matches += 1;
    }

    final wordCount = rawPageText.split(RegExp(r'\s+')).length;
    if (matches >= 3 && wordCount < 350) return true;
    if (matches >= 4) return true;
    return false;
  }

  /// Prepara el texto específicamente para que el motor neuronal respire y entone como un narrador humano profesional
  static String humanizeTextForNaturalSpeech(String text) {
    var s = sanitizeExtractedText(text);
    s = s
        .replaceAll(RegExp(r'[“”«»"]'), '')
        .replaceAll('—', ', ')
        .replaceAll('–', ', ')
        .replaceAll('(', ', ')
        .replaceAll(')', ', ')
        .replaceAll(RegExp(r'\bpágs?\.\s*', caseSensitive: false), 'páginas ')
        .replaceAll(RegExp(r'\bcap\.\s*', caseSensitive: false), 'capítulo ')
        .replaceAll(RegExp(r'\bp\.\s*ej\.', caseSensitive: false), 'por ejemplo')
        .replaceAll(RegExp(r'\betc\.', caseSensitive: false), 'etcétera.')
        .replaceAll(RegExp(r'\bdr\.\s*', caseSensitive: false), 'doctor ')
        .replaceAll(RegExp(r'\bdra\.\s*', caseSensitive: false), 'doctora ')
        .replaceAll(RegExp(r'\s+([,\.\;\:\!\?])'), r'$1')
        .replaceAll(RegExp(r',\s*,+'), ',')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.isEmpty ? 'Continuando lectura.' : s;
  }

  /// Divide un capítulo largo en fragmentos óptimos (~420 caracteres) respetando límites de oración
  static List<String> splitIntoSegments(String rawText) {
    final cleaned = sanitizeExtractedText(rawText)
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

  /// Formatea una duración en mm:ss o h:mm:ss
  static String formatDuration(Duration d) {
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
