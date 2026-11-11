/// 纯 Dart 桩实现。
///
/// flutter_edge_tts 0.0.3 仅在「合成后导出 WAV」路径使用 audio_decode；本项目只取
/// MP3 字节写入缓存，因此不需要其原生解码能力。上游 audio_decode 带 native assets
/// 构建钩子，会在缺少 MSVC 的 Windows 构建机上阻断 flutter test / dart run；
/// 这里用 dependency_overrides 注入同版本纯 Dart 桩，保留公开 API 形状。
library;

import 'dart:typed_data';

/// 解码后的 PCM 音频。
class PcmAudio {
  PcmAudio({
    required this.sampleRate,
    required this.channels,
    required this.samples,
  });

  final int sampleRate;
  final int channels;
  final Int16List samples;
}

/// 本项目不使用的 MP3 解码入口；被调用说明走错了 WAV 导出路径。
PcmAudio decodeMp3(Uint8List bytes) {
  throw UnsupportedError('audio_decode 桩不提供 MP3 解码');
}
