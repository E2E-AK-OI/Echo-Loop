/// TTS 回声文本过滤。
///
/// 平台 AEC 后仍可能有少量 TTS 音频进入 ASR。这里保留最近两段 TTS 文本的
/// 归一化结果，若识别文本是其中一段的前缀/子串，或全部由其中出现过的
/// 英文词组成（至少一个长度足够的词），则判定为回声。真正的用户插话只要
/// 包含 TTS 文本之外的词，就不会被误伤。
class EchoTextFilter {
  String? _previous;
  String? _current;

  /// 结束一段回声窗口，避免很久以前的朗读文本误伤后续正常发言。
  void clear() {
    _previous = null;
    _current = null;
  }

  void updateTtsText(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return;
    _previous = _current;
    _current = normalized;
  }

  bool isLikelyEcho(String transcript) {
    final candidate = _normalize(transcript);
    if (candidate.isEmpty) return false;
    for (final source in <String?>[_current, _previous]) {
      if (source == null || source.isEmpty) continue;
      // 英文两个字母的片段太容易误伤（如 am/is），中文两字仍可能是有效回声。
      final minSubstringLength = RegExp(r'^[a-z0-9 ]+$').hasMatch(candidate)
          ? 3
          : 2;
      if (candidate.length >= minSubstringLength &&
          source.contains(candidate)) {
        return true;
      }
      if (_containsLongToken(source, candidate)) {
        return true;
      }
    }
    return false;
  }

  bool _containsLongToken(String source, String candidate) {
    final sourceWords = source.split(' ');
    var hasLongWord = false;
    for (final word in candidate.split(' ')) {
      if (word.isEmpty) continue;
      if (word.length >= 3) hasLongWord = true;
      if (!sourceWords.contains(word)) {
        // 用户回答里出现任何 TTS 之外的词，就不能仅凭公共词判成回声。
        return false;
      }
    }
    return hasLongWord;
  }

  String _normalize(String text) {
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      final isAscii =
          (rune >= 0x30 && rune <= 0x39) || (rune >= 0x61 && rune <= 0x7a);
      final isCjk = rune >= 0x4e00 && rune <= 0x9fff;
      if (isAscii || isCjk) {
        buffer.writeCharCode(rune);
      } else {
        buffer.write(' ');
      }
    }
    return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
  }
}
