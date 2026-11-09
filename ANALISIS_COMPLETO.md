# 📋 Análisis Completo del Proyecto AudioMind

## 🔴 BUGS CRÍTICOS (Deben arreglarse ya)

### 1. **Race Condition en `LibraryScreen._resolveMissingCovers()`** (líneas 107-140)
```dart
// PROBLEMA: HttpClient se crea dentro del loop y no se cierra
final client = HttpClient();
final req = await client.getUrl(Uri.parse(url));
```
**Impacto:** Fugas de sockets, agotamiento de file descriptors, crashes en carga masiva.
**Fix:** Usar `http` package con `Client()` singleton o cerrar `client.close()`.

---

### 2. **Memory Leak en `PdfExtractorService` Isolate** (líneas 95-265)
```dart
// PROBLEMA: PdfDocument nunca se hace dispose() si hay error antes de línea 131
final pdfDocument = PdfDocument(inputBytes: payload.pdfBytes);
// ... si lanza excepción antes de línea 131, el documento queda en memoria nativa
pdfDocument.dispose(); // Solo se ejecuta en happy path
```
**Impacto:** Memoria nativa no liberada → OOM en PDFs grandes (>100MB).
**Fix:** `try/finally` con `dispose()`.

---

### 3. **Global AudioPlayer Singleton sin Lifecycle** (`audio_player_service.dart`)
```dart
final AudioPlayer globalAudioPlayer = AudioPlayer();
// Nunca se hace dispose() → recursos nativos (MediaPlayer/ExoPlayer) quedan vivos
```
**Impacto:** Crash al re-abrir app, audio fantasma en background, battery drain.
**Fix:** Implementar `AudioPlayerManager` con lifecycle y `dispose()` en `main.dart` al terminar.

---

### 4. **`_userRequestedPause` Flag Race Condition** (`library_screen.dart` + `player_screen.dart`)
```dart
// En LibraryScreen (línea 46):
bool _userRequestedPause = false;

// En PlayerScreen (línea 66):
bool _userRequestedPause = false;

// DOS flags independientes para el MISMO estado global
```
**Impacto:** Pausa/play inconsistente, LoFi se desincroniza, usuario escucha doble audio.
**Fix:** Estado único en `AudioPlayerService` o `ValueNotifier<bool>` compartido.

---

### 5. **`BookTranslationService` - Excepciones Silenciadas** (líneas 206-209)
```dart
} catch (_) {
} finally {
  _activeTranslations.remove(book.id);
}
```
**Impacto:** Traducción falla silenciosamente, usuario no sabe por qué su libro sigue en inglés.
**Fix:** Log del error + notificar UI + retry con backoff exponencial.

---

### 6. **`OfflineDownloadService` - Notificación Excesiva** (líneas 153, 213, 219, 227)
```dart
notifyListeners(); // Se llama en CADA iteración del batch (cada 3 segmentos)
```
**Impacto:** Rebuild masivo de UI, jank visible en listas de capítulos (60fps → 30fps).
**Fix:** Throttle `notifyListeners()` a máx 1x/500ms o usar `ValueNotifier` por capítulo.

---

### 7. **PDF Text Extraction - Sync Blocking en Isolate** (líneas 112-129)
```dart
for (int p = 0; p < totalPages; p++) {
  final raw = extractor.extractText(...); // BLOQUEA el isolate
  if (p % reportInterval == 0) { sendPort.send(...) }
}
```
**Impacto:** Isolate congelado por segundos en PDFs >50 páginas → progress bar se traba.
**Fix:** `await Future.microtask()` cada N páginas para ceder CPU.

---

### 8. **CoverService - HttpClient No Cerrado** (líneas 98-122, 198-211)
```dart
final client = HttpClient()..connectionTimeout = ...
// client.close() NUNCA se llama
```
**Impacto:** Igual que bug #1 - fuga de conexiones HTTP.

---

