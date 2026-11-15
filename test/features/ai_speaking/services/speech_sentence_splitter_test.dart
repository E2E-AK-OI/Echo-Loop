/// 流式回复分句器单元测试。
///
/// 覆盖句末确认、首句提前切分、缩写/小数/省略号保护和 Markdown 清理。
library;

import 'package:echo_loop/features/ai_speaking/services/speech_sentence_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('跨 delta 攒成完整句子后再输出', () {
    final splitter = SpeechSentenceSplitter();

    expect(splitter.add('Hello'), isEmpty);
    expect(splitter.add(' the'), isEmpty);
    expect(splitter.add('re. How'), <String>['Hello there.']);
    expect(splitter.add(' are you?'), <String>['How are you?']);
    expect(splitter.flush(), isEmpty);
  });

  test('缩写、小数与省略号不会被误判为句末', () {
    final splitter = SpeechSentenceSplitter();

    expect(splitter.add('Dr. Smith'), isEmpty);
    expect(splitter.add(' is here. Next'), <String>['Dr. Smith is here.']);
    expect(splitter.add(' one. Pi is 3.14. '), <String>[
      'Next one.',
      'Pi is 3.14.',
    ]);
    expect(splitter.add('Wait...'), isEmpty);
    expect(splitter.flush(), <String>['Wait...']);
  });

  test('首句在足够长的逗号处提前切分', () {
    final splitter = SpeechSentenceSplitter();

    expect(
      splitter.add(
        'This is a fairly long first clause with many more words in it, and the rest follows later.',
      ),
      <String>[
        'This is a fairly long first clause with many more words in it,',
      ],
    );
    expect(splitter.flush(), <String>['and the rest follows later.']);
  });

  test('中文句末标点立即断句', () {
    final splitter = SpeechSentenceSplitter();

    expect(splitter.add('你好。'), <String>['你好。']);
    expect(splitter.add('世界！'), <String>['世界！']);
  });

  test('长时间没有标点时按长度兜底切分', () {
    final splitter = SpeechSentenceSplitter();
    final chunks = splitter.add('a' * 230);

    expect(chunks, hasLength(1));
    expect(chunks.single, hasLength(220));
    expect(splitter.flush().single, hasLength(10));
  });

  test('清理 Markdown 标记后再送去合成', () {
    final splitter = SpeechSentenceSplitter();

    expect(splitter.add('## Hello **world**! '), <String>['Hello world!']);
  });
}
