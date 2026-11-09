# 🏛️ Audibuuks: Arquitectura e Ingeniería de Software (v1.0.0)
**Autor:** Luciano Gutierrez (Lukgtz)  
**Proyecto:** Audibuuks Mobile Client (`com.lo.audiomind.audiomind`)  
**Ecosistema:** Flutter 3.x / Dart 3.x / Android Native NDK & MediaSession API  

---

## 1. Resumen Ejecutivo del Sistema
**Audibuuks** es una plataforma móvil de alto rendimiento diseñada para la ingesta, procesamiento tipográfico, síntesis de voz neuronal (Neural TTS) y renderizado auditivo continuo de documentos digitales complejos (**PDF y EPUB**) en entornos móviles con restricciones estrictas de hardware y ciclo de vida de batería.

### Pilares de Diseño:
- **Zero-Latency Reactive TTS:** Síntesis y prefetching concurrente de fragmentos de audio en streaming.
- **Persistent Headless Playback:** Supervivencia de reproducción en segundo plano y pantalla bloqueada mediante `MediaSessionService` nativo de Android.
- **Non-blocking Isolates Pipeline:** Extracción y depuración de texto en hilos nativos desacoplados para garantizar 60/120 FPS en la interfaz de usuario.
- **Clean Architecture & High Cohesion:** Separación estricta de responsabilidades en capas (UI, Dominio, Datos y Servicios de Infraestructura).

---

## 2. Diagrama de Arquitectura de Capas (Clean Architecture)

```mermaid
graph TD
    subgraph UI_Presentation["🎨 Capa de Presentación (UI & State)"]
        SplashScreen["SplashScreen (Animada a 60 FPS)"]
        LibraryScreen["LibraryScreen (Grid reactivo, filtros, modals)"]
        PlayerScreen["PlayerScreen (Orquestador desacoplado)"]
        DocViewer["DocumentViewerScreen (Visor y Subrayado dinámico)"]
        
        subgraph ModularPlayerWidgets["Componentes Modulares del Reproductor"]
            STSheet["SleepTimerSheet"]
            AMSheet["AmbientMusicSheet"]
            VSSheet["VoicesSelectorSheet"]
            CLSheet["ChaptersListSheet"]
            SAViz["SpotifyAudioVisualizer"]
        end
        PlayerScreen --> ModularPlayerWidgets
    end

    subgraph Domain_Core["🧠 Capa de Dominio (Modelos & Reglas de Negocio)"]
        BookItem["BookItem (Estado del libro, progreso, portada)"]
        ChapterItem["ChapterItem (Secciones, texto depurado, notas)"]
        AmbientTrack["AmbientTrackInfo (Binaural & Lofi)"]
        VoiceModel["EdgeVoice / DeviceVoice (Metadatos neuronales)"]
    end

    subgraph Data_Repositories["📦 Capa de Repositorios (Persistencia Híbrida)"]
        LibRepo["LibraryRepository (Caché en RAM + SharedPreferences + Atomic I/O)"]
        TextSanitizer["TextSanitizer (Pipeline de Normalización Tipográfica)"]
    end

    subgraph Infrastructure_Services["⚡ Capa de Servicios de Infraestructura"]
        AudioPlayerSvc["AudioPlayerService (just_audio + AudioService Android)"]
        TTSSynthesisSvc["TtsSynthesisService (Edge-TTS WebSockets + Fallback Local)"]
        PdfExtractor["PdfExtractorService (Syncfusion Engine en Background Isolate)"]
        CloudDownloader["CloudBookDownloaderService (Google Drive / HTTP Stream)"]
        NativeChannel["NativeChannelService (MethodChannel Kotlin/Java)"]
        LofiGen["LofiGeneratorService (Síntesis de ondas acústicas)"]
    end

    UI_Presentation --> Domain_Core
    UI_Presentation --> Data_Repositories
    Data_Repositories --> Infrastructure_Services
    Infrastructure_Services --> Domain_Core
```

---

## 3. Flujo de Datos e Ingesta de Documentos (Pipeline Concurrente)

El procesamiento de documentos pesados (ej. libros de más de 400 páginas) está diseñado para evitar bloqueos del hilo principal (`ANR: Application Not Responding`).

