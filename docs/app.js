(() => {
  const REPO_OWNER = "lukgutierrez";
  const REPO_NAME = "audibuuks-app";
  const LATEST_RELEASE_API = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest`;
  const FALLBACK_RELEASES_URL = `https://github.com/${REPO_OWNER}/${REPO_NAME}/releases`;

  // 1. Voces neuronales reales de Audibuuks (sincronizadas con TtsSynthesisService.voicesMap)
  const VOICES = [
    { id: "es-MX-JorgeNeural", name: "Jorge HD", flag: "🇲🇽", region: "México", style: "Cálido y narrativo", lang: "es" },
    { id: "es-AR-TomasNeural", name: "Tomás HD", flag: "🇦🇷", region: "Argentina", style: "Natural y fluido", lang: "es" },
    { id: "es-AR-ElenaNeural", name: "Elena HD", flag: "🇦🇷", region: "Argentina", style: "Suave y clara", lang: "es" },
    { id: "es-ES-TristanMultilingualNeural", name: "Tristán DragonHD", flag: "🎙️", region: "Multilingüe", style: "Expresivo DragonHD", lang: "es" },
    { id: "es-ES-XimenaMultilingualNeural", name: "Ximena DragonHD", flag: "🎙️", region: "Multilingüe", style: "Femenina DragonHD", lang: "es" },
    { id: "es-CO-GonzaloNeural", name: "Gonzalo HD", flag: "🇨🇴", region: "Colombia", style: "Tono narrador", lang: "es" },
    { id: "es-ES-AlvaroNeural", name: "Álvaro HD", flag: "🇪🇸", region: "España", style: "Profundo y pausado", lang: "es" },
    { id: "es-MX-DaliaNeural", name: "Dalia HD", flag: "🇲🇽", region: "México", style: "Clara y articulada", lang: "es" },
    { id: "en-US-GuyNeural", name: "Guy HD", flag: "🇺🇸", region: "EE. UU.", style: "Warm & narrative", lang: "en" },
    { id: "en-US-AriaNeural", name: "Aria HD", flag: "🇺🇸", region: "EE. UU.", style: "Clear & expressive", lang: "en" },
    { id: "en-US-ChristopherNeural", name: "Christopher HD", flag: "🇺🇸", region: "EE. UU.", style: "Deep narrator", lang: "en" },
    { id: "en-GB-RyanNeural", name: "Ryan HD", flag: "🇬🇧", region: "Reino Unido", style: "British classic", lang: "en" },
    { id: "en-GB-SoniaNeural", name: "Sonia HD", flag: "🇬🇧", region: "Reino Unido", style: "Soft & crisp", lang: "en" },
  ];

  // 2. Recorrido real en dispositivo (capturas reales del repo)
  const WALKTHROUGH_ITEMS = [
    {
      img: "screenshots/player.png",
      alt: "Reproductor y visor karaoke en vivo de Audibuuks",
      caption:
        "Reproductor minimalista con seguimiento palabra por palabra en tiempo real, barra de pre-buffer estilo YouTube, velocidad 0.7x–2.0x, notas por sección, música clásica de fondo y cambio instantáneo al PDF original.",
      wide: false,
    },
    {
      img: "screenshots/home.png",
      alt: "Biblioteca principal de Audibuuks",
      caption:
        "Biblioteca inteligente con filtros rápidos (Todos, Continuar, Terminados, Favoritos), progreso exacto por libro, mini-reproductor persistente, importación directa desde Google Drive y botón de actualizaciones automáticas in-app.",
      wide: false,
    },
    {
      img: "screenshots/splash.png",
      alt: "Pantalla de bienvenida animada de Audibuuks a 60 FPS",
      caption:
        "Identidad visual Dark Slate & Ámbar con pantalla de inicio animada a 60 FPS, ecualizador LED digital en vivo y arranque instantáneo sin bloqueos.",
      wide: false,
    },
    {
      img: "screenshots/arquitectura.png",
      alt: "Infografía de arquitectura Clean de Audibuuks",
      caption:
        "Arquitectura modular Clean Architecture: extracción PDF en Background Isolates, pool de descargas offline 5x con WakeLock nativo, MediaSession de Android y FileProvider aislado para actualizaciones OTA.",
      wide: true,
    },
  ];

  // ===== RENDER DE VOCES CON FILTRO =====
  const voicesGrid = document.getElementById("voices-grid");
  const voiceFilterBtns = document.querySelectorAll("[data-voice-filter]");

  function renderVoices(filter = "all") {
    if (!voicesGrid) return;
    const list = filter === "all" ? VOICES : VOICES.filter((v) => v.lang === filter);
    voicesGrid.innerHTML = list
      .map(
        (v) => `
      <article class="voice-card">
        <div class="voice-head">
          <span class="voice-name">${v.flag} ${v.name}</span>
          <span class="voice-lang ${v.lang}">${v.lang === "en" ? "ENGLISH" : "ESPAÑOL"}</span>
        </div>
        <div class="voice-desc">${v.region} · ${v.style}</div>
        <div class="voice-id">${v.id}</div>
      </article>`
      )
      .join("");
  }

  voiceFilterBtns.forEach((btn) => {
    btn.addEventListener("click", () => {
      voiceFilterBtns.forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      renderVoices(btn.dataset.voiceFilter || "all");
    });
  });
  renderVoices("all");

  // ===== WALKTHROUGH INTERACTIVO =====
  const wtTabs = document.querySelectorAll(".wt-tab");
  const wtImg = document.getElementById("walkthrough-img");
  const wtCaption = document.getElementById("walkthrough-caption");

  wtTabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      const idx = Number(tab.dataset.wtIndex || 0);
      const item = WALKTHROUGH_ITEMS[idx];
      if (!item || !wtImg || !wtCaption) return;

      wtTabs.forEach((t) => {
        t.classList.remove("active");
        t.setAttribute("aria-selected", "false");
      });
      tab.classList.add("active");
      tab.setAttribute("aria-selected", "true");

      wtImg.style.opacity = "0";
      wtImg.style.transform = "scale(0.98)";
      setTimeout(() => {
        wtImg.src = item.img;
        wtImg.alt = item.alt;
        wtImg.classList.toggle("is-wide", Boolean(item.wide));
        wtCaption.textContent = item.caption;
        wtImg.style.opacity = "1";
        wtImg.style.transform = "scale(1)";
      }, 150);
    });
  });

  // ===== EQUALIZER LED ANIMADO (FIEL AL SPLASH DE AUDIBUUKS) =====
  const eqCanvas = document.getElementById("hero-eq-canvas");
  if (eqCanvas && eqCanvas.getContext) {
    const ctx = eqCanvas.getContext("2d");
    const baseHeights = [
      1, 5, 4, 3, 2, 0,
      4, 6, 8, 9, 6, 2,
      7, 5, 9, 8, 4, 5, 2, 0,
      4, 7, 5, 2, 6, 8, 9, 7, 4,
    ];
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let phase = 0;

    function drawEq() {
      const w = eqCanvas.width;
      const h = eqCanvas.height;
      ctx.clearRect(0, 0, w, h);

      const count = baseHeights.length;
      const maxSegs = 8;
      const gapX = 2.5;
      const barW = Math.max(3, (w - (count - 1) * gapX) / count);
      const gapY = 2;
      const segH = Math.max(2, (h - (maxSegs - 1) * gapY) / maxSegs);

      for (let i = 0; i < count; i++) {
        const base = baseHeights[i];
        if (base === 0) continue;
        const wave = (Math.sin(phase * 2.1 + i * 0.55) + Math.cos(phase * 2.9 - i * 0.8) * 0.5) / 1.5;
        const active = Math.max(1, Math.min(maxSegs, Math.round(base * 0.82 + wave * 2.3)));
        const x = i * (barW + gapX);

        for (let s = 0; s < active; s++) {
          const y = h - (s + 1) * segH - s * gapY;
          ctx.fillStyle = s >= maxSegs - 2 ? "#ffc85c" : "#f5a623";
          ctx.fillRect(x, y, barW, segH);
        }
      }

      if (!reducedMotion) {
        phase += 0.035;
        requestAnimationFrame(drawEq);
      }
    }
    drawEq();
  }

  // ===== SCROLL REVEAL =====
  const revealNodes = document.querySelectorAll(".reveal, .bench-card");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("visible");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.14 }
    );
    revealNodes.forEach((el) => io.observe(el));
  } else {
    revealNodes.forEach((el) => el.classList.add("visible"));
  }

  // ===== FETCH EN VIVO DEL ÚLTIMO RELEASE DE GITHUB =====
  const badgeText = document.getElementById("live-release-badge");
  const downloadBtn = document.getElementById("download-apk-btn");
  const navDownloadBtn = document.getElementById("nav-download-btn");
  const metaVersion = document.getElementById("meta-version");
  const metaSize = document.getElementById("meta-size");
  const metaArch = document.getElementById("meta-arch");
  const abiContainer = document.getElementById("abi-selector");
  const changelogTitle = document.getElementById("changelog-title");
  const changelogBody = document.getElementById("changelog-body");

  function formatMb(bytes) {
    if (!bytes || bytes <= 0) return "~21 MB";
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  function detectArchLabel(fileName) {
    const lower = (fileName || "").toLowerCase();
    if (lower.includes("arm64")) return "ARM64 (Recomendado)";
    if (lower.includes("armeabi")) return "ARMv7 (32-bit)";
    if (lower.includes("x86_64")) return "x86_64";
    return "Universal APK";
  }

  function applySelectedApk(asset, tag) {
    if (!asset) return;
    if (downloadBtn) {
      downloadBtn.href = asset.browser_download_url;
      downloadBtn.innerHTML = `<span>⬇</span> Descargar APK ${tag}`;
    }
    if (navDownloadBtn) {
      navDownloadBtn.href = asset.browser_download_url;
    }
    if (metaSize) metaSize.textContent = formatMb(asset.size);
    if (metaArch) metaArch.textContent = detectArchLabel(asset.name);
  }

  async function loadLatestRelease() {
    try {
      const res = await fetch(LATEST_RELEASE_API, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!res.ok) throw new Error("No release yet");
      const release = await res.json();

      const tag = release.tag_name || "v1.0.0";
      const apks = (release.assets || []).filter((a) =>
        (a.name || "").toLowerCase().endsWith(".apk")
      );

      if (badgeText) {
        badgeText.textContent = `Último Release (${tag}) · Android 7.0+ ARM64 · Auto-Updates OTA`;
      }
      if (metaVersion) metaVersion.textContent = tag;
      if (changelogTitle) {
        changelogTitle.textContent = release.name || `Audibuuks ${tag}`;
      }
      if (changelogBody && release.body) {
        changelogBody.textContent = release.body.trim();
      }

      if (apks.length > 0) {
        const preferred =
          apks.find((a) => a.name.toLowerCase().includes("arm64")) || apks[0];
        applySelectedApk(preferred, tag);

        if (abiContainer && apks.length > 1) {
          abiContainer.innerHTML = apks
            .map(
              (a, idx) => `
              <button type="button" class="abi-chip ${a === preferred ? "active" : ""}" data-apk-idx="${idx}">
                ${detectArchLabel(a.name)} · ${formatMb(a.size)}
              </button>`
            )
            .join("");

          abiContainer.querySelectorAll(".abi-chip").forEach((chip) => {
            chip.addEventListener("click", () => {
              abiContainer.querySelectorAll(".abi-chip").forEach((c) => c.classList.remove("active"));
              chip.classList.add("active");
              const chosen = apks[Number(chip.dataset.apkIdx)];
              applySelectedApk(chosen, tag);
            });
          });
        }
      } else if (downloadBtn) {
        downloadBtn.href = release.html_url || FALLBACK_RELEASES_URL;
      }
    } catch (_) {
      // Fallback limpio si GitHub API tiene rate-limit o no hay conexión
      if (downloadBtn) downloadBtn.href = FALLBACK_RELEASES_URL;
      if (navDownloadBtn) navDownloadBtn.href = FALLBACK_RELEASES_URL;
    }
  }

  loadLatestRelease();
})();
