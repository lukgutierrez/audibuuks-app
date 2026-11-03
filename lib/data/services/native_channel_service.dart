import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'lofi_generator_service.dart';

class NativeChannelService {
  static const MethodChannel channel = MethodChannel('com.lo.audiomind/pdf_cover');
  static String currentTrackId = 'classical_adagio';

  static Future<void> initLoFi({
    String trackId = 'classical_adagio',
    bool autoStart = false,
  }) async {
    try {
      currentTrackId = trackId;
      final wavPath = await LoFiGeneratorService.ensureAmbientTrack(trackId);
      await channel.invokeMethod('initLoFi', {
        'path': wavPath,
        'autoStart': autoStart,
      });
    } catch (e) {
      debugPrint('initLoFi notice: $e');
    }
  }

  static Future<void> selectAndPlayTrack(
    String trackId,
    double volume, {
    required bool shouldPlayNow,
  }) async {
    try {
      currentTrackId = trackId;
      final wavPath = await LoFiGeneratorService.ensureAmbientTrack(trackId);
      await channel.invokeMethod('setLoFiVolume', {'volume': volume});
      await channel.invokeMethod('initLoFi', {
        'path': wavPath,
        'autoStart': shouldPlayNow && volume > 0,
      });
    } catch (e) {
      debugPrint('selectAndPlayTrack notice: $e');
    }
  }

  static Future<void> playLoFi() async {
    try {
      final wavPath = await LoFiGeneratorService.ensureAmbientTrack(currentTrackId);
      await channel.invokeMethod('playLoFi', {'path': wavPath});
    } catch (_) {}
  }

  static Future<void> pauseLoFi() async {
    try {
      await channel.invokeMethod('pauseLoFi');
    } catch (_) {}
  }

  static Future<void> setLoFiVolume(double volume) async {
    try {
      await channel.invokeMethod('setLoFiVolume', {'volume': volume});
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> renderPdfPage(
    String path,
    int pageIndex, {
    int width = 1080,
  }) async {
    try {
      final res = await channel.invokeMethod('renderPdfPage', {
        'path': path,
        'pageIndex': pageIndex,
        'width': width,
      });
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      debugPrint('renderPdfPage notice: $e');
    }
    return null;
  }

  static Future<Map<String, dynamic>?> extractEpub(String path) async {
    try {
      final res = await channel.invokeMethod('extractEpub', {'path': path});
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      debugPrint('extractEpub notice: $e');
    }
    return null;
  }
}
