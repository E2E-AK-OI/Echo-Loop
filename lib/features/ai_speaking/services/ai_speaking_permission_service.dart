/// AI 口语练习的麦克风权限。
///
/// 复用项目已有的 SpeechPermissionService，只申请麦克风权限，不申请语音识别权限。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/speech_permission_service.dart';

abstract class AiSpeakingPermissionService {
  bool get isSupported;

  Future<bool> ensurePermission();

  Future<void> openSettings();
}

class PlatformAiSpeakingPermissionService
    implements AiSpeakingPermissionService {
  PlatformAiSpeakingPermissionService(this._speechPermissionService);

  final SpeechPermissionService _speechPermissionService;

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> ensurePermission() async {
    final status = await _speechPermissionService.getStatus();
    if (status.isGranted) return true;
    final requested = await _speechPermissionService.request(onlyMic: true);
    return requested.isGranted;
  }

  @override
  Future<void> openSettings() => _speechPermissionService.openAppSettings();
}

final aiSpeakingPermissionServiceProvider =
    Provider<AiSpeakingPermissionService>(
      (ref) => PlatformAiSpeakingPermissionService(
        ref.read(speechPermissionServiceProvider),
      ),
    );
