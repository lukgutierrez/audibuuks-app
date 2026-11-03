import 'package:flutter/material.dart';

class AmbientTrackInfo {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;

  const AmbientTrackInfo({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
  });
}

const List<AmbientTrackInfo> kAmbientTracks = [
  AmbientTrackInfo(
    id: 'classical_adagio',
    title: 'Adagio en Piano Clásico',
    subtitle: 'Notas lentas y cristalinas estilo Erik Satie (Gymnopédie)',
    icon: Icons.piano_rounded,
  ),
  AmbientTrackInfo(
    id: 'debussy_harp',
    title: 'Preludio de Arpa & Piano',
    subtitle: 'Arpegios acústicos suaves y armónicos en Do Mayor',
    icon: Icons.music_note_rounded,
  ),
  AmbientTrackInfo(
    id: 'canon_chamber',
    title: 'Canon Armónico de Cámara',
    subtitle: 'Progresión clásica serena estilo Pachelbel para lectura',
    icon: Icons.library_music_rounded,
  ),
  AmbientTrackInfo(
    id: 'nocturne_calm',
    title: 'Nocturno Minimalista',
    subtitle: 'Piano íntimo y pausado estilo Ludovico Einaudi',
    icon: Icons.nights_stay_rounded,
  ),
];
