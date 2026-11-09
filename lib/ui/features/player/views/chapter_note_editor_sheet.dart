import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../data/repositories/library_repository.dart';
import '../../../../domain/models/book_item.dart';
import '../../../../domain/models/chapter_item.dart';

/// Controlador con formato enriquecido en vivo (Negrita, Cursiva, Subrayado, Subtítulos y Listas)
/// inspirado en Google Keep con la estética oscura y ámbar de AudioMind.
class FormattedNoteTextController extends TextEditingController {
  FormattedNoteTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ??
        const TextStyle(
          color: Color(0xFFEAECEF),
          fontSize: 16.5,
          height: 1.55,
        );

    final String raw = text;
    if (raw.isEmpty) {
      return TextSpan(text: '', style: baseStyle);
    }

    final List<InlineSpan> children = [];
    final lines = raw.split('\n');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('# ')) {
        // Subtítulo de sección (como "Poutine Gravy" o "Steps" en la imagen de referencia)
        children.add(
          TextSpan(
            text: '# ',
            style: baseStyle.copyWith(
              color: const Color(0xFFF5A623).withValues(alpha: 0.45),
              fontSize: 19,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        children.add(
          TextSpan(
            text: line.substring(2),
            style: baseStyle.copyWith(
              color: Colors.white,
              fontSize: 19.5,
              fontWeight: FontWeight.w700,
              height: 1.6,
            ),
          ),
        );
      } else if (line.startsWith('❝')) {
        // Cita del audiolibro
        children.add(
          TextSpan(
            text: line,
            style: baseStyle.copyWith(
              color: const Color(0xFFF5A623).withValues(alpha: 0.92),
              fontStyle: FontStyle.italic,
              fontSize: 15.5,
            ),
          ),
        );
      } else {
        children.addAll(_parseInlineFormatting(line, baseStyle));
      }

      if (i < lines.length - 1) {
        children.add(TextSpan(text: '\n', style: baseStyle));
      }
    }

    return TextSpan(style: baseStyle, children: children);
  }

  List<InlineSpan> _parseInlineFormatting(String line, TextStyle baseStyle) {
    final List<InlineSpan> spans = [];
    String remaining = line;

    // Destacar numeración inicial (ej. "1. ", "2. ") o viñeta ("• ")
    final listMatch = RegExp(r'^(\d+\.\s+|•\s+)').firstMatch(remaining);
    if (listMatch != null) {
      final prefix = listMatch.group(0)!;
      spans.add(
        TextSpan(
          text: prefix,
          style: baseStyle.copyWith(
            color: const Color(0xFFF5A623),
            fontWeight: FontWeight.w800,
          ),
        ),
      );
      remaining = remaining.substring(prefix.length);
    }

    final pattern = RegExp(r'(\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*)');
    int lastEnd = 0;

    for (final match in pattern.allMatches(remaining)) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: remaining.substring(lastEnd, match.start),
            style: baseStyle,
          ),
        );
      }

      final token = match.group(0)!;
      final markerColor = Colors.white.withValues(alpha: 0.25);

      if (token.startsWith('**') && token.endsWith('**') && token.length > 4) {
        final content = token.substring(2, token.length - 2);
        spans.add(TextSpan(text: '**', style: baseStyle.copyWith(color: markerColor, fontSize: 12)));
        spans.add(
          TextSpan(
            text: content,
            style: baseStyle.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        );
        spans.add(TextSpan(text: '**', style: baseStyle.copyWith(color: markerColor, fontSize: 12)));
      } else if (token.startsWith('__') && token.endsWith('__') && token.length > 4) {
        final content = token.substring(2, token.length - 2);
        spans.add(TextSpan(text: '__', style: baseStyle.copyWith(color: markerColor, fontSize: 12)));
        spans.add(
          TextSpan(
            text: content,
            style: baseStyle.copyWith(
              decoration: TextDecoration.underline,
              decorationColor: const Color(0xFFF5A623),
              decorationThickness: 2.0,
              color: Colors.white,
            ),
          ),
        );
        spans.add(TextSpan(text: '__', style: baseStyle.copyWith(color: markerColor, fontSize: 12)));
      } else if (token.startsWith('*') && token.endsWith('*') && token.length > 2) {
        final content = token.substring(1, token.length - 1);
        spans.add(TextSpan(text: '*', style: baseStyle.copyWith(color: markerColor, fontSize: 12)));
        spans.add(
          TextSpan(
            text: content,
            style: baseStyle.copyWith(
              fontStyle: FontStyle.italic,
              color: const Color(0xFFE0E4EC),
            ),
          ),
        );
        spans.add(TextSpan(text: '*', style: baseStyle.copyWith(color: markerColor, fontSize: 12)));
      } else {
        spans.add(TextSpan(text: token, style: baseStyle));
      }

      lastEnd = match.end;
    }

    if (lastEnd < remaining.length) {
      spans.add(
        TextSpan(
          text: remaining.substring(lastEnd),
          style: baseStyle,
        ),
      );
    }

    return spans;
  }
}

