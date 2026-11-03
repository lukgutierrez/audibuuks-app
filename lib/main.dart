import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.ryanheise.bg_demo.channel.audio',
      androidNotificationChannelName: 'AudioMind Reproducción',
      androidNotificationOngoing: true,
    );
  } catch (e) {
    debugPrint('Background audio init notice: $e');
  }
  runApp(const AudioMindApp());
}
