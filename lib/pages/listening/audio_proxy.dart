import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Streams audio through localhost and keeps complete responses for later plays.
class ListeningAudioProxy {
  static const _maxCacheBytes = 512 * 1024 * 1024;
  final HttpServer _server;
  final HttpClient _client;
  final Uri upstream;
  final void Function(int) onBytes;
  final String userAgent;
  final File _cacheFile;
  bool _closed = false;
  bool _cacheRead = false;
  ListeningAudioProxy._(
    this._server,
    this._client,
    this.upstream,
    this.onBytes,
    this.userAgent,
    this._cacheFile,
  ) {
    _server.listen((request) => unawaited(_serve(request)));
  }

  static Future<ListeningAudioProxy> create(
    Uri upstream,
    void Function(int) onBytes, {
    required String userAgent,
    required String cacheKey,
  }) async {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}listening_audio',
    );
    await directory.create(recursive: true);
    await _pruneCache(directory);
    final safeKey = base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');
    final cacheFile = File('${directory.path}${Platform.pathSeparator}$safeKey.audio');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 15);
    return ListeningAudioProxy._(
      server,
      client,
      upstream,
      onBytes,
      userAgent,
      cacheFile,
    );
  }

  static Future<void> _pruneCache(Directory directory) async {
    try {
      final files = <File>[];
      var totalBytes = 0;
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        totalBytes += stat.size;
        files.add(entity);
      }
      if (totalBytes <= _maxCacheBytes) return;
      files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      for (final file in files) {
        if (totalBytes <= _maxCacheBytes * 3 ~/ 4) break;
        totalBytes -= (await file.length());
        await file.delete();
      }
    } catch (_) {
      // Cache cleanup must never prevent audio playback.
    }
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
      if (!_cacheRead && await _cacheFile.exists()) {
        _cacheRead = await _cacheFile.length() > 0;
      }
      if (_cacheRead) {
        await _serveCached(incoming);
        return;
      }
      await _serveUpstream(incoming);
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        response.detachSocket().then((socket) => socket.destroy()).catchError((_) {});
      }
    }
  }

  Future<void> _serveCached(HttpRequest incoming) async {
    final response = incoming.response;
    final length = await _cacheFile.length();
    var start = 0;
    var end = length - 1;
    final range = incoming.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      final from = match[1] ?? '';
      final to = match[2] ?? '';
      if (from.isEmpty) {
        final suffix = int.tryParse(to) ?? 0;
        start = (length - suffix).clamp(0, length);
      } else {
        start = int.tryParse(from) ?? length;
        if (to.isNotEmpty) end = int.tryParse(to) ?? end;
      }
      if (start >= length || end < start) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      end = end.clamp(0, length - 1);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
    }
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'audio/*')
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentLengthHeader, end - start + 1);
    response.bufferOutput = false;
    if (incoming.method == 'GET') {
      await for (final chunk in _cacheFile.openRead(start, end + 1)) {
        if (_closed) break;
        response.add(chunk);
        await response.flush();
      }
    }
    await response.close();
    await _cacheFile.setLastModified(DateTime.now());
  }

  Future<void> _serveUpstream(HttpRequest incoming) async {
    final response = incoming.response;
    final request = await _client.openUrl(incoming.method, upstream);
    request.headers
      ..set(HttpHeaders.userAgentHeader, userAgent)
      ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com/');
    // Fetch one complete representation so later playback and seeks are local.
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
    if (incoming.method == 'HEAD') {
      await response.close();
      return;
    }

    File? partialFile;
    IOSink? cacheSink;
    if (remote.statusCode == HttpStatus.ok &&
        remote.headers.value(HttpHeaders.contentRangeHeader) == null) {
      partialFile = File('${_cacheFile.path}.part');
      try {
        cacheSink = partialFile.openWrite();
      } catch (_) {
        partialFile = null;
      }
    }
    await for (final chunk in remote) {
      if (_closed) break;
      onBytes(chunk.length);
      cacheSink?.add(chunk);
      response.add(chunk);
      await response.flush();
    }
    await response.close();
    if (cacheSink != null && partialFile != null && !_closed) {
      try {
        await cacheSink.flush();
        await cacheSink.close();
        await partialFile.rename(_cacheFile.path);
        _cacheRead = true;
      } catch (_) {
        await cacheSink.close();
        if (await partialFile.exists()) await partialFile.delete();
      }
    } else {
      await cacheSink?.close();
      if (partialFile != null && await partialFile.exists()) await partialFile.delete();
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
