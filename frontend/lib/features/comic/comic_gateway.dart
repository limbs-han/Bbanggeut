/// 만화를 만드는 서버 통로.
///
/// **왜 서버를 경유하나**: 이미지 생성 API 키를 앱에 넣으면 APK를 뜯어 가져갈 수
/// 있다. 그러면 남의 계정으로 아무나 이미지를 생성한다. 키는 서버에만 둔다.
///
/// 서버 통로는 구현됐다(API-71·72 + 파이썬 만화 워커). [FakeComicGateway]는
/// 서버 없이 화면을 걸어 볼 때만 쓴다 — `--dart-define=COMIC_SERVER=false`.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../stt/caption_line.dart';
import 'comic_script.dart';

/// 기본은 **실서버**다. 견본으로 돌리려면 `--dart-define=COMIC_SERVER=false`.
///
/// 서버가 없던 동안에는 기본이 견본이었다. 이제 백엔드 게이트웨이(API-71·72)와
/// 만화 워커가 있으므로 뒤집었다 — 빌드할 때마다 인자를 붙여야 하는 쪽이
/// 위험하다. 붙이는 걸 잊으면 오류가 아니라 **가짜 만화가 그대로 출고된다.**
const comicServerReady = bool.fromEnvironment('COMIC_SERVER', defaultValue: true);

/// 기본 화풍. 화면에 고르는 UI를 두지 않는다(설계의 "하지 않는 것").
const comicDefaultStyle = 'webtoon';

abstract interface class ComicGateway {
  /// 전사문 → 4컷 구성.
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines);

  /// 4컷 구성 → 만화 그림 한 장(PNG 바이트). 2x2 격자다.
  Future<Uint8List> image(String videoId, List<ComicCut> cuts, {String style});
}

ComicGateway defaultComicGateway(ApiClient api) =>
    comicServerReady ? HttpComicGateway(api) : FakeComicGateway();

class HttpComicGateway implements ComicGateway {
  HttpComicGateway(this.api);

  final ApiClient api;

  @override
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines) async =>
      parseComicCuts(await api.createComicScript(videoId, linesToJson(lines)));

  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    final body = await api.createComicImage(
      videoId,
      cuts: cutsToJson(cuts),
      style: style,
    );
    final encoded = body['image'];
    if (encoded is! String || encoded.isEmpty) {
      throw FormatException('응답에 그림이 없습니다: ${body.keys.toList()}');
    }
    return base64Decode(encoded);
  }
}

/// 서버가 없을 때 쓰는 가짜. 화면과 흐름을 그대로 검증할 수 있게 만든다.
class FakeComicGateway implements ComicGateway {
  @override
  Future<List<ComicCut>> script(
    String videoId,
    List<CaptionLine> lines,
  ) async => [
    ComicCut(
      beat: '빌드업',
      scene: '아이가 탁자 위 물건에 손을 뻗고, 엄마가 말리는 순간',
      dialogue: '그거 만지지 마',
    ),
    ComicCut(
      beat: '전개',
      scene: '아이가 손을 뒤로 감추며 아니라고 하는 순간',
      dialogue: '안 만졌는데요',
    ),
    ComicCut(
      beat: '절정',
      scene: '탁자 위 물건이 바닥에 흩어져 있고 세 사람이 눈을 크게 뜨고 보는 순간',
    ),
    ComicCut(
      beat: '여운',
      scene: '온 가족이 마주 보며 크게 웃는 순간',
      dialogue: '안 만졌다면서',
    ),
  ];

  /// 2x2로 나뉜 색 블록. 자막을 얹을 칸이 보이면 화면 작업에 충분하다.
  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    const side = 512.0;
    const colors = [
      Color(0xFFBBDEFB),
      Color(0xFFC8E6C9),
      Color(0xFFFFE0B2),
      Color(0xFFF8BBD0),
    ];

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, side, side),
        Paint()..color = Colors.white,
      );
    for (var i = 0; i < colors.length; i++) {
      final left = (i % 2) * side / 2;
      final top = (i ~/ 2) * side / 2;
      canvas.drawRect(
        Rect.fromLTWH(left + 6, top + 6, side / 2 - 12, side / 2 - 12),
        Paint()..color = colors[i],
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(side.toInt(), side.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw StateError('가짜 그림을 만들지 못했습니다.');
    return data.buffer.asUint8List();
  }
}
