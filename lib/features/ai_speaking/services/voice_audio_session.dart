import 'dart:io';

import 'package:flutter/services.dart';

import 'pcm_stream_player.dart';

/// 原生音频会话状态。
///
/// 外放插话依赖平台 AEC。只有同时满足「外放」「AEC 可用」时，控制器才会
/// 进入 duck 判别流程；否则退回手动停止，避免把 TTS 回声当成用户插话。
class VoiceAudioSessionStatus {
  const VoiceAudioSessionStatus({
    required this.isSupported,
    required this.isSpeakerOutput,
    required this.isAecAvailable,
    required this.outputUsage,
    this.isRouteKnown = true,
  });

  const VoiceAudioSessionStatus.unsupported()
    : isSupported = false,
      isSpeakerOutput = false,
      isAecAvailable = false,
      outputUsage = PcmOutputUsage.media,
      isRouteKnown = false;

  final bool isSupported;
  final bool isSpeakerOutput;
  final bool isAecAvailable;
  final PcmOutputUsage outputUsage;

  /// 原生是否成功读出当前输出路由。读不到时不能把「未知」当成耳机，
  /// 否则会错误地打开 VAD 插话并再次被外放回声触发。
  final bool isRouteKnown;

  bool get canUseSpeakerBargeIn =>
      isSupported && isRouteKnown && isSpeakerOutput && isAecAvailable;

  static VoiceAudioSessionStatus fromMap(Object? value) {
    if (value is! Map) {
      return const VoiceAudioSessionStatus.unsupported();
    }
    final usage = value['usage'] == 'voiceCommunication'
        ? PcmOutputUsage.voiceCommunication
        : PcmOutputUsage.media;
    return VoiceAudioSessionStatus(
      isSupported: value['isSupported'] == true,
      isSpeakerOutput: value['isSpeakerOutput'] == true,
      isAecAvailable: value['isAecAvailable'] == true,
      outputUsage: usage,
      isRouteKnown: value['isRouteKnown'] == true,
    );
  }
}

/// 原生音频会话：把系统切到通话模式，让平台 AEC 把外放 TTS 当作参考信号。
abstract class VoiceAudioSession {
  bool get isSupported => Platform.isAndroid;

  Future<VoiceAudioSessionStatus> begin();

  Future<VoiceAudioSessionStatus> prepareForTts();

  Future<void> end();
}

class PlatformVoiceAudioSession implements VoiceAudioSession {
  static const MethodChannel _channel = MethodChannel(
    'top.echo-loop/voice_audio_session',
  );

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<VoiceAudioSessionStatus> begin() => _invoke('begin');

  @override
  Future<VoiceAudioSessionStatus> prepareForTts() => _invoke('prepareForTts');

  @override
  Future<void> end() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('end');
    } on PlatformException {
      // 会话收尾失败不影响后续听音，原生侧下次 begin 会重新保存初始状态。
    }
  }

  Future<VoiceAudioSessionStatus> _invoke(String method) async {
    if (!isSupported) {
      return const VoiceAudioSessionStatus.unsupported();
    }
    try {
      final result = await _channel.invokeMethod<Object?>(method);
      return VoiceAudioSessionStatus.fromMap(result);
    } on PlatformException {
      return const VoiceAudioSessionStatus.unsupported();
    }
  }
}
