import 'package:echo_loop/features/ai_speaking/services/echo_text_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('识别文本与刚朗读的句子相同时判定为回声', () {
    final filter = EchoTextFilter()..updateTtsText('Hello there, how are you?');

    expect(filter.isLikelyEcho('how are you'), isTrue);
    expect(filter.isLikelyEcho('HELLO THERE'), isTrue);
    expect(filter.isLikelyEcho('I am fine, thank you'), isFalse);
  });

  test('中文标点和空白差异不影响回声匹配', () {
    final filter = EchoTextFilter()..updateTtsText('今天天气很好，我们出去走走吧。');

    expect(filter.isLikelyEcho('今天天气很好'), isTrue);
    expect(filter.isLikelyEcho('我们出去走走'), isTrue);
    expect(filter.isLikelyEcho('我想学习英语'), isFalse);
  });

  test('只匹配短英文单词时要求至少三个字母', () {
    final filter = EchoTextFilter()..updateTtsText('I am here');

    expect(filter.isLikelyEcho('am'), isFalse);
    expect(filter.isLikelyEcho('here'), isTrue);
  });

  test('清空后不再匹配旧朗读文本', () {
    final filter = EchoTextFilter()..updateTtsText('Hello there');

    filter.clear();

    expect(filter.isLikelyEcho('Hello there'), isFalse);
  });
}
