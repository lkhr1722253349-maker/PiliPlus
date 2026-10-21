import 'dart:io';

import 'package:PiliPlus/pages/listening/audio_proxy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The proxy resolves an application support directory through a platform
  // channel, so the binding must exist and the channel must answer.
  // `HttpOverrides.global = null` keeps real loopback sockets working, which
  // the test binding would otherwise stub out with HTTP 400.
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory support;
  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('piliplus-proxy-');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationSupportDirectory'
          ? support.path
          : null,
    );
  });
  tearDownAll(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (support.existsSync()) await support.delete(recursive: true);
  });
  test('audio proxy preserves ranges and counts downloaded bytes including rereads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final payload = List.generate(8192, (i) => i % 256);
    final ranges = <String?>[];
    server.listen((request) async {
      expect(request.headers.value('referer'), 'https://www.bilibili.com/');
      ranges.add(request.headers.value('range'));
      final response = request.response;
      response.headers.contentType = ContentType('audio', 'mp4');
      if (request.headers.value('range') == 'bytes=2048-4095') {
        response.statusCode = 206;
        response.headers.set('content-range', 'bytes 2048-4095/8192');
        response.contentLength = 2048;
        response.add(payload.sublist(2048, 4096));
      } else {
        response.contentLength = payload.length;
        if (request.method != 'HEAD') response.add(payload);
      }
      await response.close();
    });
    var bytes = 0;
    final proxy = await ListeningAudioProxy.create(
      Uri.parse('http://127.0.0.1:${server.port}/test'),
      (count) => bytes += count,
      userAgent: 'Test',
      cacheKey: 'test-cache-key',
    );
    final client = HttpClient();
    try {
      final first = await (await client.getUrl(Uri.parse(proxy.url))).close();
      expect((await first.expand((e) => e).toList()), payload);
      expect(bytes, 8192);
      final request = await client.getUrl(Uri.parse(proxy.url));
      request.headers.set('range', 'bytes=2048-4095');
      final second = await request.close();
      expect(second.statusCode, 206);
      expect(second.headers.value('content-range'), 'bytes 2048-4095/8192');
      expect(
        await second.expand((e) => e).toList(),
        payload.sublist(2048, 4096),
      );
      // The first response cached the whole body, so the ranged read is served
      // from the local file and adds no network bytes.
      expect(bytes, 8192);
      final head = await (await client.headUrl(Uri.parse(proxy.url))).close();
      await head.drain<void>();
      expect(bytes, 8192);
      expect(ranges, [null]);
    } finally {
      client.close(force: true);
      await proxy.close();
      await server.close(force: true);
    }
  });
  test('traffic units scale with downloaded bytes', () {
    expect(formatAudioBytes(0), '0 B');
    expect(formatAudioBytes(1024), '1.0 KB');
    expect(formatAudioBytes(1024 * 1024), '1.0 MB');
  });
}
