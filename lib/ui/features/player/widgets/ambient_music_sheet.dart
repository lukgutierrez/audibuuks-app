import 'package:flutter/material.dart';
import '../../../../domain/models/ambient_track_info.dart';

class AmbientMusicSheet extends StatefulWidget {
  final double initialVolume;
  final String initialTrackId;
  final ValueChanged<double> onVolumeChanged;
  final void Function(String trackId, double volume) onTrackSelected;

  const AmbientMusicSheet({
    super.key,
    required this.initialVolume,
    required this.initialTrackId,
    required this.onVolumeChanged,
    required this.onTrackSelected,
  });

  @override
  State<AmbientMusicSheet> createState() => _AmbientMusicSheetState();
}

class _AmbientMusicSheetState extends State<AmbientMusicSheet> {
  late double _volume;
  late String _selectedTrackId;

  @override
  void initState() {
    super.initState();
    _volume = widget.initialVolume;
    _selectedTrackId = widget.initialTrackId;
  }

  void _updateVolume(double val) {
    setState(() => _volume = val);
    widget.onVolumeChanged(val);
  }

  Widget _buildVolumePresetChip(String label, double val) {
    final bool active = (_volume - val).abs() < 0.04;
    return InkWell(
      onTap: () => _updateVolume(val),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFF5A623) : Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            color: active ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.48,
      maxChildSize: 0.85,
      builder: (_, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 30),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.piano_rounded, color: Color(0xFFF5A623), size: 24),
                    SizedBox(width: 10),
                    Text(
                      'Música Clásica Instrumental',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                    ),
                  ],
                ),
                Switch(
                  value: _volume > 0,
                  activeThumbColor: const Color(0xFFF5A623),
                  onChanged: (enabled) {
                    final newVol = enabled ? 0.25 : 0.0;
                    _updateVolume(newVol);
                  },
                ),
              ],
            ),
            const Text(
              'Arpegios acústicos puros de piano y arpa sin ruido de fondo. Se pausa automáticamente al pausar la lectura.',
              style: TextStyle(color: Colors.white60, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(
                        _volume > 0
                            ? Icons.volume_up_rounded
                            : Icons.volume_off_rounded,
                        color: const Color(0xFFF5A623),
                      ),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          min: 0.0,
                          max: 1.0,
                          activeColor: const Color(0xFFF5A623),
                          inactiveColor: Colors.white12,
                          onChanged: _updateVolume,
                        ),
                      ),
                      SizedBox(
                        width: 46,
                        child: Text(
                          '${(_volume * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Color(0xFFF5A623),
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildVolumePresetChip('Silencio', 0.0),
                      _buildVolumePresetChip('Sutil 15%', 0.15),
                      _buildVolumePresetChip('Armónico 30%', 0.30),
                      _buildVolumePresetChip('Envolvente 55%', 0.55),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ...kAmbientTracks.map((track) {
              final isSelected = _selectedTrackId == track.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    final vol = _volume > 0 ? _volume : 0.25;
                    setState(() {
                      _selectedTrackId = track.id;
                      _volume = vol;
                    });
                    widget.onTrackSelected(track.id, vol);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFFF5A623).withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFFF5A623)
                            : Colors.white12,
                        width: isSelected ? 1.4 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 21,
                          backgroundColor: isSelected
                              ? const Color(0xFFF5A623)
                              : Colors.white10,
                          child: Icon(
                            track.icon,
                            color: isSelected ? Colors.black : Colors.white70,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.title,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                  color: isSelected
                                      ? const Color(0xFFF5A623)
                                      : Colors.white,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                track.subtitle,
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          isSelected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: isSelected
                              ? const Color(0xFFF5A623)
                              : Colors.white38,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
