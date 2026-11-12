/// 输入电平计算测试。
library;

import 'dart:typed_data';

import 'package:echo_loop/features/ai_speaking/services/audio_level.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _pcm16(List<int> samples) {
  final bytes = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  group('pcm16Rms', () {
    test('静音与空数据返回 0', () {
      expect(pcm16Rms(Uint8List(0)), 0);
      expect(pcm16Rms(_pcm16([0, 0, 0, 0])), 0);
    });

    test('满幅采样归一化为 1', () {
      expect(pcm16Rms(_pcm16([32767, -32767])), closeTo(1, 0.001));
    });

    test('按小端解析 16bit 采样', () {
      // 单个 16384 采样约为满幅一半。
      expect(pcm16Rms(_pcm16([16384])), closeTo(0.5, 0.001));
    });

    test('忽略不足一个采样点的尾部字节', () {
      final bytes = Uint8List.fromList([
        ..._pcm16([16384]),
        0x12,
      ]);

      expect(pcm16Rms(bytes), closeTo(0.5, 0.001));
    });
  });

  group('normalizeAudioLevel', () {
    test('无效值与静音映射为 0', () {
      expect(normalizeAudioLevel(0), 0);
      expect(normalizeAudioLevel(-0.2), 0);
      expect(normalizeAudioLevel(double.nan), 0);
      expect(normalizeAudioLevel(double.infinity), 0);
    });

    test('开方放大轻声音量', () {
      // 常见说话 RMS 约 0.04，线性映射几乎不可见；开方后应接近 0.36。
      expect(normalizeAudioLevel(0.04), closeTo(0.36, 0.001));
    });

    test('结果夹紧在 0~1', () {
      expect(normalizeAudioLevel(1), 1);
      expect(normalizeAudioLevel(9), 1);
    });
  });
}