```mermaid
sequenceDiagram
    autonumber
    actor Usuario
    participant UI as LibraryScreen
    participant Worker as Isolate Secundario (Background)
    participant Engine as Syncfusion PDF Layout Engine
    participant Sanitizer as TextSanitizer Pipeline
    participant Repo as LibraryRepository (Storage)

    Usuario->>UI: Carga archivo PDF / EPUB o Link de Drive
    UI->>UI: Despliega modal de progreso con percentil reactivo
    UI->>Worker: Invoca extractChaptersInBackground(bytes)
    Worker->>Engine: extractText(startPageIndex, endPageIndex, layoutText: true)
    Note over Engine: El modo layoutText preserva operadores tipográficos (evita palabras pegadas y glifos duplicados)
    Engine-->>Worker: Texto crudo con layout original
    Worker->>Sanitizer: sanitizeExtractedText(rawText)
    Note over Sanitizer: Filtra encabezados, pies de página, 'yy' de kerning, restaura ligaduras
    Sanitizer-->>Worker: Texto depurado y modularizado en capítulos
    Worker-->>UI: Retorna List<ChapterItem> estructurada
    UI->>Repo: saveBooks() (Serialización atómica diferida)
    Repo-->>UI: Confirmación de almacenamiento (<0.2ms)
    UI->>Usuario: Documento disponible para lectura y escucha inmediata
```

---

## 4. Pipeline de Síntesis y Reproducción Neuronal (Edge-TTS + Background Audio)

Audibuuks implementa un modelo de reproducción híbrido de ultra-baja latencia:

```mermaid
flowchart TD
    Start([Play Solicitado por Usuario]) --> CheckCache{¿Existe audio cacheado<br/>en almacenamiento local?}
    
    CheckCache -- Sí --> PlayLocal[Reproducir archivo WAV/MP3 local instantáneo]
    CheckCache -- No --> ConnEdge[Abrir WebSocket seguro con Edge-TTS Neural Gateway]
    
    ConnEdge --> SSML[Inyectar SSML: Voz, Velocidad, Tono, Expresividad]
    SSML --> StreamChunk[Descarga streaming en chunks binarios]
    StreamChunk --> SaveDisk[Persistir en disco para reproducción offline]
    SaveDisk --> PlayLocal
    
    PlayLocal --> MediaSvc[Android Foreground MediaSession Service]
    MediaSvc --> Notif[Notificación interactiva con carátula y controles]
    MediaSvc --> SleepTimerCheck{¿Sleep Timer Activo?}
    
    SleepTimerCheck -- Fin de tiempo / Fin de capítulo --> FadeOut[Atenuación suave de volumen y detención]
    SleepTimerCheck -- No --> KeepPlaying[Continuar flujo al siguiente fragmento]
```

---

## 5. Estrategia de Persistencia y Rendimiento (Ultra-Optimized I/O)

Para soportar bibliotecas con decenas de libros y miles de notas sin degradar la memoria RAM:

1. **Lectura Lazy & Desacoplada:**
   - La lista de libros (`BookItem`) se carga en memoria con metadatos ligeros (título, autor, porcentaje de lectura, ruta del archivo original).
   - El contenido pesado de cada capítulo (`textContent`) solo se hidrata bajo demanda cuando se ingresa al reproductor o visor.
2. **Fast Progress & Fast Notes:**
   - Cada cambio de segundo o subrayado se almacena en claves dedicadas en `SharedPreferences` (`audiomind_prog_<id>` y `audiomind_notes_<id>`) ejecutándose en `< 0.2 milisegundos`.
   - Se evita la re-escritura masiva de cadenas JSON de varios megabytes en cada segundo de reproducción.

---

## 6. Escalabilidad y Futura Expansión

| Módulo Actual | Capacidad de Escalabilidad Técnica |
| :--- | :--- |
| **Edge-TTS / Fallback Local** | Permite conectar proveedores cloud alternativos (OpenAI TTS, ElevenLabs, Google Cloud Text-to-Speech) simplemente implementando una interfaz común `TtsBackend`. |
| **Persistencia Local** | Arquitectura lista para migración a base de datos embebida (`Isar` o `ObjectBox`) para consultas vectoriales y búsqueda semántica de fragmentos. |
| **Multiplataforma** | Base de código compatible con iOS (`AVAudioSession`), macOS y Web con mínimas adaptaciones en los canales nativos. |

---

## 7. Métricas de Calidad de Código
- **Análisis Estático (Dart Analyzer):** 0 errores, 0 advertencias, 0 lints (`No issues found!`).
- **FPS en Animaciones (Splash & Visualizers):** 60 FPS estables gracias a `CustomPainter` directo sobre el canvas de hardware.
- **Consumo de Memoria en Background:** < 45 MB de RAM en estado de reproducción con pantalla apagada.
