import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class EditorColorTokens {
  static const background = Color(0xFFFFF7EE);
  static const surface = Color(0xFFFFFDFC);
  static const previewWorkspace = Color(0xFF0F0F10);
  static const videoCanvas = Color(0xFF000000);
  static const coral = Color(0xFFFF725B);
  static const ink = Color(0xFF2D1C12);
  static const muted = Color(0xFF8B776A);
  static const sage = Color(0xFFA7B96B);
  static const border = Color(0xFFEBD7C5);
  static const selected = Color(0xFFFFE9DF);
  static const shadow = Color(0x147A4F32);
}

/// 줌·자막처럼 한 클립에 여러 구간이 달릴 때 서로를 구분하는 색.
/// 타임라인 마커, 장면 카드, 자막 칩이 같은 순번에 같은 색을 쓴다.
abstract final class EditorMarkerTokens {
  static const palette = <Color>[
    Color(0xFF5A7CFF), // 파랑
    Color(0xFFFFA726), // 주황
    Color(0xFF66BB6A), // 초록
    Color(0xFFAB47BC), // 보라
    Color(0xFF26C6DA), // 청록
    Color(0xFFEC407A), // 분홍
  ];

  static Color colorAt(int index) => palette[index % palette.length];
}

abstract final class EditorSpacingTokens {
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const previewHorizontal = 12.0;
  static const minimumTouch = 44.0;
}

abstract final class EditorRadiusTokens {
  static const video = 4.0;
  static const control = 8.0;
  static const panel = 12.0;
  static const navigation = 22.0;
}

abstract final class EditorTypographyTokens {
  static const title = 18.0;
  static const panelTitle = 14.0;
  static const control = 12.0;
  static const navigation = 10.0;
}

enum EditorLayoutClass { compact, normal, tall }

/// 편집 화면의 높이·너비 배분.
///
/// **왜 비율인가**: 예전에는 높이 구간마다 고정 픽셀 값을 골랐다(148 / 184 /
/// 198…). 갤럭시 S24+처럼 세로가 긴 기기에서는 타임라인이 실제 화면에 비해
/// 작고, 작은 기기에서는 미리보기가 눌렸다. 이제 SafeArea 안쪽 실측 높이에
/// 비율을 곱한 뒤 안전 범위로 잘라낸다.
///
/// **기준 기기는 갤럭시 S24+**다. 논리 크기 411×891dp, 상태바·제스처바를 뺀
/// SafeArea 안쪽이 대략 411×840dp. 거기서 나오는 값은 이렇다.
///
/// | 조각        | 값      | 설명                          |
/// |-------------|---------|-------------------------------|
/// | 위 막대     | 48.7dp  | 뒤로·되돌리기·저장            |
/// | 구간 띠     | 73.9dp  | 프레임이 꽉 찬 노란 창        |
/// | 버튼 줄     | 41.2dp  | 분할·복제·삭제(컷 편집일 때)  |
/// | 도구 칸     | 119.3dp | 탭마다 다름(AR은 ×1.6)        |
/// | 하단 네비   | 63.8dp  | 도구 7개                      |
/// | **미리보기**| **493~612dp** | 나머지 전부 = 화면의 59~73% |
///
/// 다른 기기는 같은 비율로 따라간다. 세로가 짧아 미리보기가
/// [minimumPreviewHeight] 밑으로 내려갈 상황이면 도구 칸이 먼저 양보한다.
class EditorLayoutTokens {
  const EditorLayoutTokens._({
    required this.layoutClass,
    required this.availableHeight,
    required this.availableWidth,
    required this.topBarHeight,
    required this.trimBarHeight,
    required this.toolPanelHeight,
    required this.bottomNavigationHeight,
    required this.minimumPreviewHeight,
    required this.thumbnailHeight,
    required this.navigationFontSize,
    required this.navigationIconSize,
    required this.actionButtonHeight,
  });

  factory EditorLayoutTokens.fromSize(
    Size size, {
    bool keyboardVisible = false,
  }) {
    final height = size.height.isFinite && size.height > 0
        ? size.height
        : 800.0;
    final width = size.width.isFinite && size.width > 0 ? size.width : 390.0;
    final layoutClass = height < 700
        ? EditorLayoutClass.compact
        : height <= 850
        ? EditorLayoutClass.normal
        : EditorLayoutClass.tall;

    final topBarHeight = _clamp(height * 0.058, 44, 58);
    final bottomNavigationHeight = _clamp(height * 0.076, 54, 74);
    // 구간 띠 하나의 높이. 프레임이 알아볼 만큼은 크고, 미리보기를 밀어낼
    // 만큼 크지는 않게. 타임라인 칸 전체 높이는 이 띠와 버튼 줄을 더해
    // 저절로 정해진다 — 남는 자리를 빈칸으로 채우지 않는다.
    final trimBarHeight = _clamp(height * 0.088, 58, 92);
    final toolPanelHeight = _clamp(height * 0.142, 100, 148);
    final thumbnailHeight = _clamp(height * 0.076, 50, 80);

    return EditorLayoutTokens._(
      layoutClass: layoutClass,
      availableHeight: height,
      availableWidth: width,
      topBarHeight: topBarHeight,
      trimBarHeight: trimBarHeight,
      toolPanelHeight: toolPanelHeight,
      bottomNavigationHeight: bottomNavigationHeight,
      // 키보드가 올라오면 미리보기가 먼저 양보한다.
      minimumPreviewHeight: keyboardVisible
          ? _clamp(height * 0.22, 150, 210)
          : _clamp(height * 0.32, 200, 320),
      thumbnailHeight: thumbnailHeight,
      // 하단 도구가 7개다. 좁은 기기에서 글자가 잘리지 않게 줄인다.
      navigationFontSize: width < 360
          ? 8.5
          : width < 400
          ? 9.5
          : 10.0,
      navigationIconSize: width < 360 ? 18 : 20,
      actionButtonHeight: _clamp(height * 0.049, 38, 46),
    );
  }

  /// 높이만 아는 호출부를 위한 지름길. 너비는 흔한 세로 화면 기준으로 둔다.
  factory EditorLayoutTokens.fromHeight(
    double height, {
    bool keyboardVisible = false,
  }) => EditorLayoutTokens.fromSize(
    Size(390, height),
    keyboardVisible: keyboardVisible,
  );

  final EditorLayoutClass layoutClass;
  final double availableHeight;
  final double availableWidth;
  final double topBarHeight;
  final double trimBarHeight;
  final double toolPanelHeight;
  final double bottomNavigationHeight;
  final double minimumPreviewHeight;
  final double thumbnailHeight;
  final double navigationFontSize;
  final double navigationIconSize;
  final double actionButtonHeight;

  /// 도구 칸이 아무리 양보해도 이 아래로는 줄지 않는다. 제목 한 줄과 버튼
  /// 한 줄은 남아야 도구를 쓸 수 있다.
  static const minimumToolPanelHeight = 72.0;

  static double _clamp(double value, double min, double max) =>
      math.min(math.max(value, min), max);
}
