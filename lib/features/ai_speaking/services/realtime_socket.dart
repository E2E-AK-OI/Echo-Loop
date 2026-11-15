/// 阿里云实时语音服务（实时识别 / 语音到语音）共用的 WebSocket 抽象。
///
/// 单独抽出来是为了让协议客户端不直接依赖 dart:io，单元测试可以注入
/// 可控的假连接，按需推送服务端事件。
library;

import 'dart:io';

abstract class RealtimeSocket {
  Stream<dynamic> get messages;

  void add(dynamic data);

  Future<void> close();
}

typedef WebSocketConnector = Future<RealtimeSocket> Function(
  String url, {
  Map<String, dynamic>? headers,
});

/// 默认连接器：直接使用 dart:io 的 WebSocket。
Future<RealtimeSocket> connectRealtimeSocket(
  String url, {
  Map<String, dynamic>? headers,
}) async {
  final socket = await WebSocket.connect(url, headers: headers);
  return _IoRealtimeSocket(socket);
}

class _IoRealtimeSocket implements RealtimeSocket {
  _IoRealtimeSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  void add(dynamic data) => _socket.add(data);

  @override
  Future<void> close() => _socket.close();
}
