# Flutter R8 / ProGuard configuration for release optimization

-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Just Audio, Audio Session & Background Audio Service
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.audio_session.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-keep class androidx.media.** { *; }

# Syncfusion PDF
-keep class com.syncfusion.** { *; }
