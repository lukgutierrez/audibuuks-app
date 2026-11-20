(() => {
  const REPO_OWNER = "lukgutierrez";
  const REPO_NAME = "audibuuks-app";
  const LATEST_RELEASE_API = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest`;
  const FALLBACK_RELEASES_URL = `https://github.com/${REPO_OWNER}/${REPO_NAME}/releases`;

  // 1. Voces naturales de Audibuuks explicadas de forma clara para cualquier lector
  const VOICES = [
    { name: "Jorge", flag: "🇲🇽", region: "México", style: "Voz masculina cálida, ideal para novelas y estudio", lang: "es", badge: "Favorita" },
    { name: "Tomás", flag: "🇦🇷", region: "Argentina", style: "Acento argentino natural y muy fluido", lang: "es", badge: "Natural" },
    { name: "Elena", flag: "🇦🇷", region: "Argentina", style: "Voz femenina suave, perfecta para relajarse", lang: "es", badge: "Suave" },
    { name: "Tristán", flag: "🎙️", region: "Español Ultra HD", style: "Narración expresiva con entonación realista", lang: "es", badge: "Ultra HD" },
    { name: "Ximena", flag: "🎙️", region: "Español Ultra HD", style: "Voz femenina expresiva y super clara", lang: "es", badge: "Ultra HD" },
    { name: "Gonzalo", flag: "🇨🇴", region: "Colombia", style: "Tono narrador claro y agradable", lang: "es", badge: "Narrador" },
    { name: "Álvaro", flag: "🇪🇸", region: "España", style: "Voz profunda y pausada para lecturas largas", lang: "es", badge: "Profunda" },
    { name: "Dalia", flag: "🇲🇽", region: "México", style: "Voz femenina nítida y fácil de seguir", lang: "es", badge: "Clara" },
    { name: "Guy", flag: "🇺🇸", region: "Estados Unidos", style: "Voz cálida para libros y textos en inglés", lang: "en", badge: "English" },
    { name: "Aria", flag: "🇺🇸", region: "Estados Unidos", style: "Voz femenina expresiva y natural", lang: "en", badge: "English" },
    { name: "Christopher", flag: "🇺🇸", region: "Estados Unidos", style: "Narrador profundo estilo documental", lang: "en", badge: "English" },
    { name: "Ryan", flag: "🇬🇧", region: "Reino Unido", style: "Elegante acento británico clásico", lang: "en", badge: "British" },
    { name: "Sonia", flag: "🇬🇧", region: "Reino Unido", style: "Voz británica suave y prolija", lang: "en", badge: "British" },
  ];

  // 2. Recorrido real por la app (100% enfocado en la experiencia de usuario)
  const WALKTHROUGH_ITEMS = [
    {
      img: "screenshots/player.png",
      alt: "Reproductor de Audibuuks leyendo y subrayando palabra por palabra",
      caption:
        "Mientras escuchás, Audibuuks te muestra el texto y resalta cada palabra en vivo. Podés cambiar la velocidad, elegir tu voz favorita, agregar música suave de piano o anotar ideas sin salir del libro.",
      wide: false,
    },
    {
      img: "screenshots/home.png",
      alt: "Biblioteca personal de Audibuuks con portadas y progreso",
      caption:
        "Todos tus PDF y EPUB organizados en un solo lugar, con portadas, porcentaje leído, filtros rápidos (Continuar, Terminados, Favoritos), carga directa desde Google Drive y aviso automático de actualizaciones.",
      wide: false,
    },
    {
      img: "screenshots/splash.png",
      alt: "Pantalla de inicio de Audibuuks diseñada por Lukgtz",
      caption:
        "Una experiencia cuidada desde el primer segundo: modo oscuro elegante para no cansar la vista y controles simples pensados para usar con una sola mano.",
      wide: false,
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
          <span class="voice-lang ${v.lang}">${v.lang === "en" ? "INGLÉS" : "ESPAÑOL"}</span>
        </div>
        <div class="voice-desc">${v.style}</div>
        <div class="voice-id">${v.region} · ${v.badge}</div>
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

  // ===== DESCARGA AUTOMÁTICA DE LA ÚLTIMA VERSIÓN PUBLICADA =====
  const badgeText = document.getElementById("live-release-badge");
  const downloadBtn = document.getElementById("download-apk-btn");
  const navDownloadBtn = document.getElementById("nav-download-btn");
  const metaVersion = document.getElementById("meta-version");
  const metaSize = document.getElementById("meta-size");
  const abiContainer = document.getElementById("abi-selector");

  function formatMb(bytes) {
    if (!bytes || bytes <= 0) return "~22 MB";
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  function friendlyArchLabel(fileName) {
    const lower = (fileName || "").toLowerCase();
    if (lower.includes("arm64")) return "Celulares modernos (Recomendado)";
    if (lower.includes("armeabi")) return "Celulares antiguos (32-bit)";
    return "Versión Universal";
  }

  function applySelectedApk(asset, tag) {
    if (!asset) return;
    if (downloadBtn) {
      downloadBtn.href = asset.browser_download_url;
      downloadBtn.innerHTML = `<span>⬇</span> Descargar Audibuuks ${tag}`;
    }
    if (navDownloadBtn) {
      navDownloadBtn.href = asset.browser_download_url;
    }
    if (metaSize) metaSize.textContent = formatMb(asset.size);
  }

  async function loadLatestRelease() {
    try {
      const res = await fetch(LATEST_RELEASE_API, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!res.ok) throw new Error("No release yet");
      const release = await res.json();

      const tag = release.tag_name || "v1.1.0";
      const apks = (release.assets || []).filter((a) =>
        (a.name || "").toLowerCase().endsWith(".apk")
      );

      if (badgeText) {
        badgeText.textContent = `Versión ${tag} disponible · Gratis para Android · Por Lukgtz`;
      }
      if (metaVersion) metaVersion.textContent = tag;

      if (apks.length > 0) {
        const preferred =
          apks.find((a) => a.name.toLowerCase().includes("arm64")) || apks[0];
        applySelectedApk(preferred, tag);

        if (abiContainer && apks.length > 1) {
          abiContainer.innerHTML = apks
            .map(
              (a, idx) => `
              <button type="button" class="abi-chip ${a === preferred ? "active" : ""}" data-apk-idx="${idx}">
                ${friendlyArchLabel(a.name)} · ${formatMb(a.size)}
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
      if (downloadBtn) downloadBtn.href = FALLBACK_RELEASES_URL;
      if (navDownloadBtn) navDownloadBtn.href = FALLBACK_RELEASES_URL;
    }
  }

  loadLatestRelease();
})();