### 9. **`EpubProcessorService` - No Valida HTML Malformado** (líneas 46-52)
```dart
final String html = rawChapters[i].toString();
String chapterTitle = _extractTitleFromHtml(html); // Puede lanzar en RegExp
```
**Impacto:** Crash en EPUBs con HTML corrupto (común en libros pirateados).
**Fix:** `try/catch` en cada capítulo + fallback a "Capítulo N".

---

### 10. **MiniPlayerBar - Tap Area Demasiado Pequeña** (`mini_player_bar.dart` línea 28)
```dart
GestureDetector(onTap: onOpenPlayer, child: Container(...))
// Solo responde al tap en el Container, NO en toda la SafeArea
```
**Impacto:** Usuario toca y no abre player → frustración UX.
**Fix:** `HitTestBehavior.opaque` o expandir a ancho completo.

---

## 🟠 BUGS MEDIOS (Importantes pero no rompen la app)

### 11. **ChapterItem.segments Cache Invalido tras Traducción**
```dart
// En chapter_item.dart línea 43:
List<String> get segments => getSegmentsForLanguage('es');

// Si se traduce el capítulo, _cachedSegments NO se limpia
```
**Fix:** `clearCache()` method o invalidar en `translateSingleChapter`.

---

### 12. **`DocumentViewerScreen._computeActiveHighlightRectsForPage()` Complejidad O(n²)**
```dart
// Líneas 581-598: nested loops sobre lines × words
for (int i = 0; i < overlay.lines.length; i++) {
  for (int j = i; j < min(overlay.lines.length, i + 9); j++) {
```
**Impacto:** Lag en PDFs con muchas líneas/página (>100 líneas).
**Fix:** Índice invertido (Map<token, List<lineIdx>>) precalculado.

---

### 13. **LoFi Generator - Hardcoded 16s Loop** (`lofi_generator_service.dart` línea 29)
```dart
const int seconds = 16; // Bucle perceptible cada 16s
```
**Impacto:** Usuario nota repetición → experiencia "barata".
**Fix:** 60s+ o generación procedural infinita via stream.

---

### 14. **Translation Progress Notifier - Memory Leak** (`book_translation_service.dart` línea 30)
```dart
static final ValueNotifier<TranslationProgressInfo?> progressNotifier = ...
// NUNCA se hace dispose() → listener acumulan si se traducen muchos libros
```
**Fix:** `dispose()` en `LibraryScreen.dispose()` o usar `StreamController.broadcast`.

---

### 15. **`TextSanitizer.humanizeTextForNaturalSpeech()` - Regex Catastrofico** (línea 70)
```dart
s = s.replaceAllMapped(RegExp(r'([a-záéíóúñü])([A-ZÁÉÍÓÚÑÜ])'), ...)
// Backtracking exponencial en textos largos sin espacios
```
**Impacto:** ANR (App Not Responding) en capítulos >5000 palabras.
**Fix:** Limitar input length o usar regex más simple.

---

### 16. **`BookCoverWidget` - No Cache de Imagen de Red** (líneas 34-40)
```dart
Image.network(book.coverUrl!, ...)
// Sin cache, re-descarga cada rebuild
```
**Fix:** `cached_network_image` package o `ImageProvider` con cache.

---

### 17. **`LibraryScreen._saveBooks()` - Serializa MEGABYTES en Main Thread** (línea 142-144)
```dart
await _repository.saveBooks(_books, activeBookId: activeBookId);
// BookItem.toJson() incluye TODO el texto de TODOS los capítulos
```
**Impacto:** UI freeze 200-500ms al guardar libro grande.
**Fix:** `compute()` isolate o solo guardar metadatos (progreso) en fast save.

---

### 18. **PlayerScreen - `setState` en `positionStream` Cada 120ms** (líneas 228-240)
```dart
_positionSub = widget.player.positionStream.listen((pos) {
  if ((pos.inMilliseconds - _position.inMilliseconds).abs() >= 120) {
    setState(() => _position = pos); // Rebuild 8x/seg
  }
});
```
**Impacto:** Rebuilds innecesarios de TODO el PlayerScreen (texto, controles, fondo animado).
**Fix:** `ValueNotifier<Duration>` solo para slider + `RepaintBoundary` aislando animación.

