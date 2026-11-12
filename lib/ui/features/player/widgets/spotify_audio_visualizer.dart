import 'dart:math';
import 'package:flutter/material.dart';

class SpotifyAudioVisualizer extends StatelessWidget {
  final bool isPlaying;
  final Duration position;

  const SpotifyAudioVisualizer({
    super.key,
    required this.isPlaying,
    required this.position,
  });

  static const List<double> _baseHeights = [
    0.22, 0.35, 0.50, 0.30, 0.68, 0.85, 0.52, 0.92, 0.64, 1.0,
    0.75, 1.0, 0.64, 0.92, 0.52, 0.85, 0.68, 0.30, 0.50, 0.35, 0.22
  ];

  @override
  Widget build(BuildContext context) {
    final double phase = (position.inMilliseconds % 1200) / 1200.0;

    return RepaintBoundary(
      child: SizedBox(
        height: 28,
        width: 170,
        child: CustomPaint(
          painter: _VisualizerBarsPainter(
            isPlaying: isPlaying,
            phase: phase,
          ),
        ),
      ),
    );
  }
}

class _VisualizerBarsPainter extends CustomPainter {
  final bool isPlaying;
  final double phase;

  const _VisualizerBarsPainter({
    required this.isPlaying,
    required this.phase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const int n = 21;
    const double barW = 3.4;
    const double gap = 4.4;
    final double totalW = n * barW + (n - 1) * gap;
    final double startX = (size.width - totalW) / 2.0;

    final Paint centerPaint = Paint()
      ..color = isPlaying ? const Color(0xFFF5A623) : Colors.white24
      ..style = PaintingStyle.fill;

    final Paint outerPaint = Paint()
      ..color = isPlaying
          ? const Color(0xFFF5A623).withValues(alpha: 0.60)
          : Colors.white12
      ..style = PaintingStyle.fill;

    for (int i = 0; i < n; i++) {
      final double base = SpotifyAudioVisualizer._baseHeights[i];
      final double wave = isPlaying
          ? (0.45 + 0.55 * sin((phase * 2 * pi) + (i * 0.55)).abs())
          : 0.22;
      final double barH = (26.0 * base * wave).clamp(4.0, 26.0);
      final double x = startX + i * (barW + gap);
      final double y = (size.height - barH) / 2.0;
      final bool isCenter = (i - 10).abs() <= 4;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barW, barH),
          const Radius.circular(2.0),
        ),
        isCenter ? centerPaint : outerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VisualizerBarsPainter oldDelegate) {
    if (!isPlaying && !oldDelegate.isPlaying) return false;
    return oldDelegate.isPlaying != isPlaying ||
        (oldDelegate.phase - phase).abs() > 0.04;
  }
}
