import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('서명 URL 다운로드에는 앱 Bearer 토큰을 전송하지 않는다', () async {
    final testHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = testHttpOverrides);

    FlutterSecureStorage.setMockInitialValues({
      'wj_access_token': 'app-access-token',
    });

    String? apiAuthorization;
    String? objectAuthorization;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((request) async {
      if (request.uri.path == '/api/videos/video-1/download-url') {
        apiAuthorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'url':
                'http://${server.address.host}:${server.port}/object/video.mp4?X-Amz-Signature=test',
            'expiresAt': '2026-07-30T12:00:00Z',
          }),
        );
      } else if (request.uri.path == '/object/video.mp4') {
        objectAuthorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.add([0, 1, 2, 3]);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final api = ApiClient(
      dio: Dio(
        BaseOptions(baseUrl: 'http://${server.address.host}:${server.port}'),
      ),
    );
    final tempDirectory = await Directory.systemTemp.createTemp(
      'bbanggeut-download-test-',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final destination = File('${tempDirectory.path}/video.mp4');

    await api.downloadVideoToFile('video-1', destination.path);

    expect(apiAuthorization, 'Bearer app-access-token');
    expect(objectAuthorization, isNull);
    expect(await destination.readAsBytes(), [0, 1, 2, 3]);
  });
}
