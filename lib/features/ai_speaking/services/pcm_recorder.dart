/// 16kHz 单声道 PCM 录音封装。
///
/// 使用 record 的 startStream 直接拿原始 PCM，交给阿里云实时识别；
/// 不写临时文件，避免录音文件残留。
library;

import 'dart:typed_data';

import 'package:record/record.dart';

abstract class PcmRecorder {
  Future<bool> hasPermission();

  Future<Stream<Uint8List>> start({
    int sampleRate = 16000,
    int numChannels = 1,
  });

  /// 会话录音：使用 VOICE_COMMUNICATION 录音源，让平台 AEC 把外放 TTS
  /// 当作回声参考。默认实现回退普通录音，便于非 Android 平台与测试替换。
  Future<Stream<Uint8List>> startForVoiceCommunication({
    int sampleRate = 16000,
    int numChannels = 1,
  }) => start(sampleRate: sampleRate, numChannels: numChannels);

  Future<void> stop();

  Future<void> dispose();
}

class RecordPcmRecorder implements PcmRecorder {
  RecordPcmRecorder({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start({
    int sampleRate = 16000,
    int numChannels = 1,
  }) {
    return _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: numChannels,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );
  }

  @override
  Future<Stream<Uint8List>> startForVoiceCommunication({
    int sampleRate = 16000,
    int numChannels = 1,
  }) {
    return _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: numChannels,
        // 外放插话用 duck 后的残留电平判断人声；AGC 会把衰减后的回声
        // 重新放大，导致回声看起来像持续人声，因此这里必须关闭。
        autoGain: false,
        echoCancel: true,
        noiseSuppress: true,
        androidConfig: const AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
          audioManagerMode: AudioManagerMode.modeInCommunication,
        ),
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
