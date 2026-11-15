import 'package:echo_loop/features/ai_speaking/services/vad_turn_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 以 20ms 帧节奏喂入固定电平，收集产生的事件。
List<VadTurnEvent> feedLevels(
  VadTurnDetector detector,
  double level,
  int startMs,
  int count,
) {
  final events = <VadTurnEvent>[];
  for (var i = 0; i < count; i++) {
    final event = detector.feed(level: level, timestampMs: startMs + i * 20);
    if (event != null) events.add(event);
  }
  return events;
}

VadTurnDetector makeDetector({
  int endOfSpeechMs = 800,
  int idleTimeoutMs = 30000,
  int hardLimitMs = 2000,
}) {
  return VadTurnDetector(
    endOfSpeech: Duration(milliseconds: endOfSpeechMs),
    idleTimeout: Duration(milliseconds: idleTimeoutMs),
    hardLimit: Duration(milliseconds: hardLimitMs),
  );
}

void main() {
  test('短促噪声不会触发开始说话', () {
    final detector = makeDetector();
    final events = feedLevels(detector, 0.2, 0, 5);

    expect(events, isEmpty);
    expect(detector.phase, VadTurnPhase.silence);
  });

  test('持续语音达到最小语音时长后触发一次开始说话', () {
    final detector = makeDetector();
    final events = feedLevels(detector, 0.2, 0, 20);

    expect(events, [VadTurnEvent.speechStarted]);
    expect(detector.phase, VadTurnPhase.speech);
  });

  test('尾静音未达到 EOS 时不结束本轮', () {
    final detector = makeDetector();
    feedLevels(detector, 0.2, 0, 20);

    // 780ms 静音仍不足 800ms EOS。
    final events = feedLevels(detector, 0.001, 400, 39);

    expect(events, isEmpty);
    expect(detector.phase, VadTurnPhase.speech);
  });

  test('尾静音达到 EOS 时结束本轮，并可开始下一轮', () {
    final detector = makeDetector();
    feedLevels(detector, 0.2, 0, 20);

    final ended = feedLevels(detector, 0.001, 400, 41);
    expect(ended, [VadTurnEvent.speechEnded]);

    final next = feedLevels(detector, 0.2, 1220, 20);
    expect(next, [VadTurnEvent.speechStarted]);
  });

  test('静默超过空闲时长触发 idleTimeout 并重新计时', () {
    final detector = makeDetector(idleTimeoutMs: 1000);

    final first = feedLevels(detector, 0.001, 0, 51);
    expect(first, [VadTurnEvent.idleTimeout]);

    final second = feedLevels(detector, 0.001, 1020, 49);
    expect(second, isEmpty);
  });

  test('AI 朗读期间静音判定，恢复后重新开始静默计时', () {
    final detector = makeDetector(idleTimeoutMs: 1000);
    detector.mute();

    expect(feedLevels(detector, 0.2, 0, 40), isEmpty);
    expect(detector.phase, VadTurnPhase.silence);

    detector.unmute(timestampMs: 800);
    // 恢复后 900ms 静默不应立刻空闲超时。
    expect(feedLevels(detector, 0.001, 820, 45), isEmpty);
    // 越过 1000ms 后触发一次。
    expect(feedLevels(detector, 0.001, 1720, 10), [VadTurnEvent.idleTimeout]);
  });

  test('reset 清空状态并允许重新判定', () {
    final detector = makeDetector();
    feedLevels(detector, 0.2, 0, 20);
    expect(detector.phase, VadTurnPhase.speech);

    detector.reset();
    expect(detector.phase, VadTurnPhase.silence);

    final events = feedLevels(detector, 0.2, 5000, 20);
    expect(events, [VadTurnEvent.speechStarted]);
  });

  test('电平长期低于本轮峰值时按硬上限强制断句', () {
    final detector = makeDetector(hardLimitMs: 2000);
    // 0.09 的语音峰值让 0.03 的底噪仍高于入门门限，但低于峰值的 70%。
    final started = feedLevels(detector, 0.09, 0, 16);
    expect(started, [VadTurnEvent.speechStarted]);

    // 底噪一直高于 0.02 的入门门限，旧实现永远等不到静音帧。
    final ended = feedLevels(detector, 0.03, 320, 100);
    expect(ended, [VadTurnEvent.speechEnded]);
    expect(detector.phase, VadTurnPhase.silence);
  });

  test('持续接近峰值的长句不会被硬上限提前截断', () {
    final detector = makeDetector(hardLimitMs: 2000);

    final events = feedLevels(detector, 0.09, 0, 201);

    expect(events, [VadTurnEvent.speechStarted]);
    expect(detector.phase, VadTurnPhase.speech);
  });

  test('环境噪声抬高门限后不再把底噪当成说话', () {
    final detector = makeDetector();
    // 先喂入 0.018 的持续底噪，抬高噪声底到上限 0.02。
    feedLevels(detector, 0.018, 0, 300);

    expect(detector.effectiveThreshold, greaterThan(0.018));
    expect(detector.phase, VadTurnPhase.silence);
  });

  test('抬高门限期间不把外放回声当成说话，恢复后照常判定', () {
    final detector = makeDetector();
    detector.raiseThreshold(0.05);

    // 0.03 平时足以判定开口，抬高到 0.05 后应保持静音。
    expect(feedLevels(detector, 0.03, 0, 400), isEmpty);
    expect(detector.phase, VadTurnPhase.silence);

    detector.raiseThreshold(null);
    final events = feedLevels(detector, 0.2, 500, 400);
    expect(events, [VadTurnEvent.speechStarted]);
  });
}
