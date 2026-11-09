class TextSanitizer {
  /// Limpia profundamente el texto extraído de cualquier PDF o EPUB, tanto al importar
  /// como en tiempo real antes de mostrarlo y narrarlo.
  /// - Elimina citas bibliográficas [12], (12), superíndices ¹², asteriscos y símbolos raros
  /// - Limpia signos « » sueltos, barras, guiones rotos y números de página huérfanos
  /// - Une iniciales de nombres ("Gordon W.\nAllport" -> "Gordon W. Allport")
  static String sanitizeExtractedText(String raw) {
    if (raw.isEmpty) return '';

    var s = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\u00A0', ' ') // Non-breaking space
        .replaceAll('\u00AD', ''); // Soft hyphen invisible en PDFs/EPUBs

    // 1. Eliminar referencias de notas al pie y citas bibliográficas que interrumpen la lectura: [12], [1, 2], ¹²³
    s = s
        .replaceAll(RegExp(r'\[\s*\d+(?:\s*[,;-]\s*\d+)*\s*\]'), ' ')
        .replaceAll(RegExp(r'\(\s*\d{1,3}\s*\)'), ' ')
        .replaceAll(RegExp(r'[¹²³⁴⁵⁶⁷⁸⁹⁰]+'), '')
        .replaceAll(RegExp(r'[\*†‡§¶‖#•●▪▫►◄◆◇¤¦¨©®™°±²³´µ¸¹º¼½¾]'), ' ');

    // 2. Eliminar URLs, correos o rutas técnicas sueltas que ensucian los libros
    s = s
        .replaceAll(RegExp(r'https?://\S+'), '')
        .replaceAll(RegExp(r'www\.\S+'), '');

    // 3. Eliminar números de página huérfanos y cabeceras aisladas de 1 a 2 letras separadas por espacios (ej. "\n 42 \n", "\n D E \n", "\n A P \n")
    s = s
        .replaceAll(RegExp(r'\n\s*[-–—]?\s*\d{1,4}\s*[-–—]?\s*(?=\n)'), '\n')
        .replaceAll(RegExp(r'\n\s*[A-ZÁÉÍÓÚÑ]\s+[A-ZÁÉÍÓÚÑ]\s*(?=\n)'), '\n')
        .replaceAll(RegExp(r'\b[Pp]áginas?\s+\d+\s*(?:a|al|-)\s*\d+\b'), '');

    // 4. Unir palabras cortadas por guión al final de línea en PDFs ("pro-\nceso" -> "proceso")
    s = s.replaceAllMapped(
      RegExp(r'([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])[-‐‑‒–]\s*\n\s*([a-záéíóúñü])'),
      (m) => '${m.group(1)}${m.group(2)}',
    );

    // 4b. Corregir letras capitales / capitulares huérfanas al inicio de títulos o párrafos:
    // "D\nE\nL INFORME" -> "DEL INFORME", "U\nN ENSAYO" -> "UN ENSAYO", "S\nELECCIÓN" -> "SELECCIÓN"
    s = s.replaceAllMapped(
      RegExp(r'(?:^|\n)\s*([A-ZÁÉÍÓÚÑ])\s*\n+\s*([A-ZÁÉÍÓÚÑ])\s*\n+\s*([A-ZÁÉÍÓÚÑ])(?=\s+[A-ZÁÉÍÓÚÑ])'),
      (m) => '\n${m.group(1)}${m.group(2)}${m.group(3)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'(?:^|\n)\s*([A-ZÁÉÍÓÚÑ])\s*\n+\s*([A-ZÁÉÍÓÚÑ])(?=\s+[A-ZÁÉÍÓÚÑ])'),
      (m) => '\n${m.group(1)}${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'(?:^|\n)\s*([A-ZÁÉÍÓÚÑ])\s*\n+\s*([A-ZÁÉÍÓÚÑ]{2,})\b'),
      (m) => '\n${m.group(1)}${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'(?:^|\n)\s*([A-ZÁÉÍÓÚÑ])\s*\n+\s*([a-záéíóúñü]{1,4})\b'),
      (m) => '\n${m.group(1)}${m.group(2)}',
    );

    // 5. Proteger y unir iniciales de nombres propios cortadas por salto de línea ("Gordon W.\nAllport" -> "Gordon W. Allport")
    s = s.replaceAllMapped(
      RegExp(r'\b([A-ZÁÉÍÓÚÑ])\.\s*\n+\s*([A-ZÁÉÍÓÚÑ][a-záéíóúñü]+)'),
      (m) => '${m.group(1)}. ${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'\b(Dr|Dra|Sr|Sra|Srta|Prof|Lic|Ing|St|San|Sta|Cap|Pág|Art|Vol|Núm|Ed)\.\s*\n+\s*([A-ZÁÉÍÓÚÑa-záéíóúñü])'),
      (m) => '${m.group(1)}. ${m.group(2)}',
    );

    // 5b. Corregir artefacto de fuentes PDF con glifo 'y' duplicado o desplazado ("Estoyy", "yy", "apoyyo", "ayyuda", "yEstoyy", "y. Estoyy")
    // En español e inglés jamás existe "yy" en ninguna palabra real, y si queda "yy" el TTS pronuncia "igriega igriega".
    s = s.replaceAllMapped(
      RegExp(r'(?:^|(?<=[\.\!\?\n]))\s*[yY]\.\s*'),
      (_) => '',
    );
    s = s.replaceAllMapped(
      RegExp(r'\b(De|Di|Da|Du|Mc|Mac|Van|Von)\.\s+([A-ZÁÉÍÓÚÑÜ][a-záéíóúñü]+)'),
      (m) => '${m.group(1)}${m.group(2)}',
    );
    s = s.replaceAllMapped(
      RegExp(r'\b[yY]+([A-ZÁÉÍÓÚÑ][a-záéíóúñü]*[yY][a-záéíóúñü]*)'),
      (m) => m.group(1)!,
    );
    s = s.replaceAllMapped(
      RegExp(r'([yY])\1+'),
      (m) => m.group(1)!,
    );

    // 5c. Separar la conjunción "y" o artículos pegados por falta de espacio en PDFs justificados ("yypor" -> "y por", "generosay el" -> "generosa y el", "laeditorial" -> "la editorial", "esteproyecto" -> "este proyecto")
    s = s.replaceAllMapped(
      RegExp(
        r'\by(por|para|con|sin|sobre|entre|hacia|hasta|desde|durante|mediante|según|como|cuando|donde|aunque|porque|pero|sino|también|además|todo|toda|todos|todas|este|esta|estos|estas|ese|esa|esos|esas|un|una|unos|unas|el|la|los|las|su|sus|mi|mis|tu|tus|me|te|se|nos|le|les|lo|al|del|en|de|a|que|si|no|más|muy|ya)\b',
        caseSensitive: false,
      ),
      (m) {
        final full = m.group(0)!.toLowerCase();
        // Proteger palabras reales que empiezan con "y" + esas sílabas (ej. "yacimiento", "yate", "yerno", "yeso", "yoga", "yugo")
        const realYWords = {
          'ya', 'yate', 'yates', 'yace', 'yacen', 'yacer', 'yacimiento',
          'yendo', 'yerno', 'yernos', 'yerba', 'yerbas', 'yerro', 'yerros',
          'yeso', 'yema', 'yemas', 'yegua', 'yeguas', 'yo', 'yoga', 'yogur',
          'yugo', 'yugos', 'yunta', 'yuxtaposición'
        };
        if (realYWords.contains(full)) return m.group(0)!;
        final firstChar = m.group(0)!.substring(0, 1);
        return '$firstChar ${m.group(1)}';
      },
    );
    s = s.replaceAllMapped(
      RegExp(
        r'\b([a-záéíóúñü]{4,}[aeoáéó])y\s+(?=(?:el|la|los|las|un|una|unos|unas|su|sus|mi|mis|tu|tus|en|por|para|con|sin|de|a|que|no|se|me|le|nos|al|del|este|esta|ese|esa|todo|toda)\b)',
        caseSensitive: false,
      ),
      (m) {
        final stem = m.group(1)!.toLowerCase();
        // Proteger verbos en 1ra persona terminados en -oy/-ay/-ey ("estoy", "soy", "doy", "voy", "hay")
        if (stem.endsWith('est') || stem == 's' || stem == 'd' || stem == 'v' || stem == 'h') {
          return m.group(0)!;
        }
        return '${m.group(1)} y ';
      },
    );
    s = s.replaceAllMapped(
      RegExp(
        r'\b(la|el|los|las|un|una|este|esta|estos|estas|ese|esa|mi|tu|su)(editorial|proyecto|proyectos|libro|libros|mundo|vida|tiempo|camino|trabajo|equipo|proceso|familia|historia|cuerpo|mente|dolor|amor|miedo|padre|madre|hijo|hija|hermano|hermana|experiencia|sabiduría|ayuda|apoyo|manera|maneras|idea|ideas|persona|personas|campo|campos|parte|partes)\b',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // 6. Separar palabras pegadas por minúscula seguida de mayúscula ("cansancioTraducción" -> "cansancio. Traducción"),
    // pero respetando apellidos compuestos como "DeSanti", "DiCaprio", "McDonald", "MacArthur"
    s = s.replaceAllMapped(
      RegExp(r'\b([A-ZÁÉÍÓÚÑÜ]?[a-záéíóúñü]+)([A-ZÁÉÍÓÚÑÜ][a-záéíóúñü]+)'),
      (m) {
        final left = m.group(1)!;
        final right = m.group(2)!;
        const namePrefixes = {'De', 'Di', 'Da', 'Du', 'Mc', 'Mac', 'Van', 'Von', 'La', 'Le', 'Lo', 'St'};
        if (namePrefixes.contains(left)) {
          return '$left$right';
        }
        return '$left. $right';
      },
    );

    // 7. Separar números pegados a letras o comas pegadas ("2010,MSB" -> "2010, MSB", "om1ª" -> "om 1ª")
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

    // 8. Limpiar comillas angulares « » y comillas sueltas con espacios ("« intención paradójica » ." -> '"intención paradójica".')
    // Así nunca queda un símbolo « o » suelto como palabra en el Karaoke ni genera "$1"
    s = s
        .replaceAll(RegExp(r'[«‹„“]+\s*'), '"')
        .replaceAll(RegExp(r'\s*[»›”]+'), '"')
        .replaceAll(RegExp(r'<<+\s*'), '"')
        .replaceAll(RegExp(r'\s*>>+'), '"');

    // Si hay espacio antes de punto, coma, punto y coma, dos puntos o cierre de interrogación/exclamación: pegarlo a la palabra
    s = s.replaceAllMapped(
      RegExp(r'\s+([,\.\;\:\!\?\”\"])'),
      (m) => m.group(1)!,
    );
    // Y si quedó `".` o `",` normalizar el orden limpio
    s = s.replaceAllMapped(
      RegExp(r'"\s+([,\.\;\:\!\?])'),
      (m) => '"${m.group(1)}',
    );

    // 9. Limpiar barras (/ , \ , |), guiones bajos (_) y corchetes/llaves residuales
    s = s
        .replaceAll(RegExp(r'\s*[/\\|]\s*'), ', ')
        .replaceAll(RegExp(r'[_\[\]\{\}<>~^`]+'), ' ');

    // 10. Eliminar hileras de puntos de índices visuales ("....... 24")
    s = s
        .replaceAll(RegExp(r'\.{3,}\s*\d*'), '. ')
        .replaceAll(RegExp(r'…+\s*\d*'), '. ');

    // 10b. Asegurar espacio después de punto, coma, punto y coma, dos puntos o cierre de interrogación/exclamación cuando está pegado a una letra ("enorme.Agradecidísimo" -> "enorme. Agradecidísimo")
    s = s.replaceAllMapped(
      RegExp(r'([,\.\;\:\!\?])([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ¿¡])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // 11. Unir saltos de línea simples dentro de un mismo párrafo para que la lectura sea continua y armónica
    s = s.replaceAllMapped(
      RegExp(r'([^\.\!\?\:\n])\n\s*([a-záéíóúñüA-ZÁÉÍÓÚÑÜ0-9"“\(])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // 12. Limpiar signos de puntuación repetidos (", ," o "..") y espacios múltiples
    s = s
        .replaceAll(RegExp(r',\s*,+'), ', ')
        .replaceAll(RegExp(r'\.\s*\.+'), '. ')
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

  /// Prepara el texto específicamente para el motor neuronal (Edge-TTS) con pausas
  /// respiratorias, cadencia de audiolibro/podcast profesional y cero símbolos leídos en voz alta.
  static String humanizeTextForNaturalSpeech(String text) {
    var s = sanitizeExtractedText(text);

    // 1. Limpiar cualquier rastro de "$1" por si viniera de texto viejo
    s = s.replaceAll(r'$1', '');

    // 2. En iniciales de nombres ("Gordon W. Allport" -> "Gordon W Allport"), quitar el punto
    // para que el narrador NO haga una pausa muerta a mitad del nombre de una persona
    s = s.replaceAllMapped(
      RegExp(r'\b([A-ZÁÉÍÓÚÑ])\.\s+([A-ZÁÉÍÓÚÑ][a-záéíóúñü]+)'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // 3. Dar pausa natural de locutor a frases entre comillas ("intención paradójica" -> ", intención paradójica, ")
    // y eliminar todas las comillas para que el motor jamás tropiece con ellas
    s = s.replaceAllMapped(
      RegExp(r'([a-záéíóúñüA-ZÁÉÍÓÚÑ0-9])\s+"([^"]{2,120})"'),
      (m) => '${m.group(1)}, ${m.group(2)}, ',
    );
    s = s.replaceAll(RegExp(r'[“”«»"‹›„‟\x27`]'), '');

    // 4. Convertir guiones largos (incisos explicativos) y paréntesis en pausas suaves de coma
    s = s
        .replaceAll(RegExp(r'\s*[—–―]\s*'), ', ')
        .replaceAll('(', ', ')
        .replaceAll(')', ', ');

    // 5. Dos puntos y punto y coma: asegurar pausa respiratoria clara antes de citas o enumeraciones
    s = s
        .replaceAll(RegExp(r'\s*:\s*'), ': ')
        .replaceAll(RegExp(r'\s*;\s*'), '; ');

    // 6. Expandir abreviaturas frecuentes para que el narrador las pronuncie completas con fluidez
    s = s
        .replaceAll(RegExp(r'\bpágs?\.\s*', caseSensitive: false), 'páginas ')
        .replaceAll(RegExp(r'\bcap\.\s*', caseSensitive: false), 'capítulo ')
        .replaceAll(RegExp(r'\bp\.\s*ej\.', caseSensitive: false), 'por ejemplo, ')
        .replaceAll(RegExp(r'\be\.\s*g\.', caseSensitive: false), 'por ejemplo, ')
        .replaceAll(RegExp(r'\bi\.\s*e\.', caseSensitive: false), 'es decir, ')
        .replaceAll(RegExp(r'\betc\.', caseSensitive: false), 'etcétera.')
        .replaceAll(RegExp(r'\bdr\.\s*', caseSensitive: false), 'doctor ')
        .replaceAll(RegExp(r'\bdra\.\s*', caseSensitive: false), 'doctora ')
        .replaceAll(RegExp(r'\bsr\.\s*', caseSensitive: false), 'señor ')
        .replaceAll(RegExp(r'\bsra\.\s*', caseSensitive: false), 'señora ')
        .replaceAll(RegExp(r'\bprof\.\s*', caseSensitive: false), 'profesor ')
        .replaceAll(RegExp(r'\bvol\.\s*', caseSensitive: false), 'volumen ')
        .replaceAll(RegExp(r'\bnúm\.\s*', caseSensitive: false), 'número ')
        .replaceAll(RegExp(r'\bn\.º\s*', caseSensitive: false), 'número ')
        .replaceAll(RegExp(r'\bnº\s*', caseSensitive: false), 'número ');

    // 7. Asegurar micro-pausa natural después de conectores discursivos si no tienen coma
    s = s.replaceAllMapped(
      RegExp(
        r'\b(Ahora bien|Sin embargo|No obstante|Por lo tanto|Por consiguiente|En conclusión|Por ejemplo|Es decir|En cambio|Además|Al mismo tiempo)\s+(?=[a-záéíóúñü])',
      ),
      (m) => '${m.group(1)}, ',
    );

    // 8. Pegar signos de puntuación a la palabra anterior USANDO replaceAllMapped (nunca replaceAll con $1)
    s = s.replaceAllMapped(
      RegExp(r'\s+([,\.\;\:\!\?])'),
      (m) => m.group(1)!,
    );

    // 9. Asegurar espacio después de cualquier signo de puntuación seguido de letra
    s = s.replaceAllMapped(
      RegExp(r'([,\.\;\:\!\?])([a-zA-ZáéíóúÁÉÍÓÚñÑüÜ])'),
      (m) => '${m.group(1)} ${m.group(2)}',
    );

    // 10. Filtro final de seguridad: eliminar cualquier símbolo raro restante que no sea letra, número o puntuación hablada
    s = s
        .replaceAll(RegExp(r'[^a-zA-ZáéíóúÁÉÍÓÚñÑüÜ0-9\s,\.\;\:\!\?¿¡%\-]'), ' ')
        .replaceAll(RegExp(r',\s*,+'), ', ')
        .replaceAll(RegExp(r'\.\s*,+'), '. ')
        .replaceAll(RegExp(r',\s*\.+'), '. ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return s.isEmpty ? 'Continuando lectura.' : s;
  }

  /// Divide un capítulo largo en fragmentos óptimos (~380 caracteres) respetando límites de oración
  /// y sin cortar jamás iniciales ("Gordon W. Allport") ni abreviaturas ("Dr. Frankl").
  static List<String> splitIntoSegments(String rawText) {
    final cleaned = sanitizeExtractedText(rawText)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return ['Capítulo listo para reproducir.'];

    // Proteger temporalmente los puntos de iniciales ("W. ") y abreviaturas ("Dr. ") con un marcador
    // para que el divisor de oraciones no parta a mitad de un nombre
    const dotPlaceholder = '∯';
    var protectedText = cleaned.replaceAllMapped(
      RegExp(r'\b([A-ZÁÉÍÓÚÑ])\.\s+'),
      (m) => '${m.group(1)}$dotPlaceholder ',
    );
    protectedText = protectedText.replaceAllMapped(
      RegExp(
        r'\b(Dr|Dra|Sr|Sra|Srta|Prof|Lic|Ing|St|San|Sta|Cap|Pág|Págs|Art|Vol|Núm|Ed|p\.\s*ej|etc)\.\s+',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}$dotPlaceholder ',
    );

    final rawSentences = protectedText.split(RegExp(r'(?<=[.!?])\s+'));
    final List<String> result = [];
    StringBuffer current = StringBuffer();

    for (final rawSentence in rawSentences) {
      final sTrim = rawSentence.replaceAll(dotPlaceholder, '.').trim();
      if (sTrim.isEmpty) continue;
      if (current.length + sTrim.length > 380 && current.isNotEmpty) {
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
