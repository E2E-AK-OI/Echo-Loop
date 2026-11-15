import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:echo_loop/features/ai_speaking/services/local_asr_streaming_transcriber.dart';
import 'package:echo_loop/services/asr/offline_asr_engine.dart';

class _FakeEngine implements OfflineAsrEngine {
  _FakeEngine(this.results);

  final List<String> results;
  final received = <Uint8List>[];
  var _index = 0;

  @override
  String get name => 'fake';

  @override
  bool get isReady => true;

  @override
  AsrModelInfo? get currentModel => null;

  @override
  Future<void> initialize(AsrModelConfig config) async {}

  @override
  Future<AsrResult> transcribe(String wavPath) async {
    received.add(await File(wavPath).readAsBytes());
    final text = results[_index.clamp(0, results.length - 1)];
    _index++;
    return AsrResult(text: text, inferenceTime: Duration.zero);
  }

  @override
  Future<List<AsrSegment>> transcribeSegments(
    String wavPath, {
    void Function(double progress)? onProgress,
  }) async => const [];

  @override
  Future<void> dispose() async {}
}

Uint8List _wav(int payloadLength) {
  final bytes = Uint8List(44 + payloadLength);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  ascii(36, 'data');
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  for (var i = 0; i < payloadLength; i++) {
    bytes[44 + i] = i + 1;
  }
  return bytes;
}

void main() {
  test('WAV 快照回填 RIFF 与 data 长度', () {
    final snapshot = buildStreamingWavSnapshot(_wav(6))!;
    final data = ByteData.sublistView(snapshot);
    expect(data.getUint32(4, Endian.little), snapshot.length - 8);
    expect(data.getUint32(40, Endian.little), 6);
  });

  test('非法或不完整的 WAV 不生成快照', () {
    expect(buildStreamingWavSnapshot(Uint8List(20)), isNull);
    final bad = _wav(2);
    bad[0] = 0;
    expect(buildStreamingWavSnapshot(bad), isNull);
  });

  test('录音增长时按增量生成伪流式转写', () async {
    final root = await Directory.systemTemp.createTemp('asr-stream-test');
    addTearDown(() => root.delete(recursive: true));
    final wav = File(p.join(root.path, 'recording.wav'));
    await wav.writeAsBytes(_wav(4));
    final engine = _FakeEngine(['hello', 'hello world']);
    final partials = <String>[];
    final transcriber = LocalAsrStreamingTranscriber(
      engine: engine,
      wavPath: wav.path,
      onPartial: partials.add,
      interval: const Duration(hours: 1),
      tempDirectory: Directory(p.join(root.path, 'temp')),
    );

    await transcriber.transcribeNow();
    await wav.writeAsBytes(_wav(8));
    await transcriber.transcribeNow();
    await transcriber.transcribeNow();

    expect(partials, ['hello', 'hello world']);
    expect(engine.received, hasLength(2));
    final last = ByteData.sublistView(engine.received.last);
    expect(last.getUint32(4, Endian.little), engine.received.last.length - 8);
    expect(last.getUint32(40, Endian.little), 8);
    transcriber.stop();
    await transcriber.dispose();
  });
}