class ChapterNoteEditorSheet extends StatefulWidget {
  final BookItem book;
  final ChapterItem chapter;
  final String? currentSpokenParagraph;
  final int? currentSegmentNumber;
  final VoidCallback onNoteChanged;

  const ChapterNoteEditorSheet({
    super.key,
    required this.book,
    required this.chapter,
    this.currentSpokenParagraph,
    this.currentSegmentNumber,
    required this.onNoteChanged,
  });

  @override
  State<ChapterNoteEditorSheet> createState() => _ChapterNoteEditorSheetState();
}

class _ChapterNoteEditorSheetState extends State<ChapterNoteEditorSheet> {
  final LibraryRepository _repository = LibraryRepository();
  late final TextEditingController _titleController;
  late final FormattedNoteTextController _bodyController;
  final FocusNode _bodyFocusNode = FocusNode();

  late bool _isPinned;
  late int _selectedColorHex;
  bool _showFormattingBar = true;
  bool _showColorBar = false;
  bool _justSavedIndicator = false;
  Timer? _debounceFullSaveTimer;

  static const List<Map<String, dynamic>> _studioColors = [
    {'hex': 0xFF141519, 'name': 'Carbón'},
    {'hex': 0xFF231B10, 'name': 'Ámbar'},
    {'hex': 0xFF121D28, 'name': 'Pizarra'},
    {'hex': 0xFF12221B, 'name': 'Bosque'},
    {'hex': 0xFF231419, 'name': 'Borgoña'},
    {'hex': 0xFF1C1726, 'name': 'Violeta'},
  ];

  @override
  void initState() {
    super.initState();
    _isPinned = widget.chapter.isNotePinned;
    _selectedColorHex = widget.chapter.noteColorHex;
    _titleController = TextEditingController(
      text: (widget.chapter.noteTitle != null && widget.chapter.noteTitle!.trim().isNotEmpty)
          ? widget.chapter.noteTitle!
          : widget.chapter.title,
    );
    _bodyController = FormattedNoteTextController(
      text: widget.chapter.noteContent ?? '',
    );

    _titleController.addListener(_onTextEdited);
    _bodyController.addListener(_onTextEdited);
  }

  void _onTextEdited() {
    _persistImmediately();
  }

  Future<void> _persistImmediately() async {
    final trimmedBody = _bodyController.text;
    final trimmedTitle = _titleController.text.trim();

    widget.chapter.noteContent = trimmedBody;
    widget.chapter.noteTitle = trimmedTitle.isEmpty ? widget.chapter.title : trimmedTitle;
    widget.chapter.isNotePinned = _isPinned;
    widget.chapter.noteColorHex = _selectedColorHex;
    widget.chapter.noteUpdatedAtMs = DateTime.now().millisecondsSinceEpoch;

    // Guardado ultraligero (< 0.2ms) en cada tecla para que jamás se pierda aunque se apague el celular
    await _repository.saveBookNotesFast(widget.book);
    widget.onNoteChanged();

    if (mounted && !_justSavedIndicator) {
      setState(() {
        _justSavedIndicator = true;
      });
    }

    _debounceFullSaveTimer?.cancel();
    _debounceFullSaveTimer = Timer(const Duration(milliseconds: 900), () {
      _repository.updateSingleBookInStorage(widget.book);
    });
  }

  @override
  void dispose() {
    _debounceFullSaveTimer?.cancel();
    // Asegurar guardado completo en el libro al salir
    _repository.saveBookNotesFast(widget.book);
    _repository.updateSingleBookInStorage(widget.book);
    _titleController.removeListener(_onTextEdited);
    _bodyController.removeListener(_onTextEdited);
    _titleController.dispose();
    _bodyController.dispose();
    _bodyFocusNode.dispose();
    super.dispose();
  }