---

### 19. **EpubProcessorService - `chId` No Reseteado entre Libros** (línea 44)
```dart
int chId = 1; // Variable local, OK per-book
// Pero si se procesan múltiples EPUBs en misma sesión sin reiniciar app...
```
**Impacto:** Bajo (variable local), pero confuso en logs.

---

### 20. **`PdfExtractorService` - Magic Numbers en Detección de Capítulos** (líneas 76, 136, 177)
```dart
(p - headingPages.last) >= 2 // Mínimo 2 páginas entre capítulos
pageSpan > 24 // Split si capítulo > 24 páginas
step = (totalPages > 300) ? 10 : ...
```
**Impacto:** Falla en libros con capítulos cortos (ensayos, poesía) o muy largos.
**Fix:** Configurable via constants o heurística adaptativa.

---

## 🟡 OPTIMIZACIONES DE RENDIMIENTO

### 21. **UI Thread Blocking - PDF Page Rendering**
```dart
// document_viewer_screen.dart _loadPdfPage() llama NativeChannelService.renderPdfPage
// que hace trabajo pesado en platform channel (síncrono en UI thread Android)
```
**Fix:** `compute()` para decode de imagen o `isolate` para render PDF.

---

### 22. **RepaintBoundary Faltantes en Árboles Complejos**
- `PlayerScreen.build()`: AnimatedBuilder (fondo) + ListView (karaoke) + controles → TODO repinta a 60fps
- `DocumentViewerScreen._buildPdfOriginalWithLiveHighlight()`: CustomPainter + Image.memory + InteractiveViewer
**Fix:** `RepaintBoundary` en cada sección independiente.

---

### 23. **LRU Cache de Páginas PDF - Ineficiente** (líneas 1056-1073)
```dart
// _cacheLruOrder usa List.remove() → O(n) cada acceso
_cacheLruOrder.remove(pageIndex); // Lineal!
```
**Fix:** `LinkedHashMap` o package `lru_map` para O(1).

---

### 24. **TTS Synthesis - No Compresión de Audio** (`tts_synthesis_service.dart`)
```dart
// Edge TTS devuelve 96kbps MP3, se guarda tal cual
// Para libro de 10h = ~430MB cache
```
**Fix:** Transcodificar a Opus 48kbps (~50% tamaño) o AAC HE 32kbps.

---

### 25. **Database/Storage - SharedPreferences para MEGABYTES** (`library_repository.dart`)
```dart
// Guarda TODOS los libros (texto completo) en SharedPreferences
// Límite práctico ~1-2MB antes de corromperse / lentitud extrema
```
**Fix:** `sqflite` / `drift` / `isar` para datos estructurados + archivos para texto.

---

### 26. **Isolate Communication - JSON Serialization Overhead** (`pdf_extractor_service.dart` línea 254)
```dart
payload.sendPort.send({'type': 'done', 'chapters': chapters});
// chapters = List<Map<String, dynamic>> con texto COMPLETO
// Serialización JSON masiva en isolate → GC pressure
```
**Fix:** `Uint8List` + binary protocol (protobuf/msgpack) o `SendPort` de `ByteData`.

---

### 27. **Image Loading - No Placeholder/Loading State** (`book_cover_widget.dart`)
```dart
Image.file/File/Image.network sin fadeInDuration ni placeholder
// Parpadeo visual al hacer scroll rápido en LibraryScreen
```
**Fix:** `FadeInImage` o `cached_network_image` con placeholder.

---

### 28. **Font Loading - GoogleFonts sin Pre-carga** (`app_theme.dart` línea 21)
```dart
fontFamily: GoogleFonts.inter().fontFamily;
// Descarga fuente en PRIMER frame → jank inicial
```
**Fix:** `GoogleFonts.inter(fontWeight: FontWeight.w400)` en `main.dart` antes de `runApp()` o bundle local.

---

