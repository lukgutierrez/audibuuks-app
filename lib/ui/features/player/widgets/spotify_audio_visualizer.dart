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

    return SizedBox(
      height: 28,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_baseHeights.length, (i) {
          final double wave = isPlaying
              ? (0.45 + 0.55 * sin((phase * 2 * pi) + (i * 0.55)).abs())
              : 0.22;
          final double barH = (26.0 * _baseHeights[i] * wave).clamp(4.0, 26.0);
          final bool isCenter = (i - 10).abs() <= 4;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            margin: const EdgeInsets.symmetric(horizontal: 2.2),
            width: 3.4,
            height: barH,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: isPlaying
                    ? [
                        isCenter
                            ? const Color(0xFFF5A623)
                            : const Color(0xFFF5A623).withValues(alpha: 0.55),
                        Colors.white.withValues(alpha: isCenter ? 0.92 : 0.45),
                      ]
                    : [
                        Colors.white24,
                        Colors.white12,
                      ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
