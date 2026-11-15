/// 把大模型流式回复切成适合语音合成的短句。
///
/// LLM 的 delta 可能把单词、标点切在任意位置，因此不能按 delta 直接合成。
/// 这里维护缓冲区，遇到句末标点或段落换行才输出；首句额外允许在逗号处
/// 提前切分，让第一段音频不必等整句话生成完。缩写、小数和省略号不会被
/// 误判为句末。
class SpeechSentenceSplitter {
  String _buffer = '';
  bool _emittedFirst = false;

  /// 单个合成块的安全长度，避免模型迟迟不输出标点时无限增长。
  static const _maxChunkLength = 220;

  static const _abbreviations = <String>{
    'mr',
    'mrs',
    'ms',
    'dr',
    'prof',
    'st',
    'jr',
    'sr',
    'vs',
    'etc',
  };

  /// 追加一段流式文本，返回本次可以送去合成的完整句子。
  List<String> add(String delta) {
    if (delta.isEmpty) return const <String>[];
    _buffer += delta;
    return _drain();
  }

  /// 回复结束时输出缓冲区里的剩余文本。
  List<String> flush() {
    final text = _clean(_buffer);
    _buffer = '';
    if (text.isEmpty) return const <String>[];
    _emittedFirst = true;
    return <String>[text];
  }

  List<String> _drain() {
    final chunks = <String>[];
    while (true) {
      final text = _buffer;
      if (text.trim().isEmpty) {
        _buffer = '';
        break;
      }
      var splitAt = _findSentenceBoundary(text);
      if (splitAt < 0) {
        splitAt = _findEarlyBoundary(text);
      }
      if (splitAt < 0) break;
      final cleaned = _clean(text.substring(0, splitAt));
      _buffer = text.substring(splitAt).trimLeft();
      if (cleaned.isEmpty) continue;
      chunks.add(cleaned);
      _emittedFirst = true;
    }
    return chunks;
  }

  /// 返回句末标点之后的下标；没有确认的句末返回 -1。
  int _findSentenceBoundary(String text) {
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '\n') return i;
      if (char != '.' &&
          char != '!' &&
          char != '?' &&
          char != '。' &&
          char != '！' &&
          char != '？') {
        continue;
      }
      if (char == '.' && _isNonBoundaryDot(text, i)) continue;

      var end = i + 1;
      while (end < text.length && _isClosingQuote(text[end])) {
        end++;
      }
      // 中文标点本身就足够明确；英文句号可能只是缩写或省略号的一部分，
      // 等下一个 delta 到了再确认。
      final isCjk = char == '。' || char == '！' || char == '？';
      if (isCjk) return end;
      if (end >= text.length) {
        // 感叹号和问号不会像句号那样被缩写复用，可以直接断句。
        return char == '.' ? -1 : end;
      }
      if (text[end].trim().isEmpty) return end;
    }
    return -1;
  }

  /// 首句在逗号处提前切分；后续句子只在超长时按空白兜底切分。
  int _findEarlyBoundary(String text) {
    if (!_emittedFirst) {
      var lastComma = -1;
      for (var i = 0; i < text.length; i++) {
        if (text[i] == ',' ||
            text[i] == '，' ||
            text[i] == ';' ||
            text[i] == '；') {
          lastComma = i;
        }
      }
      if (lastComma >= 0) {
        final prefix = text.substring(0, lastComma);
        if (_wordCount(prefix) >= 12 || _cjkCount(prefix) >= 24) {
          return lastComma + 1;
        }
      }
    }
    if (text.length < _maxChunkLength) return -1;
    var splitAt = _maxChunkLength;
    for (var i = _maxChunkLength - 1; i >= 0; i--) {
      if (text[i].trim().isEmpty || text[i] == ',' || text[i] == '，') {
        splitAt = i + 1;
        break;
      }
    }
    return splitAt;
  }

  bool _isNonBoundaryDot(String text, int index) {
    // 小数：3.14
    if (index > 0 &&
        index + 1 < text.length &&
        _isDigit(text[index - 1]) &&
        _isDigit(text[index + 1])) {
      return true;
    }
    // 省略号：...，等连续的点都留在同一段里。
    if (index + 1 < text.length && text[index + 1] == '.') return true;

    var start = index - 1;
    while (start >= 0 && _isWordChar(text[start])) {
      start--;
    }
    final word = text.substring(start + 1, index).toLowerCase();
    if (_abbreviations.contains(word)) return true;
    // 单个大写字母通常是姓名缩写，例如 J. K. Rowling。
    if (word.length == 1 && _isAsciiLetter(word)) return true;
    return false;
  }

  int _wordCount(String text) {
    return RegExp(r"[A-Za-z0-9']+").allMatches(text).length;
  }

  int _cjkCount(String text) {
    return RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
  }

  String _clean(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    text = text.replaceAll(RegExp(r'```[A-Za-z0-9]*'), ' ');
    text = text.replaceAll('`', '');
    text = text.replaceAll(RegExp(r'\*\*|__'), '');
    text = text.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+'), '');
    text = text.replaceAll(RegExp(r'^\s*[-*•]\s+'), '');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    return text.trim();
  }

  bool _isClosingQuote(String char) =>
      char == '"' || char == "'" || char == '”' || char == '’' || char == ')';

  bool _isDigit(String char) =>
      char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;

  bool _isAsciiLetter(String text) {
    final code = text.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  bool _isWordChar(String char) {
    final code = char.codeUnitAt(0);
    return _isAsciiLetter(char) || _isDigit(char) || code == 39 || code == 45;
  }
}
