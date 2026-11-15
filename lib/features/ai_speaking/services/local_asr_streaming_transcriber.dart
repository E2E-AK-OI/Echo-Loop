/// 本地 ASR 的“伪流式”转录器。
///
/// Android 录音器在停止前不会回填 WAV 头，不能直接把正在写入的文件交给
/// sherpa-onnx。这里按固定间隔复制当前 PCM、修正 RIFF/data 长度后写入临时
/// 文件，再让离线引擎解码，从而在说话过程中得到不断更新的转写文本。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../services/asr/offline_asr_engine.dart';

/// 周期性地对正在录制的 WAV 做一次完整解码，并回调当前最佳文本。
class LocalAsrStreamingTranscriber {
  LocalAsrStreamingTranscriber({
    required this.engine,
    required this.wavPath,
    required this.onPartial,
    this.interval = const Duration(milliseconds: 1200),
    Directory? tempDirectory,
  }) : _tempDirectoryOverride = tempDirectory;

  final OfflineAsrEngine engine;
  final String wavPath;
  final void Function(String text) onPartial;
  final Duration interval;

  final Directory? _tempDirectoryOverride;
  Directory? _tempDirectory;
  bool _ownsTempDirectory = false;
  Timer? _timer;
  Future<void>? _inFlight;
  int _lastByteLength = 0;
  bool _disposed = false;

  /// 开始周期转录；重复调用无副作用。
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      unawaited(transcribeNow());
    });
  }

  /// 立即执行一次转录；已有任务在跑时复用同一个 Future。
  Future<void> transcribeNow() {
    if (_disposed) return Future<void>.value();
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _transcribeOnce();
    _inFlight = future;
    return future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
  }

  Future<void> _transcribeOnce() async {
    try {
      final source = File(wavPath);
      if (!source.existsSync()) return;
      final bytes = await source.readAsBytes();
      if (bytes.length <= 44 || bytes.length == _lastByteLength) return;
      _lastByteLength = bytes.length;
      final snapshot = buildStreamingWavSnapshot(bytes);
      if (snapshot == null) return;
      final directory = await _ensureTempDirectory();
      final temp = File(p.join(directory.path, 'partial.wav'));
      await temp.writeAsBytes(snapshot, flush: true);
      final result = await engine.transcribe(temp.path);
      final text = result.text.trim();
      if (!_disposed && text.isNotEmpty) onPartial(text);
    } catch (_) {
      // 说话过程中的临时解码失败不应打断录音；停止后的完整识别仍是权威结果。
    }
  }

  Future<Directory> _ensureTempDirectory() async {
    final existing = _tempDirectory;
    if (existing != null) return existing;
    final override = _tempDirectoryOverride;
    if (override != null) {
      await override.create(recursive: true);
      _tempDirectory = override;
      return override;
    }
    final directory = await Directory.systemTemp.createTemp(
      'echo_loop_asr_stream_',
    );
    _tempDirectory = directory;
    _ownsTempDirectory = true;
    return directory;
  }

  /// 停止后续调度；已在执行的解码结果会被丢弃。
  void stop() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  /// 释放临时目录；调用后实例不可复用。
  Future<void> dispose() async {
    stop();
    final directory = _tempDirectory;
    _tempDirectory = null;
    if (_ownsTempDirectory && directory != null && directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }
}

/// 为正在写入的 WAV 生成可解码快照，回填 RIFF 与 data 长度。
///
/// 录音器启动时把这两个长度写成 0，只有停止时才 patch；因此录音中途直接
/// 解码会得到 0 个采样。返回 null 表示还不是可识别的 WAV 头。
Uint8List? buildStreamingWavSnapshot(Uint8List bytes) {
  if (bytes.length < 44) return null;
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    return null;
  }
  final snapshot = Uint8List.fromList(bytes);
  final data = ByteData.sublistView(snapshot);
  data.setUint32(4, snapshot.length - 8, Endian.little);
  data.setUint32(40, snapshot.length - 44, Endian.little);
  return snapshot;
}
