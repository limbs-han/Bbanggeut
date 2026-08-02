import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/fast_downloader.dart';

/// 여러 연결로 나눠 받는 다운로더.
///
/// 여기서 지키려는 것은 속도가 아니라 **어떤 서버를 만나도 파일이 온전하다**는
/// 점이다. Range를 제대로 주는 서버, 무시하는 서버, 반쪽만 주면서 전체 크기를
/// 안 알려주는 서버를 각각 세워 확인한다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List payload;
  late Directory workspace;

  setUp(() {
    // 5MiB. 첫 조각(1MiB) 뒤에 병렬 구간이 실제로 생기는 크기다.
    payload = Uint8List.fromList(
      List.generate(5 * 1024 * 1024, (index) => index % 256),
    );
    workspace = Directory.systemTemp.createTempSync('fast-download-test-');
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    addTearDown(() => workspace.deleteSync(recursive: true));
  });

  Future<HttpServer> serve(
    void Function(HttpRequest request, String? range) handle,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      handle(request, request.headers.value(HttpHeaders.rangeHeader));
      await request.response.close();
    });
    return server;
  }

  String urlOf(HttpServer server) =>
      'http://${server.address.host}:${server.port}/object/video.mp4';

  test('Range를 지원하는 서버에서는 구간을 나눠 받고 원본과 같은 파일을 남긴다', () async {
    var partialResponses = 0;
    final server = await serve((request, range) {
      if (range == null) {
        request.response.contentLength = payload.length;
        request.response.add(payload);
        return;
      }
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      final start = int.parse(match.group(1)!);
      final requestedEnd = match.group(2)!;
      final end = requestedEnd.isEmpty
          ? payload.length - 1
          : math.min(int.parse(requestedEnd), payload.length - 1);
      partialResponses++;
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes $start-$end/${payload.length}',
      );
      request.response.contentLength = end - start + 1;
      request.response.add(Uint8List.sublistView(payload, start, end + 1));
    });

    final destination = '${workspace.path}/ranged.mp4';
    var lastReceived = 0;
    var lastTotal = 0;
    var reports = 0;
    await FastDownloader.download(
      urlOf(server),
      destination,
      onReceiveProgress: (received, total) {
        reports++;
        lastReceived = received;
        lastTotal = total;
      },
    );

    expect(File(destination).readAsBytesSync(), payload);
    expect(partialResponses, greaterThan(1), reason: '구간을 나눠 받지 않았다');
    // 진행률은 끝에서 반드시 100%로 맞춰진다. 화면이 99%에서 멈춘 채로
    // 저장이 끝나면 안 된다.
    expect(lastTotal, payload.length);
    expect(lastReceived, payload.length);
    // 덩어리마다 알리면 5MiB에서 수백 번이 된다. 그 리빌드가 다운로드와 같은
    // isolate에서 돌아 받는 속도까지 갉아먹었다.
    expect(reports, lessThan(80), reason: '진행률 알림이 조여지지 않았다 ($reports회)');
  });

  test('Range를 무시하고 전체를 주는 서버에서도 파일이 온전하다', () async {
    final server = await serve((request, range) {
      request.response.contentLength = payload.length;
      request.response.add(payload);
    });

    final destination = '${workspace.path}/whole.mp4';
    await FastDownloader.download(urlOf(server), destination);

    expect(File(destination).readAsBytesSync(), payload);
  });

  test('전체 크기를 알려주지 않는 부분 응답은 잘린 파일 대신 통째로 다시 받는다', () async {
    var truncatedResponses = 0;
    final server = await serve((request, range) {
      if (range != null) {
        // 일부만 보내면서 Content-Range를 빠뜨린다. 이 응답만 믿으면 파일이
        // 앞부분만 남는다.
        truncatedResponses++;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.contentLength = 1024;
        request.response.add(Uint8List.sublistView(payload, 0, 1024));
        return;
      }
      request.response.contentLength = payload.length;
      request.response.add(payload);
    });

    final destination = '${workspace.path}/recovered.mp4';
    await FastDownloader.download(urlOf(server), destination);

    expect(truncatedResponses, 1);
    expect(File(destination).readAsBytesSync(), payload);
  });
}
