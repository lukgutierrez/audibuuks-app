import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'ui/features/library/views/library_screen.dart';

class AudioMindApp extends StatelessWidget {
  const AudioMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AudioMind',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const LibraryScreen(),
    );
  }
}