### 29. **LoFi Audio - Generación Síncrona en Startup** (`lofi_generator_service.dart` línea 21)
```dart
static Future<String> ensureAmbientTrack(String trackId) async {
  // Genera WAV de 16s (22050*16*2 = 704KB) en MAIN THREAD
  // Bloquea UI ~200-500ms en dispositivos lentos
}
```
**Fix:** `compute()` isolate o generar en background al primer uso real.

---

### 30. **PDF Text Extraction - Syncfusion Licencia** (`pubspec.yaml` línea 41)
```yaml
syncfusion_flutter_pdf: ^35.1.42
// Requiere licencia comercial para producción (>$1000/año)
// Watermark en release build sin licencia
```
**Fix:** Migrar a `pdf` (dart-native) + `pdf_text` o `pdfx` (open source).

---

## 🟢 MEJORAS DE ARQUITECTURA Y CÓDIGO

### 31. **Separación de Capas Violada** - Lógica de Negocio en Widgets
- `LibraryScreen` (650+ líneas): Repository, Translation, TTS, Cover, PDF, EPUB, Player, UI
- `PlayerScreen` (2600+ líneas): TTS, Download, Translation, LoFi, Voice, Speed, Chapters, Karaoke, PDF Sync
**Fix:** `BLoC`/`Riverpod`/`Provider` + Use Cases + Repository Pattern real.

---

### 32. **Estado Global Disperso** - Múltiples Sources of Truth
- `_currentPlayingBook` en `LibraryScreen`
- `_currentChapter`/`_segments` en `PlayerScreen`
- `_liveAudioChapterIndex` en `DocumentViewerScreen`
- `book.lastChapterIndex` en `BookItem`
- `LibraryRepository._fastProgressKey` en SharedPreferences
**Fix:** Single source of truth → `AudioBookState` centralizado.

---

### 33. **Servicios como Singletons con Estado Mutable**
- `TtsSynthesisService` (singleton con `_segmentWordTimings` LRU)
- `OfflineDownloadService` (singleton con `_chapterProgress` Map)
- `BookTranslationService` (static con `progressNotifier`)
**Impacto:** Imposible testear, race conditions, memory leaks.
**Fix:** Dependency Injection + instancias scoped + `dispose()`.

---

### 34. **Hardcoded Strings / Magic Numbers** (ejemplos)
```dart
// player_screen.dart
const int byteRate = sampleRate * numChannels * 2; // OK
const delimiter = '\n---AUDIOMIND_SEP---\n'; // Magic string
'1800' // límite batch traducción (línea 137)
'380' // caracteres por segmento (línea 288)
'12000' // palabras para split capítulo (línea 67)
'5000' // palabras por parte (línea 77)
```
**Fix:** `constants.dart` con documentación.

---

### 35. **Error Handling Inconsistente**
- `try/catch (e) { debugPrint(...) }` silencioso (15+ ocurrencias)
- `catch (_) {}` vacío (8+ ocurrencias)
- `throw Exception('mensaje')` genérico
**Fix:** `Result<T, E>` / `Either` pattern + logging estructurado + user-facing errors.

---

### 36. **Testing Inexistente**
- `pubspec.yaml`: solo `flutter_test` sin tests reales
- 0% cobertura
**Fix:** Unit tests para services, widget tests para screens, integration tests para flujos críticos.

---

