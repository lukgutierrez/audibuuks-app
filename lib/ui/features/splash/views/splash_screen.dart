import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../library/views/library_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _waveController;

  late final Animation<double> _booksSlide;
  late final Animation<double> _booksOpacity;
  late final Animation<double> _booksScale;

  late final Animation<double> _titleSlide;
  late final Animation<double> _titleOpacity;
  late final Animation<double> _titleScale;

  late final Animation<double> _eqOpacity;
  late final Animation<double> _footerOpacity;
  late final Animation<double> _footerSlide;

  Timer? _navTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFFE08E12),
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1650),
    );

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    _booksSlide = Tween<double>(begin: -38.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.58, curve: Curves.easeOutBack),
      ),
    );
    _booksOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.42, curve: Curves.easeOut),
      ),
    );
    _booksScale = Tween<double>(begin: 0.78, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.58, curve: Curves.easeOutBack),
      ),
    );

    _titleSlide = Tween<double>(begin: 34.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.14, 0.72, curve: Curves.easeOutCubic),
      ),
    );
    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.14, 0.56, curve: Curves.easeOut),
      ),
    );
    _titleScale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.14, 0.72, curve: Curves.easeOutBack),
      ),
    );

    _eqOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.32, 0.80, curve: Curves.easeOut),
      ),
    );

    _footerOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.48, 1.0, curve: Curves.easeOut),
      ),
    );
    _footerSlide = Tween<double>(begin: 22.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.48, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    _entranceController.forward();

    _navTimer = Timer(const Duration(milliseconds: 3300), _goToLibrary);
  }

  void _goToLibrary() {
    if (!mounted) return;
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF0F1014),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 650),
        pageBuilder: (_, animation, _) => const LibraryScreen(),
        transitionsBuilder: (_, animation, _, child) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeInOutCubic,
            ),
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    _entranceController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5A623),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.2, -0.25),
            radius: 1.25,
            colors: [
              Color(0xFFFFBD3E),
              Color(0xFFF5A623),
              Color(0xFFE08E12),
            ],
            stops: [0.0, 0.58, 1.0],
          ),
        ),
        child: SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge([_entranceController, _waveController]),
            builder: (context, _) {
              final floatOffset =
                  sin(_waveController.value * 2 * pi) * 4.0;

              return Stack(
                alignment: Alignment.center,
                children: [
                  // Sutil halo luminoso central detrás del logo
                  Positioned(
                    child: Container(
                      width: 320,
                      height: 320,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0.16),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Composición central (Libros apilados + AUDI BUUKS + Ecualizador digital en vivo)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // 1. Pila de 3 libros negros y ámbar
                            Expanded(
                              flex: 32,
                              child: Opacity(
                                opacity: _booksOpacity.value,
                                child: Transform.translate(
                                  offset: Offset(
                                    _booksSlide.value,
                                    floatOffset,
                                  ),
                                  child: Transform.scale(
                                    scale: _booksScale.value,
                                    child: Image.asset(
                                      'assets/branding/splash_books.png',
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // 2. Tipografía brush blanca "AUDI BUUKS"
                            Expanded(
                              flex: 68,
                              child: Opacity(
                                opacity: _titleOpacity.value,
                                child: Transform.translate(
                                  offset: Offset(
                                    _titleSlide.value,
                                    -floatOffset * 0.6,
                                  ),
                                  child: Transform.scale(
                                    scale: _titleScale.value,
                                    child: Image.asset(
                                      'assets/branding/splash_title.png',
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        // 3. Ecualizador digital negro animado en tiempo real (fiel al modelo)
                        Opacity(
                          opacity: _eqOpacity.value,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 36, right: 6),
                            child: SizedBox(
                              width: double.infinity,
                              height: 58,
                              child: CustomPaint(
                                painter: _AudibuuksEqualizerPainter(
                                  phase: _waveController.value * 2 * pi,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Footer profesional: Created by Lukgtz (Luciano Gutierrez) + Version 1.0.0
                  Positioned(
                    bottom: 26,
                    left: 24,
                    right: 24,
                    child: Opacity(
                      opacity: _footerOpacity.value,
                      child: Transform.translate(
                        offset: Offset(0, _footerSlide.value),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF121212)
                                    .withValues(alpha: 0.90),
                                borderRadius: BorderRadius.circular(30),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.22),
                                    blurRadius: 14,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFF5A623),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  Flexible(
                                    child: Text(
                                      'CREATED BY LUKGTZ (LUCIANO GUTIERREZ)',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.plusJakartaSans(
                                        color: Colors.white,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.15,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'VERSION 1.0.0',
                              style: GoogleFonts.jetBrainsMono(
                                color: const Color(0xFF141414)
                                    .withValues(alpha: 0.82),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Pinta las columnas de bloques LED negros del ecualizador del modelo de Audibuuks
/// animadas a 60 FPS como un espectro de audio real.
class _AudibuuksEqualizerPainter extends CustomPainter {
  final double phase;

  // Perfil base idéntico al modelo del usuario (29 columnas con sus pausas)
  static const List<int> _baseHeights = [
    1, 6, 4, 3, 1, 0, // bloque 1
    4, 6, 8, 10, 6, 1, // bloque 2
    8, 5, 10, 8, 4, 4, 5, 1, 6, 1, 0, // bloque 3
    4, 7, 4, 1, 6, 8, 10, 10, 6, 4, // bloque 4
  ];

  const _AudibuuksEqualizerPainter({required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0E0E0E)
      ..style = PaintingStyle.fill;

    final int count = _baseHeights.length;
    const double maxSegments = 10;
    final double gapX = 3.2;
    final double barWidth =
        max(3.5, (size.width - (count - 1) * gapX) / count);
    const double gapY = 2.2;
    final double segHeight =
        max(2.2, (size.height - (maxSegments - 1) * gapY) / maxSegments);

    for (int i = 0; i < count; i++) {
      final int base = _baseHeights[i];
      if (base == 0) continue; // Espacio separador entre grupos del ecualizador

      final double wave1 = sin(phase * 2.0 + i * 0.55);
      final double wave2 = cos(phase * 3.0 - i * 0.85) * 0.5;
      final double combined = (wave1 + wave2) / 1.5; // [-1..1]

      int activeSegments;
      if (base == 1) {
        activeSegments = combined > 0.35 ? 2 : 1;
      } else {
        final int delta = (combined * 3.2).round();
        activeSegments = (base + delta).clamp(2, 10);
      }

      final double x = i * (barWidth + gapX);
      for (int s = 0; s < activeSegments; s++) {
        final double y = size.height - (s + 1) * segHeight - s * gapY;
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, segHeight),
          const Radius.circular(1.0),
        );
        canvas.drawRRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AudibuuksEqualizerPainter oldDelegate) {
    return oldDelegate.phase != phase;
  }
}
