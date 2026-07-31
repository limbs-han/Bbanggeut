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
/// 비율을 곱한 뒤 안전 범위로 잘라낸다 — 기준은 S24+(약 411×890dp)에서
/// 미리보기 55%대, 타임라인 24%대가 나오도록 잡았고, 다른 기기는 같은 비율로
/// 자동으로 따라간다.
class EditorLayoutTokens {
  const EditorLayoutTokens._({
    required this.layoutClass,
    required this.availableHeight,
    required this.availableWidth,
    required this.topBarHeight,
    required this.timelineHeight,
    required this.collapsedTimelineHeight,
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
    final timelineHeight = _clamp(height * 0.245, 146, 232);
    final collapsedTimelineHeight = _clamp(height * 0.092, 64, 92);
    final toolPanelHeight = _clamp(height * 0.142, 100, 148);
    final thumbnailHeight = _clamp(height * 0.076, 50, 80);

    return EditorLayoutTokens._(
      layoutClass: layoutClass,
      availableHeight: height,
      availableWidth: width,
      topBarHeight: topBarHeight,
      timelineHeight: timelineHeight,
      collapsedTimelineHeight: collapsedTimelineHeight,
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
  final double timelineHeight;
  final double collapsedTimelineHeight;
  final double toolPanelHeight;
  final double bottomNavigationHeight;
  final double minimumPreviewHeight;
  final double thumbnailHeight;
  final double navigationFontSize;
  final double navigationIconSize;
  final double actionButtonHeight;

  static double _clamp(double value, double min, double max) =>
      math.min(math.max(value, min), max);
}
