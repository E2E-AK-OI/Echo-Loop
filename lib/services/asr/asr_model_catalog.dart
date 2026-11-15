/// ASR 模型发布规格目录。
///
/// 静态资源 CDN 路径、归档摘要、预计流量和解压后关键文件只在本文件维护；
/// 下载与安装行为由 ASR 专属归档安装器负责。
library;

/// 所有 Whisper 模型共享的 VAD 资源 ID。
const vadModelId = 'silero-vad';

/// SenseVoice Small 多语种模型的资源 ID（口语特级档使用）。
const senseVoiceSmallModelId = 'sense-voice-small-int8';

/// 直链下载的单个模型文件。
class AsrModelFileDownload {
  const AsrModelFileDownload({
    required this.fileName,
    required this.uri,
    required this.sha256,
    required this.sizeBytes,
  });

  final String fileName;
  final String uri;
  final String sha256;
  final int sizeBytes;
}

class AsrModelResourceSpec {
  const AsrModelResourceSpec({
    required this.id,
    this.archivePath = '',
    this.sha256 = '',
    required this.estimatedDownloadBytes,
    required this.requiredFiles,
    this.dependencies = const [],
    this.files = const [],
  });

  final String id;
  final String archivePath;
  final String sha256;
  final int estimatedDownloadBytes;
  final List<String> requiredFiles;
  final List<String> dependencies;

  /// 非空表示该资源由若干直链文件组成，而不是一个 CDN 归档。
  final List<AsrModelFileDownload> files;

  bool get isDirect => files.isNotEmpty;
}

const asrModelResourceCatalog = <String, AsrModelResourceSpec>{
  vadModelId: AsrModelResourceSpec(
    id: vadModelId,
    archivePath: 'asr/silero-vad-v1.zip',
    sha256: 'e7ae67c1610b5ef8d1f00d2e0e42e833ced8d3bc22f8e59a809d36616028f5e2',
    estimatedDownloadBytes: 508294,
    requiredFiles: ['silero_vad.onnx'],
  ),
  'whisper-tiny-en-int8': AsrModelResourceSpec(
    id: 'whisper-tiny-en-int8',
    archivePath: 'asr/whisper-tiny-en-int8-v1.zip',
    sha256: '251f653212befd7fa0318cca2ff0ce4f71804581aad387ba88bc7c85f9eb5dc3',
    estimatedDownloadBytes: 62337248,
    requiredFiles: [
      'tiny.en-encoder.int8.onnx',
      'tiny.en-decoder.int8.onnx',
      'tiny.en-tokens.txt',
    ],
    dependencies: [vadModelId],
  ),
  'whisper-base-en-int8': AsrModelResourceSpec(
    id: 'whisper-base-en-int8',
    archivePath: 'asr/whisper-base-en-int8-v1.zip',
    sha256: 'ff8af5965f6d017ad317e9a7c023c3f457259cef3de33e543c2fa87338a32fbb',
    estimatedDownloadBytes: 95051629,
    requiredFiles: [
      'base.en-encoder.int8.onnx',
      'base.en-decoder.int8.onnx',
      'base.en-tokens.txt',
    ],
    dependencies: [vadModelId],
  ),
  'whisper-small-en-int8': AsrModelResourceSpec(
    id: 'whisper-small-en-int8',
    archivePath: 'asr/whisper-small-en-int8-v1.zip',
    sha256: '33f80b3bbc4871daaeb57376c0629bf868443ab95b0a71e9970da09c163eeed9',
    estimatedDownloadBytes: 228206095,
    requiredFiles: [
      'small.en-encoder.int8.onnx',
      'small.en-decoder.int8.onnx',
      'small.en-tokens.txt',
    ],
    dependencies: [vadModelId],
  ),
  // SenseVoice 官方仓库只提供原始 ONNX 与词表，没有可直接安装的 CDN 归档，
  // 因此按文件直链下载；SHA-256 来自 HuggingFace LFS 元数据与本地实测。
  senseVoiceSmallModelId: AsrModelResourceSpec(
    id: senseVoiceSmallModelId,
    estimatedDownloadBytes: 239549735,
    requiredFiles: ['model.int8.onnx', 'tokens.txt'],
    dependencies: [vadModelId],
    files: [
      AsrModelFileDownload(
        fileName: 'model.int8.onnx',
        uri: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
        sha256:
            'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
        sizeBytes: 239233841,
      ),
      AsrModelFileDownload(
        fileName: 'tokens.txt',
        uri: 'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
        sha256:
            'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
        sizeBytes: 315894,
      ),
    ],
  ),
};
