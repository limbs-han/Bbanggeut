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

class EditorLayoutTokens {
  const EditorLayoutTokens._({
    required this.layoutClass,
    required this.topBarHeight,
    required this.timelineHeight,
    required this.bottomNavigationHeight,
    required this.minimumPreviewHeight,
  });

  factory EditorLayoutTokens.fromHeight(
    double height, {
    bool keyboardVisible = false,
  }) {
    if (height < 700) {
      return EditorLayoutTokens._(
        layoutClass: EditorLayoutClass.compact,
        topBarHeight: 44,
        timelineHeight: 148,
        bottomNavigationHeight: 56,
        minimumPreviewHeight: keyboardVisible ? 190 : 240,
      );
    }
    if (height <= 850) {
      return EditorLayoutTokens._(
        layoutClass: EditorLayoutClass.normal,
        topBarHeight: 48,
        timelineHeight: 184,
        bottomNavigationHeight: 60,
        minimumPreviewHeight: keyboardVisible ? 190 : 280,
      );
    }
    return EditorLayoutTokens._(
      layoutClass: EditorLayoutClass.tall,
      topBarHeight: 52,
      timelineHeight: 198,
      bottomNavigationHeight: 64,
      minimumPreviewHeight: keyboardVisible ? 190 : 280,
    );
  }

  final EditorLayoutClass layoutClass;
  final double topBarHeight;
  final double timelineHeight;
  final double bottomNavigationHeight;
  final double minimumPreviewHeight;

  double get thumbnailHeight => switch (layoutClass) {
    EditorLayoutClass.compact => 58,
    EditorLayoutClass.normal => 68,
    EditorLayoutClass.tall => 72,
  };
}