  void _wrapSelectionOrInsert(String prefix, String suffix, String placeholder) {
    final text = _bodyController.text;
    final sel = _bodyController.selection;

    if (!sel.isValid || sel.start < 0) {
      final addition = text.isEmpty ? '$prefix$placeholder$suffix' : '$text$prefix$placeholder$suffix';
      _bodyController.value = TextEditingValue(
        text: addition,
        selection: TextSelection(
          baseOffset: addition.length - suffix.length - placeholder.length,
          extentOffset: addition.length - suffix.length,
        ),
      );
      _bodyFocusNode.requestFocus();
      return;
    }

    final start = sel.start;
    final end = sel.end;
    if (start != end) {
      final selectedText = text.substring(start, end);
      final replacement = '$prefix$selectedText$suffix';
      final newText = text.replaceRange(start, end, replacement);
      _bodyController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start + replacement.length),
      );
    } else {
      final replacement = '$prefix$placeholder$suffix';
      final newText = text.replaceRange(start, end, replacement);
      _bodyController.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start + prefix.length,
          extentOffset: start + prefix.length + placeholder.length,
        ),
      );
    }
    _bodyFocusNode.requestFocus();
  }

  void _insertLinePrefix(String prefix, {bool autoIncrementNumber = false}) {
    final text = _bodyController.text;
    final sel = _bodyController.selection;
    final cursor = (sel.isValid && sel.start >= 0) ? sel.start : text.length;

    // Buscar inicio de la línea actual
    final lineStart = cursor == 0 ? 0 : text.lastIndexOf('\n', cursor - 1) + 1;
    final currentLine = text.substring(lineStart, cursor);

    String actualPrefix = prefix;
    if (autoIncrementNumber) {
      final prevNumbers = RegExp(r'^(\d+)\.\s', multiLine: true).allMatches(text.substring(0, cursor));
      if (prevNumbers.isNotEmpty) {
        final lastNum = int.tryParse(prevNumbers.last.group(1) ?? '0') ?? 0;
        actualPrefix = '${lastNum + 1}. ';
      } else {
        actualPrefix = '1. ';
      }
    }

    if (currentLine.trim().isEmpty) {
      final newText = text.replaceRange(lineStart, cursor, actualPrefix);
      _bodyController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: lineStart + actualPrefix.length),
      );
    } else {
      final insertion = '\n$actualPrefix';
      final newText = text.replaceRange(cursor, cursor, insertion);
      _bodyController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: cursor + insertion.length),
      );
    }
    _bodyFocusNode.requestFocus();
  }

  void _insertSpokenQuote() {
    final quote = widget.currentSpokenParagraph?.trim();
    if (quote == null || quote.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay un párrafo activo en este momento'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    final segBadge = widget.currentSegmentNumber != null ? ' (Párr. ${widget.currentSegmentNumber})' : '';
    final formattedQuote = '❝ $quote ❞$segBadge\n';
    final text = _bodyController.text;
    final prefix = text.isNotEmpty && !text.endsWith('\n') ? '\n\n' : '';
    final newText = '$text$prefix$formattedQuote';

    _bodyController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    _bodyFocusNode.requestFocus();
  }

  void _confirmDeleteNote() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1B20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '¿Borrar nota de esta sección?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
        ),
        content: Text(
          'Se eliminará todo lo escrito en "${widget.chapter.title}".',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              _bodyController.clear();
              _titleController.text = widget.chapter.title;
              setState(() {
                _isPinned = false;
                _selectedColorHex = 0xFF141519;
              });
              widget.chapter.noteContent = null;
              widget.chapter.noteTitle = null;
              widget.chapter.isNotePinned = false;
              widget.chapter.noteColorHex = 0xFF141519;
              widget.chapter.noteUpdatedAtMs = null;
              await _repository.saveBookNotesFast(widget.book);
              await _repository.updateSingleBookInStorage(widget.book);
              widget.onNoteChanged();
              if (mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text('Borrar nota'),
          ),
        ],
      ),
    );
  }

  void _showAddActionMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1B20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  'Insertar en tu nota',
                  style: TextStyle(
                    color: Color(0xFFF5A623),
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
              if (widget.currentSpokenParagraph != null &&
                  widget.currentSpokenParagraph!.trim().isNotEmpty)
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0x28F5A623),
                    child: Icon(Icons.format_quote_rounded, color: Color(0xFFF5A623)),
                  ),
                  title: const Text(
                    'Insertar párrafo que está sonando ahora',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  subtitle: Text(
                    widget.currentSpokenParagraph!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _insertSpokenQuote();
                  },
                ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.white10,
                  child: Icon(Icons.title_rounded, color: Colors.white),
                ),
                title: const Text(
                  'Agregar Subtítulo de Sección (ej. Ideas Clave)',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _insertLinePrefix('# ');
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.white10,
                  child: Icon(Icons.format_list_numbered_rounded, color: Colors.white),
                ),
                title: const Text(
                  'Agregar Paso Numerado (1. 2. 3.)',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _insertLinePrefix('1. ', autoIncrementNumber: true);
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Colors.white10,
                  child: Icon(Icons.format_list_bulleted_rounded, color: Colors.white),
                ),
                title: const Text(
                  'Agregar Viñeta (•)',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _insertLinePrefix('• ');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1B20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy_rounded, color: Color(0xFFF5A623)),
                title: const Text(
                  'Copiar toda la nota al portapapeles',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  final fullText = '${_titleController.text}\n\n${_bodyController.text}'.trim();
                  Clipboard.setData(ClipboardData(text: fullText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('📋 Nota copiada al portapapeles'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                title: const Text(
                  'Borrar toda la nota de esta sección',
                  style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteNote();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = Color(_selectedColorHex);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            // 1. BARRA SUPERIOR ESTILO GOOGLE KEEP (← | [📌] [❝] [📋])
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 14, 6),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 24),
                    tooltip: 'Guardar y volver',
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  _buildTopPillIconButton(
                    icon: _isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    isActive: _isPinned,
                    tooltip: _isPinned ? 'Nota fijada como importante' : 'Fijar nota importante',
                    onTap: () {
                      setState(() {
                        _isPinned = !_isPinned;
                      });
                      _persistImmediately();
                    },
                  ),
                  const SizedBox(width: 8),
                  if (widget.currentSpokenParagraph != null &&
                      widget.currentSpokenParagraph!.trim().isNotEmpty) ...[
                    _buildTopPillIconButton(
                      icon: Icons.format_quote_rounded,
                      isActive: false,
                      tooltip: 'Pegar frase actual del audiolibro',
                      onTap: _insertSpokenQuote,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _buildTopPillIconButton(
                    icon: Icons.copy_all_rounded,
                    isActive: false,
                    tooltip: 'Copiar nota',
                    onTap: () {
                      final fullText = '${_titleController.text}\n\n${_bodyController.text}'.trim();
                      Clipboard.setData(ClipboardData(text: fullText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('📋 Nota copiada al portapapeles'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  if (_bodyController.text.trim().isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _buildTopPillIconButton(
                      icon: Icons.delete_outline_rounded,
                      isActive: false,
                      iconColor: Colors.redAccent.shade100,
                      tooltip: 'Borrar nota',
                      onTap: _confirmDeleteNote,
                    ),
                  ],
                ],
              ),
            ),

            // 2. HOJA DE ESCRITURA FLUIDA (TÍTULO + CONTENIDO)
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 6, 22, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Insignia de sección y estado de auto-guardado permanente
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5A623).withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFFF5A623).withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            'Sección ${widget.chapter.id.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: Color(0xFFF5A623),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(
                          Icons.cloud_done_rounded,
                          size: 14,
                          color: _justSavedIndicator
                              ? const Color(0xFF81C784)
                              : Colors.white38,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _justSavedIndicator
                              ? 'Guardado en memoria permanente'
                              : 'Auto-guardado activo',
                          style: TextStyle(
                            color: _justSavedIndicator ? const Color(0xFF81C784) : Colors.white38,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Campo de Título (como "Mathieu's Homemade Poutine" en Imagen 2)
                    TextField(
                      controller: _titleController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        height: 1.25,
                      ),
                      maxLines: null,
                      decoration: const InputDecoration(
                        hintText: 'Título de la nota...',
                        hintStyle: TextStyle(
                          color: Colors.white30,
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Campo Principal de la Nota con soporte de Negrita, Cursiva, Subrayado y Pasos
                    TextField(
                      controller: _bodyController,
                      focusNode: _bodyFocusNode,
                      autofocus: (widget.chapter.noteContent ?? '').trim().isEmpty,
                      style: const TextStyle(
                        color: Color(0xFFEAECEF),
                        fontSize: 16.5,
                        height: 1.55,
                      ),
                      maxLines: null,
                      minLines: 14,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText:
                            'Escribí acá tus ideas clave, resúmenes o reflexiones de esta sección...\n\n'
                            '• Tocá el botón [A] abajo para Negrita, Cursiva, Subrayado o Pasos (1. 2. 3.).\n'
                            '• Tocá [+] para pegar la frase que está leyendo el narrador.',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.26),
                          fontSize: 15.5,
                          height: 1.5,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 3. BARRA DESPLEGABLE DE COLORES ([🎨])
            if (_showColorBar)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.28),
                  border: const Border(top: BorderSide(color: Colors.white10)),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _studioColors.map((c) {
                      final int hex = c['hex'] as int;
                      final String name = c['name'] as String;
                      final bool isSelected = _selectedColorHex == hex;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedColorHex = hex;
                          });
                          _persistImmediately();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(right: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Color(hex),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isSelected ? const Color(0xFFF5A623) : Colors.white24,
                              width: isSelected ? 2.0 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isSelected) ...[
                                const Icon(Icons.check_rounded, size: 15, color: Color(0xFFF5A623)),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                name,
                                style: TextStyle(
                                  color: isSelected ? const Color(0xFFF5A623) : Colors.white70,
                                  fontSize: 12,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),

            // 4. BARRA DE HERRAMIENTAS DE FORMATO ([A]: H1, B, I, U, 1., •)
            if (_showFormattingBar)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  border: const Border(top: BorderSide(color: Colors.white10)),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFormatChip(
                        label: 'Subtítulo',
                        icon: Icons.title_rounded,
                        onTap: () => _insertLinePrefix('# '),
                      ),
                      _buildFormatChip(
                        label: 'Negrita',
                        icon: Icons.format_bold_rounded,
                        onTap: () => _wrapSelectionOrInsert('**', '**', 'texto en negrita'),
                      ),
                      _buildFormatChip(
                        label: 'Cursiva',
                        icon: Icons.format_italic_rounded,
                        onTap: () => _wrapSelectionOrInsert('*', '*', 'cursiva'),
                      ),
                      _buildFormatChip(
                        label: 'Subrayado',
                        icon: Icons.format_underlined_rounded,
                        onTap: () => _wrapSelectionOrInsert('__', '__', 'subrayado'),
                      ),
                      _buildFormatChip(
                        label: '1. Pasos',
                        icon: Icons.format_list_numbered_rounded,
                        onTap: () => _insertLinePrefix('1. ', autoIncrementNumber: true),
                      ),
                      _buildFormatChip(
                        label: '• Lista',
                        icon: Icons.format_list_bulleted_rounded,
                        onTap: () => _insertLinePrefix('• '),
                      ),
                    ],
                  ),
                ),
              ),

            // 5. BARRA INFERIOR IDÉNTICA A TU IMAGEN 2: [+] [🎨] [A] ........... [⋮]
            Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, bottomInset > 0 ? 8 : 14),
              child: Row(
                children: [
                  _buildBottomCircleButton(
                    icon: Icons.add_box_outlined,
                    isActive: false,
                    tooltip: 'Insertar cita o lista',
                    onTap: _showAddActionMenu,
                  ),
                  const SizedBox(width: 10),
                  _buildBottomCircleButton(
                    icon: Icons.palette_outlined,
                    isActive: _showColorBar,
                    tooltip: 'Color de la nota',
                    onTap: () {
                      setState(() {
                        _showColorBar = !_showColorBar;
                      });
                    },
                  ),
                  const SizedBox(width: 10),
                  _buildBottomCircleButton(
                    icon: Icons.text_format_rounded,
                    isActive: _showFormattingBar,
                    tooltip: 'Herramientas de formato (Negrita, Cursiva, Subrayado)',
                    onTap: () {
                      setState(() {
                        _showFormattingBar = !_showFormattingBar;
                      });
                    },
                  ),
                  const Spacer(),
                  _buildBottomCircleButton(
                    icon: Icons.more_vert_rounded,
                    isActive: false,
                    tooltip: 'Más opciones (Copiar / Borrar)',
                    onTap: _showMoreMenu,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopPillIconButton({
    required IconData icon,
    required bool isActive,
    required String tooltip,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFFF5A623)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? const Color(0xFFF5A623)
                  : Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isActive ? Colors.black : (iconColor ?? Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildFormatChip({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: const Color(0xFFF5A623)),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomCircleButton({
    required IconData icon,
    required bool isActive,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? const Color(0xFFF5A623).withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.08),
            border: Border.all(
              color: isActive
                  ? const Color(0xFFF5A623)
                  : Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: isActive ? const Color(0xFFF5A623) : Colors.white,
          ),
        ),
      ),
    );
  }
}
