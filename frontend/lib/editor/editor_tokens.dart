import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/app_theme.dart';

abstract final class EditorColorTokens {
  /// 편집 화면의 바닥. **흰색**이다.
  ///
  /// **왜 크림([background])이 아닌가**: 자막 판이 화면 절반을 쓰게 되면서
  /// 얇은 막대·머리카락 같은 구분선·흰 카드가 전부 이 바닥 위에 놓인다.
  /// 크림빛 바닥에서는 흰 카드가 한 겹 떠 보이고 회색 구분선이 누렇게
  /// 물들었다. [background]는 이제 흰 바닥 위에 얹는 **칩·타일의 옅은 살**로만
  /// 남는다 — 거기서는 크림이 제 몫을 한다.
  static const canvas = Color(0xFFFFFFFF);
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

  /// 자막 편집 화면의 고밀도 조각들이 쓰는 값.
  ///
  /// **왜 따로 두는가**: [border]는 크림빛이 도는 굵은 테두리라 카드 하나를
  /// 감쌀 때는 맞지만, 얇은 단추·구분선을 그 색으로 그으면 선이 화면을
  /// 가른다. 아래 셋은 "있는 줄도 모를 만큼 얇게" 쓰는 자리 전용이다.
  static const hairline = Color(0xFFEEE9E5);

  /// 시간 눈금·자막 시각처럼 읽히되 앞으로 나서지 않아야 하는 글자.
  static const subtle = Color(0xFF756D68);

  /// +N 배지처럼 색을 갖지 않는 알갱이의 바닥.
  static const badge = Color(0xFFF1ECE6);

  /// 고른 자막 카드의 바닥. 제 색(코랄·올리브)을 아주 낮은 투명도로 깐
  /// 것이라, 카드가 물드는 정도로만 "고른 것"을 말한다.
  static const directWash = Color(0xFFFBEDEA);
  static const automaticWash = Color(0xFFF0F3E9);
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

/// 자막 하나를 알아보는 색과 막대의 두께.
///
/// 타임라인 막대·자막 카드 번호·겹침 시트의 줄이 **같은 자막에 같은 색**을
/// 쓴다 — 번호를 읽지 않아도 색만으로 "그 자막"을 짚을 수 있다.
///
/// 색을 정하는 것은 자막이 만들어진 곳(직접/AI)이 아니라 **순번**이다. 세 색이
/// 돌아가며 붙으므로 이웃한 막대가 늘 다른 색을 받는다 — 실처럼 얇은 막대가
/// 촘촘히 늘어서도 어디서 하나가 끝나고 다음이 시작하는지가 보인다. 출처는
/// 색이 아니라 카드가 말한다.
abstract final class EditorCaptionTokens {
  /// 막대 전용 색이다. 앱 팔레트([AppColors.coral], [AppColors.sageDark])를
  /// 그대로 쓰지 않는 까닭은 **바탕이 다르기 때문**이다 — 단추와 아이콘은
  /// 크림빛 배경에 얹히지만 이 막대는 흰 바탕에 4dp 실선으로 눕는다. 앱
  /// 올리브(#6E7F45)는 그 폭에서 검게 가라앉았고, 앱 코랄(#F47B61)은 주황과
  /// 구분이 흐렸다. 조금 더 맑고 진한 값으로 셋을 벌려 놓는다.
  static const coral = Color(0xFFF06C55);
  static const amber = Color(0xFFEF9B3F);
  static const olive = Color(0xFF7F9957);

  static const palette = <Color>[coral, amber, olive];

  static Color colorAt(int index) => palette[index % palette.length];

  /// 막대 두께. 글자는 아래 자막 카드가 맡고 막대는 **길이와 색만** 말한다 —
  /// 실처럼 얇아야 겹친 자막 세 층이 프레임 띠를 밀어내지 않는다.
  static const barHeight = 4.0;

  /// 고른 막대만 조금 두꺼워진다. 테두리도 그림자도 두르지 않는다 — 4dp
  /// 막대에 두르면 색이 남지 않고, 얇은 눈금 판이 단추밭처럼 보인다.
  static const selectedBarHeight = 6.0;

  /// 영상 위 글자 상자의 조작선(테두리·손잡이)에 받치는 그림자. 밝은 장면에서
  /// 흰 손잡이와 코랄 테두리가 배경에 묻히지 않을 만큼만 옅게 깐다.
  static const overlayShadow = BoxShadow(
    color: Color(0x4D000000),
    blurRadius: 5,
    offset: Offset(0, 1.5),
  );
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
