import 'package:flutter/material.dart';
import '../../../../data/services/audio_player_service.dart';
import '../../../../domain/models/chapter_item.dart';

class SleepTimerSheet extends StatelessWidget {
  final ChapterItem currentChapter;

  const SleepTimerSheet({
    super.key,
    required this.currentChapter,
  });

  static const List<Map<String, dynamic>> _timePresets = [
    {'mins': 5, 'label': '5 min', 'desc': 'Breve'},
    {'mins': 15, 'label': '15 min', 'desc': 'Siesta'},
    {'mins': 30, 'label': '30 min', 'desc': 'Ideal'},
    {'mins': 45, 'label': '45 min', 'desc': 'Relajado'},
    {'mins': 60, 'label': '60 min', 'desc': '1 hora'},
    {'mins': 90, 'label': '90 min', 'desc': '1h 30m'},
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: audioPlayerService,
      builder: (ctx, _) {
        final bool isActive = audioPlayerService.isSleepTimerActive;
        final bool isEndChap = audioPlayerService.sleepAtEndOfChapter;
        final int? remSec = audioPlayerService.sleepRemainingSeconds;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.bedtime_rounded, color: Color(0xFFF5A623), size: 24),
                        SizedBox(width: 10),
                        Text(
                          'Temporizador de Sueño',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: isActive
                            ? const Color(0xFFF5A623).withValues(alpha: 0.18)
                            : Colors.white10,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isActive ? const Color(0xFFF5A623) : Colors.white24,
                        ),
                      ),
                      child: Text(
                        isActive ? '🌙 ${audioPlayerService.sleepTimerBadgeText}' : 'Apagado',
                        style: TextStyle(
                          color: isActive ? const Color(0xFFF5A623) : Colors.white60,
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Atenúa suavemente la voz y el piano en los últimos 10 segundos antes de pausar y guardar tu posición.',
                  style: TextStyle(color: Colors.white54, fontSize: 12.5, height: 1.35),
                ),
                const SizedBox(height: 16),
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    if (isEndChap) {
                      audioPlayerService.cancelSleepTimer();
                    } else {
                      audioPlayerService.startSleepAtEndOfChapter();
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: isEndChap
                          ? const Color(0xFFF5A623).withValues(alpha: 0.18)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isEndChap ? const Color(0xFFF5A623) : Colors.white12,
                        width: isEndChap ? 1.5 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 19,
                          backgroundColor: isEndChap
                              ? const Color(0xFFF5A623)
                              : Colors.white10,
                          child: Icon(
                            Icons.auto_stories_rounded,
                            size: 20,
                            color: isEndChap ? Colors.black : const Color(0xFFF5A623),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Al terminar este capítulo',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                  color: isEndChap ? const Color(0xFFF5A623) : Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Detiene la lectura justo al concluir "${currentChapter.title}"',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white60, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          isEndChap
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: isEndChap ? const Color(0xFFF5A623) : Colors.white38,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.1,
                  children: _timePresets.map((p) {
                    final int mins = p['mins'] as int;
                    final bool selected = !isEndChap &&
                        remSec != null &&
                        (remSec - (mins * 60)).abs() <= 45;
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        audioPlayerService.startSleepTimerMinutes(mins);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFF5A623)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected ? const Color(0xFFF5A623) : Colors.white12,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              p['label'] as String,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: selected ? Colors.black : Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              p['desc'] as String,
                              style: TextStyle(
                                fontSize: 11,
                                color: selected ? Colors.black87 : Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                if (isActive) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFF5A623),
                            side: const BorderSide(color: Color(0xFFF5A623)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () => audioPlayerService.addSleepTimerMinutes(5),
                          icon: const Icon(Icons.add_alarm_rounded, size: 18),
                          label: const Text(
                            '+5 min más',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.redAccent.withValues(alpha: 0.18),
                            foregroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () {
                            audioPlayerService.cancelSleepTimer();
                            Navigator.pop(ctx);
                          },
                          icon: const Icon(Icons.timer_off_rounded, size: 18),
                          label: const Text(
                            'Desactivar',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
