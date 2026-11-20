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

  // 2. Recorrido con TODAS las capturas reales subidas
  const WALKTHROUGH_ITEMS = [
    {
      img: "screenshots/player_portada.jpg",
      alt: "Reproductor con portada real del libro y colores ambientales",
      caption:
        "Modo Portada: muestra la tapa de tu libro con un fondo ambiental que toma los colores de la portada, barra de progreso del capítulo, temporizador de sueño (zZz), velocidad y cambio rápido de voz.",
    },
    {
      img: "screenshots/karaoke_texto.jpg",
      alt: "Lectura karaoke resaltando palabra por palabra en vivo",
      caption:
        "Modo Texto en Vivo: seguí la lectura con el párrafo destacado y cada palabra resaltada en el momento exacto en que suena la voz. Tocá cualquier frase para empezar a escuchar desde ahí.",
    },
    {
      img: "screenshots/capitulos_notas.jpg",
      alt: "Lista de 40 capítulos con descarga sin internet y notas por sección",
      caption:
        "Capítulos y Notas de Estudio: descargá capítulos individuales o el libro entero para escuchar sin internet, y guardá tus propias notas e ideas en cada sección del libro.",
    },
    {
      img: "screenshots/home.png",
      alt: "Biblioteca personal con filtros, portadas y carga desde Google Drive",
      caption:
        "Tu Biblioteca: organizá tus PDF y EPUB en Continuar, Terminados o Favoritos, cargá libros directo desde tu celular o Google Drive, y recibí avisos automáticos cuando haya una nueva versión.",
    },
    {
      img: "screenshots/splash.png",
      alt: "Pantalla de bienvenida de Audibuuks creada por Lukgtz",
      caption:
        "Identidad visual propia en tonos oscuros y ámbar, pensada para disfrutar tus lecturas de día o de noche sin cansar la vista.",
    },
  ];

  // ===== BARRA DE PROGRESO AL SCROLLEAR =====
  const scrollBar = document.getElementById("scroll-progress");
  if (scrollBar) {
    window.addEventListener(
      "scroll",
      () => {
        const doc = document.documentElement;
        const max = doc.scrollHeight - doc.clientHeight;
        const pct = max > 0 ? (doc.scrollTop / max) * 100 : 0;
        scrollBar.style.width = `${Math.min(100, Math.max(0, pct))}%`;
      },
      { passive: true }
    );
  }

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

  // ===== WALKTHROUGH INTERACTIVO + AUTO-ROTACIÓN SUAVE =====
  const wtTabs = document.querySelectorAll(".wt-tab");
  const galleryCards = document.querySelectorAll(".screen-card");
  const wtImg = document.getElementById("walkthrough-img");
  const wtCaption = document.getElementById("walkthrough-caption");
  const wtContainer = document.querySelector(".walkthrough-layout");

  let activeWtIndex = 0;
  let wtTimer = null;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function selectWalkthrough(idx, fromUser = false) {
    const item = WALKTHROUGH_ITEMS[idx];
    if (!item || !wtImg || !wtCaption) return;
    activeWtIndex = idx;

    wtTabs.forEach((t, i) => {
      const isMatch = i === idx;
      t.classList.remove("active");
      void t.offsetWidth; // reinicia animación de barra de progreso
      if (isMatch) {
        t.classList.add("active");
      }
      t.setAttribute("aria-selected", String(isMatch));
    });

    galleryCards.forEach((c) => {
      const cardIdx = Number(c.dataset.wtTarget || -1);
      c.classList.toggle("active", cardIdx === idx);
    });

    wtImg.style.opacity = "0";
    wtImg.style.transform = "scale(0.97)";
    setTimeout(() => {
      wtImg.src = item.img;
      wtImg.alt = item.alt;
      wtCaption.textContent = item.caption;
      wtImg.style.opacity = "1";
      wtImg.style.transform = "scale(1)";
    }, 150);

    if (fromUser) {
      restartWalkthroughTimer();
    }
  }

  function restartWalkthroughTimer() {
    if (wtTimer) clearInterval(wtTimer);
    if (reducedMotion) return;
    wtTimer = setInterval(() => {
      const next = (activeWtIndex + 1) % WALKTHROUGH_ITEMS.length;
      selectWalkthrough(next, false);
    }, 5500);
  }

  wtTabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      selectWalkthrough(Number(tab.dataset.wtIndex || 0), true);
    });
  });

  galleryCards.forEach((card) => {
    card.addEventListener("click", () => {
      const targetIdx = Number(card.dataset.wtTarget || 0);
      selectWalkthrough(targetIdx, true);
      wtContainer?.scrollIntoView({ behavior: "smooth", block: "center" });
    });
  });

  if (wtContainer && !reducedMotion) {
    wtContainer.addEventListener("mouseenter", () => {
      if (wtTimer) clearInterval(wtTimer);
      wtTabs.forEach((t) => t.classList.add("paused"));
    });
    wtContainer.addEventListener("mouseleave", () => {
      wtTabs.forEach((t) => t.classList.remove("paused"));
      restartWalkthroughTimer();
    });
    restartWalkthroughTimer();
  }

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

  // ===== SCROLL REVEAL CON RETRASO ESCALONADO =====
  const revealNodes = document.querySelectorAll(".reveal, .bench-card");
  revealNodes.forEach((node) => {
    const delay = node.dataset.delay;
    if (delay) {
      node.style.transitionDelay = `${delay}ms`;
    }
  });

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
      { threshold: 0.12 }
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
    if (!bytes || bytes <= 0) return "~22.5 MB";
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

      const tag = release.tag_name || "v1.1.1";
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
