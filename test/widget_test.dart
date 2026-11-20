import 'package:audiomind/data/services/app_update_service.dart';
import 'package:audiomind/data/services/cloud_book_downloader_service.dart';
import 'package:audiomind/data/services/tts_synthesis_service.dart';
import 'package:audiomind/domain/models/chapter_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CloudBookDownloaderService security & URL normalization', () {
    test('extracts Google Drive ID and uses direct confirm=t download URL', () {
      const shareUrl = 'https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz/view?usp=sharing';
      expect(
        CloudBookDownloaderService.extractGoogleDriveId(shareUrl),
        '1AbCdEfGhIjKlMnOpQrStUvWxYz',
      );
      expect(
        CloudBookDownloaderService.buildDownloadUrl(shareUrl),
        'https://drive.usercontent.google.com/download?id=1AbCdEfGhIjKlMnOpQrStUvWxYz&export=download&confirm=t',
      );
    });

    test('sanitizes filenames against path traversal attacks', () {
      expect(
        CloudBookDownloaderService.sanitizeFileName('../../etc/passwd'),
        'passwd',
      );
      expect(
        CloudBookDownloaderService.sanitizeFileName(r'..\..\windows\system32\book.pdf'),
        'book.pdf',
      );
      expect(
        CloudBookDownloaderService.sanitizeFileName('..'),
        'libro.pdf',
      );
    });

    test('rejects unsafe schemes and private/localhost SSRF targets', () {
      expect(
        () => CloudBookDownloaderService.validateDownloadUri('file:///etc/passwd'),
        throwsException,
      );
      expect(
        () => CloudBookDownloaderService.validateDownloadUri('http://127.0.0.1:8090/tts'),
        throwsException,
      );
      expect(
        () => CloudBookDownloaderService.validateDownloadUri('http://192.168.1.10/book.pdf'),
        throwsException,
      );
      expect(
        CloudBookDownloaderService.validateDownloadUri('https://drive.usercontent.google.com/download?id=123').host,
        'drive.usercontent.google.com',
      );
    });
  });

  group('TtsSynthesisService cache key generation', () {
    test('generates deterministic segment keys with and without text hash', () {
      final tts = TtsSynthesisService();
      final ch = ChapterItem(
        id: 1,
        title: 'Capítulo 1',
        subtitle: 'Págs. 1-5',
        durationText: '3 min',
        textContent: 'Hola mundo de prueba.',
      );

      final k1 = tts.segmentKeyId('book_1', ch, 0, 'es-MX-JorgeNeural', text: 'Hola mundo');
      final k2 = tts.segmentKeyId('book_1', ch, 0, 'es-MX-JorgeNeural', text: '  hola   mundo ');
      final kEn = tts.segmentKeyId('book_1', ch, 0, 'en-US-GuyNeural', text: 'Hello world');

      expect(k1, equals(k2));
      expect(k1, isNot(equals(kEn)));
      expect(k1.contains('_es_h'), isTrue);
      expect(kEn.contains('_en_h'), isTrue);
    });
  });

  group('AppUpdateService OTA version, ABI & host verification', () {
    test('compares semver and build numbers accurately', () {
      expect(
        AppUpdateService.isNewerVersion(
          remoteVersionSource: 'v1.0.1',
          currentVersion: '1.0.0',
          currentBuild: 2015,
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isNewerVersion(
          remoteVersionSource: 'v1.0.0+2016',
          currentVersion: '1.0.0',
          currentBuild: 2015,
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isNewerVersion(
          remoteVersionSource: 'v1.0.0+2015',
          currentVersion: '1.0.0',
          currentBuild: 2015,
        ),
        isFalse,
      );
      expect(
        AppUpdateService.isNewerVersion(
          remoteVersionSource: 'v0.9.9+9999',
          currentVersion: '1.0.0',
          currentBuild: 2015,
        ),
        isFalse,
      );
    });

    test('selects optimal APK asset matching device ABI with universal fallback', () {
      final assets = [
        {'name': 'Audibuuks_v1.0.1_armeabi-v7a.apk', 'browser_download_url': 'https://github.com/a.apk'},
        {'name': 'Audibuuks_v1.0.1_arm64-v8a.apk', 'browser_download_url': 'https://github.com/b.apk'},
        {'name': 'Audibuuks_v1.0.1.apk', 'browser_download_url': 'https://github.com/u.apk'},
      ];

      final arm64 = AppUpdateService.selectBestApkAsset(assets, ['arm64-v8a', 'armeabi-v7a']);
      expect(arm64?['name'], 'Audibuuks_v1.0.1_arm64-v8a.apk');

      final armv7 = AppUpdateService.selectBestApkAsset(assets, ['armeabi-v7a']);
      expect(armv7?['name'], 'Audibuuks_v1.0.1_armeabi-v7a.apk');

      final x86Fallback = AppUpdateService.selectBestApkAsset(assets, ['x86_64']);
      expect(x86Fallback?['name'], 'Audibuuks_v1.0.1.apk');
    });

    test('only permits official HTTPS GitHub hosts for APK updates', () {
      expect(
        AppUpdateService.isTrustedUpdateHost(
          Uri.parse('https://github.com/lukgutierrez/audibuuks-app/releases/download/v1.0.1/app.apk'),
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isTrustedUpdateHost(
          Uri.parse('https://objects.githubusercontent.com/github-production-release-asset/app.apk'),
        ),
        isTrue,
      );
      expect(
        AppUpdateService.isTrustedUpdateHost(
          Uri.parse('http://github.com/lukgutierrez/audibuuks-app/app.apk'),
        ),
        isFalse,
      );
      expect(
        AppUpdateService.isTrustedUpdateHost(
          Uri.parse('https://evil-mirror.example.com/app.apk'),
        ),
        isFalse,
      );
    });
  });
}
