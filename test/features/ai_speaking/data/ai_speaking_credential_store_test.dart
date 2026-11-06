/// AI 口语 API Key 安全存储测试。
///
/// 覆盖读写往返、不同供应商隔离、删除、损坏文档与安全存储异常。
library;

import 'package:echo_loop/features/ai_speaking/data/ai_speaking_credential_store.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_llm_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockSecureStorage storage;
  late AiSpeakingCredentialStore store;

  setUp(() {
    storage = _MockSecureStorage();
    store = AiSpeakingCredentialStore(storage: storage);
  });

  void stubRead(String? value) {
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => value);
  }

  group('AiSpeakingCredentialStore', () {
    test('空存储读取两个 Key 都返回 null', () async {
      stubRead(null);

      expect(await store.readLlmApiKey(AiLlmProvider.deepSeek), isNull);
      expect(await store.readDashscopeApiKey(), isNull);
    });

    test('写入后能读取大模型 Key，并保留 DashScope Key', () async {
      String? saved;
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        saved = invocation.namedArguments[const Symbol('value')] as String?;
      });
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => saved);

      await store.writeLlmApiKey(AiLlmProvider.deepSeek, ' llm-key ');
      await store.writeDashscopeApiKey('dash-key');

      expect(await store.readLlmApiKey(AiLlmProvider.deepSeek), 'llm-key');
      expect(await store.readDashscopeApiKey(), 'dash-key');
      expect(await store.readLlmApiKey(AiLlmProvider.openAi), isNull);
    });

    test('不同供应商的 Key 相互隔离', () async {
      String? saved;
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        saved = invocation.namedArguments[const Symbol('value')] as String?;
      });
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => saved);

      await store.writeLlmApiKey(AiLlmProvider.deepSeek, 'deepseek-key');
      await store.writeLlmApiKey(AiLlmProvider.openAi, 'openai-key');

      expect(await store.readLlmApiKey(AiLlmProvider.deepSeek), 'deepseek-key');
      expect(await store.readLlmApiKey(AiLlmProvider.openAi), 'openai-key');
    });

    test('删除大模型 Key 只移除对应供应商', () async {
      String? saved;
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        saved = invocation.namedArguments[const Symbol('value')] as String?;
      });
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => saved);

      await store.writeLlmApiKey(AiLlmProvider.deepSeek, 'deepseek-key');
      await store.writeLlmApiKey(AiLlmProvider.openAi, 'openai-key');
      await store.deleteLlmApiKey(AiLlmProvider.deepSeek);

      expect(await store.readLlmApiKey(AiLlmProvider.deepSeek), isNull);
      expect(await store.readLlmApiKey(AiLlmProvider.openAi), 'openai-key');
    });

    test('损坏 JSON 抛 parseFailed', () async {
      stubRead('{bad');

      expect(
        store.readLlmApiKey(AiLlmProvider.deepSeek),
        throwsA(
          isA<AiSpeakingCredentialStoreException>().having(
            (error) => error.kind,
            'kind',
            AiSpeakingCredentialErrorKind.parseFailed,
          ),
        ),
      );
    });

    test('readStatus 对损坏文档返回未配置', () async {
      stubRead('{bad');

      final status = await store.readStatus(AiLlmProvider.deepSeek);

      expect(status.hasLlmApiKey, isFalse);
      expect(status.hasDashscopeApiKey, isFalse);
    });

    test('安全存储读取异常映射为 readFailed', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenThrow(PlatformException(code: 'storage_error', message: 'boom'));

      expect(
        store.readLlmApiKey(AiLlmProvider.deepSeek),
        throwsA(
          isA<AiSpeakingCredentialStoreException>().having(
            (error) => error.kind,
            'kind',
            AiSpeakingCredentialErrorKind.readFailed,
          ),
        ),
      );
    });

    test('写入空 Key 走删除而不是保存空字符串', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      when(() => storage.delete(key: any(named: 'key')))
          .thenAnswer((_) async {});

      await store.writeLlmApiKey(AiLlmProvider.deepSeek, '   ');

      verify(() => storage.delete(key: any(named: 'key'))).called(1);
    });

    test('写入时安全存储异常映射为 writeFailed', () async {
      stubRead(null);
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenThrow(PlatformException(code: 'storage_error'));

      expect(
        store.writeLlmApiKey(AiLlmProvider.deepSeek, 'key'),
        throwsA(
          isA<AiSpeakingCredentialStoreException>().having(
            (error) => error.kind,
            'kind',
            AiSpeakingCredentialErrorKind.writeFailed,
          ),
        ),
      );
    });
  });
}
