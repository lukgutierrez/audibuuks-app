import 'dart:io';
import 'package:flutter/material.dart';
import '../../../../data/services/app_update_service.dart';
import '../../../../data/services/native_channel_service.dart';

/// BottomSheet moderno de actualización in-app para Audibuuks.
/// Descarga el APK oficial desde GitHub Releases y abre el instalador nativo de Android sin perder datos.
class AppUpdateSheet extends StatefulWidget {
  final AppUpdateInfo updateInfo;

  const AppUpdateSheet({
    super.key,
    required this.updateInfo,
  });

  @override
  State<AppUpdateSheet> createState() => _AppUpdateSheetState();
}

class _AppUpdateSheetState extends State<AppUpdateSheet> {
  bool _isDownloading = false;
  bool _isCancelled = false;
  bool _needsInstallPermission = false;
  ApkDownloadProgress? _progress;
  File? _downloadedApk;
  String? _errorMessage;

  Future<void> _startDownloadAndInstall() async {
    setState(() {
      _isDownloading = true;
      _isCancelled = false;
      _errorMessage = null;
      _needsInstallPermission = false;
      _progress = ApkDownloadProgress(
        bytesReceived: 0,
        totalBytes: widget.updateInfo.apkSizeBytes,
        percent: 0,
        speedLabel: 'Conectando...',
      );
    });

    try {
      final apk = await AppUpdateService.downloadUpdateApk(
        info: widget.updateInfo,
        onProgress: (prog) {
          if (mounted) {
            setState(() => _progress = prog);
          }
        },
        isCancelled: () => _isCancelled || !mounted,
      );

      if (!mounted || _isCancelled) return;
      setState(() {
        _isDownloading = false;
        _downloadedApk = apk;
      });

      await _triggerInstall(apk);
    } catch (e) {
      if (!mounted) return;
      if (_isCancelled) {
        setState(() {
          _isDownloading = false;
          _progress = null;
        });
        return;
      }
      setState(() {
        _isDownloading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _triggerInstall(File apkFile) async {
    final canInstall = await NativeChannelService.canRequestPackageInstalls();
    if (!canInstall) {
      if (mounted) {
        setState(() => _needsInstallPermission = true);
      }
      await NativeChannelService.openInstallPermissionSettings();
      return;
    }

    if (mounted) {
      setState(() => _needsInstallPermission = false);
    }
    final launched = await NativeChannelService.installApk(apkFile.path);
    if (!launched && mounted) {
      setState(() {
        _errorMessage = 'No se pudo abrir el instalador de Android. Intentá de nuevo.';
      });
    }
  }

  @override
  void dispose() {
    _isCancelled = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.updateInfo;
    final progressVal = (_progress?.percent ?? 0) / 100.0;
    final mbRec = ((_progress?.bytesReceived ?? 0) / (1024 * 1024)).toStringAsFixed(1);
    final mbTot = ((_progress?.totalBytes ?? info.apkSizeBytes) / (1024 * 1024)).toStringAsFixed(1);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
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
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFFC14D), Color(0xFFE08E12)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFF5A623).withValues(alpha: 0.32),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.system_update_rounded,
                    color: Colors.black,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Nueva actualización disponible',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 17.5,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5A623).withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFF5A623).withValues(alpha: 0.55),
                              ),
                            ),
                            child: Text(
                              info.displayVersion,
                              style: const TextStyle(
                                color: Color(0xFFF5A623),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (info.formattedSize.isNotEmpty)
                            Text(
                              '• ${info.formattedSize}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF14161B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NOVEDADES DE ESTA VERSIÓN',
                      style: TextStyle(
                        color: Color(0xFFF5A623),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      info.releaseNotes,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (_isDownloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progressVal > 0 ? progressVal : null,
                  minHeight: 8,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFF5A623)),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Descargando $mbRec MB / $mbTot MB (${_progress?.percent ?? 0}%)',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _progress?.speedLabel ?? '',
                    style: const TextStyle(
                      color: Color(0xFFF5A623),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (_needsInstallPermission) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5A623).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFF5A623).withValues(alpha: 0.45)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.verified_user_outlined, color: Color(0xFFF5A623), size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Activá "Permitir desde esta fuente" en Ajustes y volvé acá para tocar Instalar.',
                        style: TextStyle(color: Colors.white, fontSize: 12, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(11),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.45)),
                ),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
                ),
              ),
            ],
            const Row(
              children: [
                Icon(Icons.shield_outlined, size: 14, color: Colors.white38),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Descarga directa oficial desde GitHub Releases • Tus libros y notas se conservan intactos.',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () async {
                      if (_isDownloading) {
                        setState(() => _isCancelled = true);
                      } else {
                        await AppUpdateService.dismissUpdateTag(info.tagName);
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                    child: Text(
                      _isDownloading ? 'Cancelar' : 'Más tarde',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF5A623),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _isDownloading
                        ? null
                        : () {
                            if (_downloadedApk != null && _downloadedApk!.existsSync()) {
                              _triggerInstall(_downloadedApk!);
                            } else {
                              _startDownloadAndInstall();
                            }
                          },
                    icon: Icon(
                      _downloadedApk != null
                          ? Icons.install_mobile_rounded
                          : Icons.download_rounded,
                      size: 20,
                    ),
                    label: Text(
                      _isDownloading
                          ? 'Descargando...'
                          : (_downloadedApk != null ? 'Instalar ahora' : 'Actualizar ahora'),
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
