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

/// 만화 작업 상태 한 장. 서버 응답(ComicJob)을 그대로 옮긴다.
class ComicJobStatus {
  const ComicJobStatus({
    required this.status,
    this.error,
    this.queuePosition = 0,
    this.imageUrl,
    this.savedAt,
    this.cuts,
  });

  /// none · queued · running · done · failed. `none`은 만든 적이 없다는 뜻이고
  /// 오류가 아니다.
  final String status;
  final String? error;

  /// 대기 순번. 0이면 지금 그리는 중이거나 이미 끝났다.
  final int queuePosition;
  final String? imageUrl;
  final DateTime? savedAt;

  /// 서버가 들고 있는 4컷 구성. 화면에 다시 들어올 때 이것을 쓰면 구성을 새로
  /// 받지 않는다 — 그 호출은 과금이고, 새로 받으면 사용자가 고친 대사가 서버
  /// 원문으로 덮인다. 만든 적이 없으면 null.
  final List<ComicCut>? cuts;

  bool get done => status == 'done';
  bool get failed => status == 'failed';
  bool get working => status == 'queued' || status == 'running';

  factory ComicJobStatus.fromJson(Map<String, dynamic> json) => ComicJobStatus(
    status: json['status'] as String? ?? 'none',
    error: json['error'] as String?,
    queuePosition: (json['queuePosition'] as num?)?.toInt() ?? 0,
    imageUrl: json['imageUrl'] as String?,
    savedAt: DateTime.tryParse(json['savedAt'] as String? ?? ''),
    cuts: _cutsOrNull(json),
  );

  /// 구성이 이상해도 상태 읽기가 죽지 않게 한다. parseComicCuts는 4컷이 아니면
  /// 예외를 던지는데, 그것 때문에 "만드는 중"조차 못 읽으면 화면이 멈춘다.
  static List<ComicCut>? _cutsOrNull(Map<String, dynamic> json) {
    if (json['cuts'] == null) return null;
    try {
      return parseComicCuts(json);
    } catch (_) {
      return null;
    }
  }
}

abstract interface class ComicGateway {
  /// 전사문 → 4컷 구성.
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines);

  /// 4컷 구성 → 만화 그림 한 장(PNG 바이트). 2x2 격자다.
  ///
  /// 화면을 붙잡아 두고 곧바로 결과를 보는 경로다. 오래 걸리는 생성은
  /// [enqueueImage]로 맡기고 [jobStatus]로 따라간다.
  Future<Uint8List> image(String videoId, List<ComicCut> cuts, {String style});

  /// 그림 만들기를 서버에 맡긴다. 화면을 벗어나도 계속되고 끝나면 알림이 온다.
  Future<ComicJobStatus> enqueueImage(
    String videoId,
    List<ComicCut> cuts, {
    String style,
  });

  /// 맡긴 작업의 상태. 다 됐으면 [ComicJobStatus.imageUrl]로 그림을 받는다.
  Future<ComicJobStatus> jobStatus(String videoId);

  /// 저장된 그림을 바이트로 받는다.
  Future<Uint8List> download(String imageUrl);
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

  @override
  Future<ComicJobStatus> enqueueImage(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async => ComicJobStatus.fromJson(
    await api.enqueueComicImage(videoId, cuts: cutsToJson(cuts), style: style),
  );

  @override
  Future<ComicJobStatus> jobStatus(String videoId) async =>
      ComicJobStatus.fromJson(await api.getComicJob(videoId));

  @override
  Future<Uint8List> download(String imageUrl) =>
      api.downloadBytes(imageUrl);
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

  /// 견본은 즉시 그린다. 대기 줄을 흉내 내면 화면 작업만 느려진다.
  Uint8List? _drawn;

  @override
  Future<ComicJobStatus> enqueueImage(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    _drawn = await image(videoId, cuts, style: style);
    return const ComicJobStatus(status: 'done', imageUrl: 'fake://comic');
  }

  @override
  Future<ComicJobStatus> jobStatus(String videoId) async => ComicJobStatus(
    status: _drawn == null ? 'none' : 'done',
    imageUrl: _drawn == null ? null : 'fake://comic',
  );

  @override
  Future<Uint8List> download(String imageUrl) async {
    final drawn = _drawn;
    if (drawn == null) throw StateError('아직 만든 만화가 없습니다.');
    return drawn;
  }
}
