import 'dart:async';
import 'dart:io';

/// Counts the audio response body, including prefetches and repeated ranges.
/// It deliberately excludes artwork, API calls and transport headers.
class ListeningAudioProxy {
  final HttpServer _server;
  final HttpClient _client;
  final Uri upstream;
  final void Function(int) onBytes;
  final String userAgent;
  bool _closed = false;
  ListeningAudioProxy._(
    this._server,
    this._client,
    this.upstream,
    this.onBytes,
    this.userAgent,
  ) {
    _server.listen((request) => unawaited(_serve(request)));
  }
  static Future<ListeningAudioProxy> create(
    Uri upstream,
    void Function(int) onBytes, {
    required String userAgent,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 15);
    return ListeningAudioProxy._(server, client, upstream, onBytes, userAgent);
  }

  String get url => 'http://127.0.0.1:${_server.port}/audio';
  Future<void> _serve(HttpRequest incoming) async {
    final response = incoming.response;
    try {
      if (incoming.uri.path != '/audio' ||
          !['GET', 'HEAD'].contains(incoming.method)) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final request = await _client.openUrl(incoming.method, upstream);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      for (final name in ['range', 'if-range']) {
        final value = incoming.headers.value(name);
        if (value != null) request.headers.set(name, value);
      }
      final remote = await request.close();
      response.statusCode = remote.statusCode;
      response.bufferOutput = false;
      for (final name in [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'content-encoding',
      ]) {
        final value = remote.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      await for (final chunk in remote) {
        if (_closed) break;
        if (incoming.method != 'HEAD') {
          onBytes(chunk.length);
          response.add(chunk);
          await response.flush();
        }
      }
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        response
            .detachSocket()
            .then((socket) => socket.destroy())
            .catchError((_) {});
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _client.close(force: true);
    await _server.close(force: true);
  }
}

String formatAudioBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024)
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
