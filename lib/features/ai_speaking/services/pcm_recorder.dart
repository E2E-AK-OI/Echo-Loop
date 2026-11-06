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
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
