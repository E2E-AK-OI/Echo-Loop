import 'package:echo_loop/features/ai_speaking/services/voice_barge_in_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late VoiceBargeInGuard guard;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    guard = VoiceBargeInGuard(
      now: () => now,
      minPlaybackBeforeCandidate: const Duration(milliseconds: 300),
      candidateHold: const Duration(milliseconds: 90),
      confirmHold: const Duration(milliseconds: 250),
      confirmWindow: const Duration(milliseconds: 700),
      resumeHold: const Duration(milliseconds: 450),
      maxDuckDuration: const Duration(seconds: 2),
    );
  });

  List<VoiceBargeInAction> feed(double level, int milliseconds) {
    now = now.add(Duration(milliseconds: milliseconds));
    return guard.onInputFrame(level);
  }

  /// 启动播放并让用户持续越线，直到返回 duck。
  VoiceBargeInAction startDuck({
    required double candidateThreshold,
    required double level,
  }) {
    guard.onPlaybackStarted(candidateThreshold: candidateThreshold);
    feed(level, 0);
    final actions = feed(level, 320);
    return actions.single;
  }

  /// 从 duck 推进到静音复核，并越过 180ms 尾音收敛窗口。
  void enterListening() {
    expect(feed(0.3, 100), isEmpty);
    final listen = feed(0.3, 100);
    expect(listen.single.type, VoiceBargeInActionType.listen);
    expect(guard.isListening, isTrue);
    expect(feed(0.3, 100), isEmpty);
    expect(feed(0.3, 100), isEmpty);
  }

  test('低电平持续人声：duck 后静音复核并确认', () {
    expect(
      startDuck(candidateThreshold: 0.045, level: 0.05).type,
      VoiceBargeInActionType.duck,
    );
    enterListening();

    expect(feed(0.05, 100), isEmpty);
    expect(feed(0.05, 100), isEmpty);
    final confirm = feed(0.05, 100);
    expect(confirm.single.type, VoiceBargeInActionType.confirm);
    expect(guard.isConfirmed, isTrue);
  });

  test('duck 后回声消失时恢复 TTS 音量，不确认', () {
    expect(
      startDuck(candidateThreshold: 0.2, level: 0.3).type,
      VoiceBargeInActionType.duck,
    );
    enterListening();

    expect(feed(0, 200), isEmpty);
    final resume = feed(0, 510);
    expect(resume.single.type, VoiceBargeInActionType.resume);
    expect(guard.isConfirmed, isFalse);
    expect(guard.isListening, isFalse);
  });

  test('用户声音低于 duck 前回声时仍进入静音复核并确认', () {
    // duck 前是 0.4 的外放回声，duck 后用户只有 0.05；
    // 旧逻辑会用 0.4 的比例抬高门限，导致用户永远无法确认。
    expect(
      startDuck(candidateThreshold: 0.045, level: 0.4).type,
      VoiceBargeInActionType.duck,
    );
    enterListening();

    expect(feed(0.05, 100), isEmpty);
    expect(feed(0.05, 100), isEmpty);
    final confirm = feed(0.05, 100);
    expect(confirm.single.type, VoiceBargeInActionType.confirm);
  });

  test('人声短暂跌破门限时仍按窗口内有声时长确认', () {
    expect(
      startDuck(candidateThreshold: 0.045, level: 0.05).type,
      VoiceBargeInActionType.duck,
    );
    enterListening();

    expect(feed(0.05, 100), isEmpty);
    expect(feed(0.02, 100), isEmpty);
    expect(feed(0.05, 100), isEmpty);
    expect(feed(0.02, 100), isEmpty);
    final confirm = feed(0.05, 100);
    expect(confirm.single.type, VoiceBargeInActionType.confirm);
  });

  test('duck 后静音复核只有底噪时恢复', () {
    expect(
      startDuck(candidateThreshold: 0.045, level: 0.05).type,
      VoiceBargeInActionType.duck,
    );
    expect(feed(0.02, 100), isEmpty);
    final listen = feed(0.02, 100);
    expect(listen.single.type, VoiceBargeInActionType.listen);
    expect(feed(0.02, 100), isEmpty);
    expect(feed(0.02, 100), isEmpty);

    final resume = feed(0.02, 510);
    expect(resume.single.type, VoiceBargeInActionType.resume);
    expect(guard.isConfirmed, isFalse);
  });

  test('低于候选门限的底噪不会触发 duck', () {
    guard.onPlaybackStarted(candidateThreshold: 0.2);
    for (var i = 0; i < 8; i++) {
      expect(feed(0.03, 100), isEmpty);
    }
    expect(guard.isDucking, isFalse);
  });

  test('停止播放时若在 duck 阶段必须恢复音量', () {
    expect(
      startDuck(candidateThreshold: 0.2, level: 0.3).type,
      VoiceBargeInActionType.duck,
    );
    final resume = guard.onPlaybackStopped();
    expect(resume.single.type, VoiceBargeInActionType.resume);
    expect(guard.isDucking, isFalse);
  });

  test('停止播放时若在静音复核阶段也必须恢复音量', () {
    expect(
      startDuck(candidateThreshold: 0.2, level: 0.3).type,
      VoiceBargeInActionType.duck,
    );
    expect(feed(0.3, 100), isEmpty);
    final listen = feed(0.3, 100);
    expect(listen.single.type, VoiceBargeInActionType.listen);
    expect(guard.isListening, isTrue);

    final resume = guard.onPlaybackStopped();
    expect(resume.single.type, VoiceBargeInActionType.resume);
    expect(guard.isListening, isFalse);
  });
}
