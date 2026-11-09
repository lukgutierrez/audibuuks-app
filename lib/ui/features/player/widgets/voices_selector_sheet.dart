import 'package:flutter/material.dart';
import '../../../../data/services/tts_synthesis_service.dart';

class VoicesSelectorSheet extends StatelessWidget {
  final String selectedVoiceKey;
  final void Function(String voiceKey, String voiceName) onVoiceSelected;

  const VoicesSelectorSheet({
    super.key,
    required this.selectedVoiceKey,
    required this.onVoiceSelected,
  });

  Widget _buildVoiceTile(BuildContext context, MapEntry<String, String> entry) {
    final isSelected = selectedVoiceKey == entry.key;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: isSelected
            ? const Color(0xFFF5A623)
            : const Color(0xFF2C2D32),
        child: Icon(
          Icons.record_voice_over,
          color: isSelected ? Colors.black : Colors.white,
        ),
      ),
      title: Text(
        entry.value,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? const Color(0xFFF5A623) : Colors.white,
        ),
      ),
      trailing: isSelected
          ? const Icon(Icons.check_circle_rounded, color: Color(0xFFF5A623))
          : null,
      onTap: () {
        Navigator.pop(context);
        onVoiceSelected(entry.key, entry.value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Narradores Neuronales HD (96 kbps)',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          const SizedBox(height: 4),
          const Text(
            'Se guarda automáticamente tu voz elegida para todos tus libros',
            style: TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(
                      '🇪🇸 VOCES EN ESPAÑOL',
                      style: TextStyle(
                        color: Color(0xFFEAA036),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  ...TtsSynthesisService.voicesMap.entries
                      .where((e) => e.key.startsWith('es-'))
                      .map((entry) => _buildVoiceTile(context, entry)),
                  const Padding(
                    padding: EdgeInsets.only(top: 14, bottom: 4),
                    child: Text(
                      '🇺🇸 VOCES EN INGLÉS (ENGLISH HD)',
                      style: TextStyle(
                        color: Color(0xFF64B5F6),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  ...TtsSynthesisService.voicesMap.entries
                      .where((e) => e.key.startsWith('en-'))
                      .map((entry) => _buildVoiceTile(context, entry)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
