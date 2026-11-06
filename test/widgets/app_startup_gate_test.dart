import 'dart:async';

import 'package:echo_loop/providers/startup_bootstrap_provider.dart';
import 'package:echo_loop/widgets/app_startup_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/mock_providers.dart';

void main() {
  testWidgets('品牌页保持到本地数据启动完成', (tester) async {
    final localGate = Completer<StartupReport>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: dedupeOverrides([
          localStartupProvider.overrideWith(
            () => _DelayedLocalStartupController(localGate),
          ),
        ]),
        child: const MaterialApp(
          home: AppStartupGate(
            splashScreen: Text('startup splash'),
            child: Text('business route'),
          ),
        ),
      ),
    );

    expect(find.text('startup splash'), findsOneWidget);
    expect(find.text('business route'), findsNothing);

    localGate.complete(const StartupReport([]));
    await tester.pump();

    expect(find.text('startup splash'), findsNothing);
    expect(find.text('business route'), findsOneWidget);
  });

  testWidgets('本地启动失败时进入降级页面', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: dedupeOverrides([
          localStartupProvider.overrideWith(_FailedLocalStartupController.new),
        ]),
        child: const MaterialApp(
          home: AppStartupGate(
            splashScreen: Text('startup splash'),
            child: Text('degraded route'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('startup splash'), findsNothing);
    expect(find.text('degraded route'), findsOneWidget);
  });
}

class _DelayedLocalStartupController extends LocalStartupController {
  _DelayedLocalStartupController(this.gate);

  final Completer<StartupReport> gate;

  @override
  Future<StartupReport> build() => gate.future;
}

class _FailedLocalStartupController extends LocalStartupController {
  @override
  Future<StartupReport> build() async => throw StateError('database failed');
}