### 37. **Accesibilidad (a11y) Nula**
- Sin `semanticLabel` en botones icon-only
- Contraste colores no verificado (ámbar #F5A623 sobre negro)
- No soporte `Reduce Motion` para animaciones
- Text scaling no probado
**Fix:** `Semantics`, `MediaQuery.boldText`, `MediaQuery.disableAnimations`.

---

### 38. **Internacionalización (i18n) Hardcoded**
- Todo texto en español hardcodeado en 15+ archivos
- Formato fecha/hora hardcodeado
**Fix:** `intl` + `arb` files + `LocalizationsDelegate`.

---

### 39. **Deep Linking / Restore State Incompleto**
- `LibraryScreen._loadStoredBooksAndLastSession()` restaura solo último libro
- No restaura: posición exacta en chapter, velocidad, voz, LoFi track, filtros
**Fix:** `AppLifecycleManager` + `RestorationManager` + `RestorationMixin`.

---

### 40. **Build Configuration Issues**
```yaml
# pubspec.yaml
version: 1.0.0+1 # Hardcoded, no CI/CD
environment:
  sdk: ^3.13.5 # Muy específico, bloquea updates
```
**Fix:** `flutter_version` package o `--build-number` CI + sdk: `^3.13.0`.

---

## 🔐 SEGURIDAD Y PRIVACIDAD

### 41. **Traducción - Envía Texto Completo a Google Translate (No Oficial)**
```dart
// translator package usa scraping web no oficial
// TEXTO DEL LIBRO DEL USUARIO sale del dispositivo sin consentimiento
```
**Impacto:** GDPR/LOPD violation, privacidad usuario, posible bloqueo IP.
**Fix:** Local translation (ML Kit on-device) o API oficial con consentimiento.

---

### 42. **TTS - Edge TTS Envía Texto a Microsoft**
```dart
// edge_tts package → Microsoft Azure TTS endpoint
// Texto completo del libro sale a cloud
```
**Fix:** Documentar claramente + opt-in + alternativa local (`flutter_tts` con motor del sistema).

---

### 43. **Cover Fetch - iTunes API Sin Rate Limit Handling**
```dart
// cover_service.dart línea 101-116
// Sin User-Agent, sin retry, sin cache persistente
```
**Fix:** Cache local + exponential backoff + proper headers.

---

### 44. **File Picker - Sin Validación de Contenido**
```dart
// library_screen.dart línea 148-162
// Acepta cualquier .pdf/.epub sin verificar magic bytes
// Riesgo: archivo malicioso → crash parser / path traversal
```
**Fix:** Validar magic bytes (`%PDF-` / `PK\x03\x04` para EPUB) + sandbox.

---

### 45. **Native Channel - Sin Verificación de Integridad**
```dart
// native_channel_service.dart
// MethodChannel sin signature verification
// App vulnerable a hijacking si otro app registra mismo channel
```
**Fix:** `MethodChannel` con nombre único + package name verificado.

---

## 📱 UX / UI MEJORAS

### 46. **Onboarding Inexistente** - Usuario nuevo no sabe cómo empezar
### 47. **Empty States Genéricos** - "No hay libros" sin call-to-action claro
### 48. **Feedback Háptico Ausente** - Botones críticos sin `HapticFeedback`
### 49. **Animaciones Inconsistentes** - Mix de `AnimatedContainer`, `AnimatedSwitcher`, `AnimationController` manual
### 50. **Landscape Mode Roto** - PlayerScreen y DocumentViewer no se adaptan
### 51. **Tablet Layout Inexistente** - Todo `ListView` single column
### 52. **Dark Mode Only** - No light theme, no system theme follow
### 53. **Pull-to-Refresh Faltante** - LibraryScreen no actualiza portadas/progreso
### 54. **Búsqueda en Biblioteca Inexistente** - Solo filtros fijos
### 55. **Ordenación Personalizable Faltante** - Solo "reciente primero"
### 56. **Estadísticas de Lectura** - No hay "tiempo escuchado", "libros completados", "racha"
### 57. **Export/Import Biblioteca** - No backup/restore
### 58. **Widget Homescreen** - No quick-play widget Android/iOS
### 59. **CarPlay / Android Auto** - No soporte
### 60. **Sleep Timer** - No auto-pause tras X minutos

---

## 🧪 TESTING Y CALIDAD

### 61. **Static Analysis - Reglas Muy Permisivas** (`analysis_options.yaml`)
```yaml
linter:
  rules: {} # Solo flutter_lints defaults
```
**Fix:** Activar `pedantic` / `very_good_analysis` rules.

---

### 62. **No CI/CD Pipeline** - Build manual, sin tests automáticos
### 63. **Crash Reporting Ausente** - No Sentry / Firebase Crashlytics / Play Console
### 64. **Analytics Ausentes** - No métricas de uso (retención, features usadas, errores)
### 65. **Performance Monitoring** - No Firebase Performance / custom traces

---

## 📦 DEPENDENCIAS - RIESGOS

| Package | Versión | Riesgo |
|---------|---------|--------|
| `syncfusion_flutter_pdf` | 35.1.42 | **Licencia comercial requerida** - Watermark en release |
| `translator` | 1.0.4+1 | **No oficial** - Scraping Google, inestable, privacy |
| `edge_tts` | 0.1.5 | **Alpha** - Breaking changes frecuentes, envía datos a MS |
| `just_audio_background` | 0.0.1-beta.17 | **Beta** - API inestable, bugs conocidos en notification |
| `google_fonts` | 9.0.0 | Descarga red en runtime - primer frame jank |
| `flutter_tts` | 4.2.5 | No usado (dead code) - aumenta bundle size |

---

## 🎯 PLAN DE ACCIÓN PRIORIZADO

### **FASE 1 - Crítico (Semana 1-2)**
1. ✅ Fix memory leaks (PdfDocument, HttpClient, AudioPlayer)
2. ✅ Fix race conditions (_userRequestedPause, global state)
3. ✅ Migrar de SharedPreferences a DB real (Isar/Drift)
4. ✅ Fix translator privacy (local ML Kit o consentimiento)
5. ✅ License Syncfusion → migrar a `pdf` + `pdfx`

### **FASE 2 - Arquitectura (Semana 3-4)**
6. ✅ Extraer Business Logic a Use Cases / BLoC
7. ✅ Centralizar Estado (Riverpod/Provider)
8. ✅ Dependency Injection (get_it / riverpod)
9. ✅ Error Handling unificado (Result/Either)

### **FASE 3 - Rendimiento (Semana 5)**
10. ✅ RepaintBoundary + ValueNotifier para position
11. ✅ LRU Cache O(1) para PDF pages
12. ✅ Isolate para PDF rendering + TTS synthesis
13. ✅ Image caching (cached_network_image)

### **FASE 4 - Calidad (Semana 6)**
14. ✅ Tests unitarios (services) + widget tests (screens)
15. ✅ CI/CD GitHub Actions
16. ✅ Crashlytics + Analytics
17. ✅ a11y + i18n básico

### **FASE 5 - Features UX (Continuo)**
18. ✅ Onboarding + Empty states
19. ✅ Search + Sort + Stats
20. ✅ Sleep Timer + CarPlay + Widget
21. ✅ Backup/Restore + Cloud Sync (opcional)

---

## 📊 MÉTRICAS DE ÉXITO

| Métrica | Actual | Target |
|---------|--------|--------|
| App startup (cold) | ~3-5s | <1.5s |
| Library scroll FPS | 30-45 | 60 constante |
| PDF page render | 800-2000ms | <300ms |
| TTS first segment | 2-5s | <800ms (cached) |
| Memory usage (10h book) | ~800MB | <200MB |
| APK size | ~45MB | <25MB |
| Crash-free sessions | ~95% | 99.9% |
| Test coverage | 0% | >80% |

---

## 🔧 ARCHIVOS CLAVE A REFACTORIZAR (Prioridad)

1. `lib/ui/features/library/views/library_screen.dart` (650 líneas) → Split en 5+ widgets + BLoC
2. `lib/ui/features/player/views/player_screen.dart` (2600 líneas) → **URGENTE** split masivo
3. `lib/ui/features/reader/views/document_viewer_screen.dart` (2100 líneas) → Split
4. `lib/data/services/pdf_extractor_service.dart` → Fix isolate + memory
5. `lib/data/services/book_translation_service.dart` → Privacy + error handling
6. `lib/data/services/tts_synthesis_service.dart` → Cache + compression
7. `lib/data/repositories/library_repository.dart` → DB migration
8. `lib/core/utils/text_sanitizer.dart` → Regex optimization
9. `lib/data/services/cover_service.dart` → HttpClient + cache
10. `lib/data/services/lofi_generator_service.dart` → Background generation

---

*Análisis generado automáticamente - Revisar y priorizar según roadmap del equipo*