import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'ui/features/splash/views/splash_screen.dart';

class AudioMindApp extends StatelessWidget {
  const AudioMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audibuuks',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
