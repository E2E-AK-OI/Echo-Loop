/// 输入电平计算：把原始音频转换为 0~1 的 UI 电平。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 计算 16bit 单声道小端 PCM 的 RMS（0~1）。
///
/// 录屏或静音时返回 0；不足一个采样点时也返回 0，避免读出半个采样。
double pcm16Rms(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  if (sampleCount == 0) return 0;
  final data = ByteData.sublistView(bytes);
  var sum = 0.0;
  for (var i = 0; i < sampleCount; i++) {
    final sample = data.getInt16(i * 2, Endian.little) / 32767.0;
    sum += sample * sample;
  }
  return math.sqrt(sum / sampleCount);
}

/// 把原始 RMS 映射为 UI 电平。
///
/// 正常说话 RMS 通常只有 0.01~0.15，直接使用会让动画几乎不动；
/// 开方后再放大，既能拉开轻声与大声的差距，又不会在噪声底上乱跳。
double normalizeAudioLevel(double rms) {
  if (!rms.isFinite || rms <= 0) return 0;
  return (math.sqrt(rms) * 1.8).clamp(0.0, 1.0);
}
