import 'package:echo_loop/features/ai_speaking/services/voice_barge_in_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  VoiceBargeInGuard createGuard() => VoiceBargeInGuard(
    now: () => now,
    minPlaybackBeforeCandidate: const Duration(milliseconds: 300),
    candidateHold: const Duration(milliseconds: 90),
    confirmHold: const Duration(milliseconds: 250),
    resumeHold: const Duration(milliseconds: 500),
    maxDuckDuration: const Duration(seconds: 2),
  );

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
  });

  test('持续人声先 duck，确认期仍有人声才打断', () {
    final guard = createGuard()..onPlaybackStarted(candidateThreshold: 0.2);
    guard.onInputFrame(0.3);

    now = now.add(const Duration(milliseconds: 320));
    final duck = guard.onInputFrame(0.3);
    expect(duck.single.type, VoiceBargeInActionType.duck);
    expect(duck.single.volume, 0.12);
    expect(guard.isDucking, isTrue);

    // duck 后先让 AEC 收敛，残留电平明显低于原峰值，再出现人声才确认。
    now = now.add(const Duration(milliseconds: 100));
    guard.onInputFrame(0.02);
    now = now.add(const Duration(milliseconds: 100));
    guard.onInputFrame(0.02);
    now = now.add(const Duration(milliseconds: 260));
    guard.onInputFrame(0.3);
    now = now.add(const Duration(milliseconds: 260));
    final confirm = guard.onInputFrame(0.3);
    expect(confirm.single.type, VoiceBargeInActionType.confirm);
    expect(guard.isConfirmed, isTrue);
  });

  test('duck 后声音衰减判定为回声并恢复音量', () {
    final guard = createGuard()..onPlaybackStarted(candidateThreshold: 0.2);
    guard.onInputFrame(0.3);
    now = now.add(const Duration(milliseconds: 320));
    guard.onInputFrame(0.3);

    now = now.add(const Duration(milliseconds: 100));
    guard.onInputFrame(0);
    expect(guard.isConfirmed, isFalse);
    expect(guard.isDucking, isTrue);

    // 第二个采样点越过 180ms 收敛窗口，随后静音满 500ms 才恢复。
    now = now.add(const Duration(milliseconds: 100));
    guard.onInputFrame(0);
    now = now.add(const Duration(milliseconds: 510));
    final resume = guard.onInputFrame(0);
    expect(resume.single.type, VoiceBargeInActionType.resume);
    expect(guard.isDucking, isFalse);
  });

  test('duck 后回声没有下降时关闭插话而不是确认', () {
    final guard = createGuard()..onPlaybackStarted(candidateThreshold: 0.2);
    guard.onInputFrame(0.3);
    now = now.add(const Duration(milliseconds: 320));
    final duck = guard.onInputFrame(0.3);
    expect(duck.single.type, VoiceBargeInActionType.duck);

    now = now.add(const Duration(milliseconds: 100));
    guard.onInputFrame(0.3);
    now = now.add(const Duration(milliseconds: 100));
    final disable = guard.onInputFrame(0.3);
    expect(disable.single.type, VoiceBargeInActionType.disable);
    expect(guard.isDucking, isFalse);
    expect(guard.isConfirmed, isFalse);
  });

  test('停止播放时若仍在 duck 必须恢复音量', () {
    final guard = createGuard()..onPlaybackStarted(candidateThreshold: 0.2);
    guard.onInputFrame(0.3);
    now = now.add(const Duration(milliseconds: 320));
    guard.onInputFrame(0.3);

    final resume = guard.onPlaybackStopped();
    expect(resume.single.type, VoiceBargeInActionType.resume);
    expect(guard.isDucking, isFalse);
  });

  test('低于候选门限的底噪不会触发 duck', () {
    final guard = createGuard()..onPlaybackStarted(candidateThreshold: 0.2);
    for (var i = 0; i < 8; i++) {
      now = now.add(const Duration(milliseconds: 100));
      expect(guard.onInputFrame(0.03), isEmpty);
    }
    expect(guard.isDucking, isFalse);
  });
}
