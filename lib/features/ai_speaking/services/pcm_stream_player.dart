import 'dart:io';

import 'package:flutter/services.dart';

/// PCM 输出的系统用途。
///
/// 外放插话需要 AEC 把播放信号当作回声参考；平台只有把输出标记为
/// voice communication 时才会稳定提供该参考。耳机场景仍用媒体用途，
/// 避免通话模式压低音乐/提示音音量。
enum PcmOutputUsage { media, voiceCommunication }

/// 流式 PCM 播放器：把服务端持续返回的音频块按顺序送入系统音频输出。
abstract class PcmStreamPlayer {
  static const int defaultSampleRate = 24000;

  bool get isSupported => Platform.isAndroid;

  Future<void> start({int sampleRate = defaultSampleRate});

  /// 按指定系统用途启动播放器；默认保持原有媒体用途实现。
  Future<void> startWithUsage({
    int sampleRate = defaultSampleRate,
    PcmOutputUsage usage = PcmOutputUsage.media,
  }) => start(sampleRate: sampleRate);

  /// 调整当前播放器音量，只用于外放插话的临时 duck。
  Future<void> setVolume(double volume) async {}

  Future<void> write(Uint8List pcm);

  Future<void> flush();

  /// 等待已入队音频自然播放完再释放播放器。
  ///
  /// 与 [stop] 不同，调用方应在合成流正常结束后使用本方法；[stop] 会立即
  /// 丢弃缓冲区，只用于插话、取消或错误收尾。
  Future<void> finish();

  Future<void> stop();
}

class PlatformPcmStreamPlayer extends PcmStreamPlayer {
  PlatformPcmStreamPlayer();

  static const MethodChannel _channel = MethodChannel(
    'top.echo-loop/pcm_stream_player',
  );

  bool _isStarted = false;
  int _generation = 0;

  @override
  Future<void> start({int sampleRate = PcmStreamPlayer.defaultSampleRate}) {
    return startWithUsage(sampleRate: sampleRate);
  }

  @override
  Future<void> startWithUsage({
    int sampleRate = PcmStreamPlayer.defaultSampleRate,
    PcmOutputUsage usage = PcmOutputUsage.media,
  }) async {
    _generation += 1;
    final generation = _generation;
    await _channel.invokeMethod<void>('start', {
      'sampleRate': sampleRate,
      'usage': usage.name,
    });
    if (_generation == generation) {
      _isStarted = true;
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!_isStarted) return;
    await _channel.invokeMethod<void>('setVolume', {
      'volume': volume.clamp(0.0, 1.0),
    });
  }

  @override
  Future<void> write(Uint8List pcm) async {
    if (!_isStarted || pcm.isEmpty) return;
    await _channel.invokeMethod<void>('write', {'bytes': pcm});
  }

  @override
  Future<void> flush() async {
    if (!_isStarted) return;
    await _channel.invokeMethod<void>('flush');
  }

  @override
  Future<void> finish() async {
    if (!_isStarted) return;
    final generation = _generation;
    try {
      await _channel.invokeMethod<void>('finish');
    } on Object {
      await stop();
      rethrow;
    } finally {
      if (_generation == generation) {
        _isStarted = false;
      }
    }
  }

  @override
  Future<void> stop() async {
    if (!_isStarted) return;
    _isStarted = false;
    _generation += 1;
    await _channel.invokeMethod<void>('stop');
  }
}
