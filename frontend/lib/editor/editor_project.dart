import 'dart:math' as math;
import 'dart:ui';

/// 하단 네비게이션의 편집 도구. 나열 순서가 화면에 그려지는 순서다 —
/// `aiCaption`은 요청대로 `ar` 바로 왼쪽에 온다.
enum EditorTool {
  cut,
  ratio,
  zoom,
  text,
  audio,
  sticker,
  effect,
  aiCaption,
  ar,
}

enum EditorCanvasRatio { original, vertical, landscape, square, portrait }

enum EditorCanvasFit { cover, contain }

class EditorRecommendationMarker {
  const EditorRecommendationMarker({
    required this.preset,
    required this.sourceStartMs,
    required this.sourceEndMs,
  });

  final String preset;
  final int sourceStartMs;
  final int sourceEndMs;

  int get durationMs => math.max(0, sourceEndMs - sourceStartMs);
}

/// 영상 전체에 입히는 색감. 앱 안 AR 효과와 필터가 같이 쓴다.
///
/// 미리보기는 [ColorFilter], 내보내기는 media3의 RgbFilter/HslAdjustment로
/// 같은 값을 재현한다(EditorProjectExporter.kt의 `look` 처리 참조).
enum EditorLook { none, mono, warm, vivid, soft }

/// 글자 정렬. 미리보기와 내보내기가 같은 값을 쓴다
/// (EditorLayerOverlay.kt의 `AlignmentSpan` 처리 참조).
enum EditorTextAlign { left, center, right }

extension EditorLookFilter on EditorLook {
  String get label => switch (this) {
    EditorLook.none => '원본',
    EditorLook.soft => '보정',
    EditorLook.warm => '따뜻',
    EditorLook.vivid => '선명',
    EditorLook.mono => '흑백',
  };

  /// 미리보기용 색 변환. AR 탭의 필터 카드와 영상 미리보기가 같은 것을 쓴다 —
  /// 카드에서 본 색이 곧 영상에 입혀지는 색이어야 한다. 내보내기 쪽
  /// (EditorProjectExporter.kt의 `lookEffect`)이 media3로 같은 값을 재현한다.
  ColorFilter get colorFilter => switch (this) {
    EditorLook.mono => const ColorFilter.matrix([
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0, 0, 0, 1, 0,
    ]),
    EditorLook.warm => const ColorFilter.matrix([
      1.08, 0.04, 0, 0, 8, //
      0, 1.02, 0, 0, 3, //
      0, 0, 0.9, 0, -4, //
      0, 0, 0, 1, 0,
    ]),
    EditorLook.vivid => const ColorFilter.matrix([
      1.2, -0.1, -0.1, 0, 0, //
      -0.1, 1.2, -0.1, 0, 0, //
      -0.1, -0.1, 1.2, 0, 0, //
      0, 0, 0, 1, 0,
    ]),
    // 살짝 밝고 채도를 낮춘 보정. 얼굴에 쓰는 부드러운 톤이다.
    EditorLook.soft => const ColorFilter.matrix([
      0.9056, 0.0858, 0.0086, 0, 12, //
      0.0256, 0.9658, 0.0086, 0, 12, //
      0.0256, 0.0858, 0.8886, 0, 14, //
      0, 0, 0, 1, 0,
    ]),
    EditorLook.none => const ColorFilter.mode(Color(0x00000000), BlendMode.dst),
  };
}

enum EditorExportPhase {
  idle,
  preparing,
  rendering,
  completed,
  cancelled,
  failed,
}

class EditorSourceSize {
  const EditorSourceSize({required this.width, required this.height});

  final int width;
  final int height;

  double get aspectRatio => width > 0 && height > 0 ? width / height : 16 / 9;

  Map<String, Object> toMap() => {'width': width, 'height': height};
}

class NormalizedPoint {
  const NormalizedPoint._(this.x, this.y);

  factory NormalizedPoint(double x, double y) =>
      NormalizedPoint._(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));

  static const center = NormalizedPoint._(0.5, 0.5);

  final double x;
  final double y;

  NormalizedPoint translate(double dx, double dy) =>
      NormalizedPoint(x + dx, y + dy);

  Map<String, Object> toMap() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      other is NormalizedPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

class EditorClip {
  const EditorClip({
    required this.id,
    required this.sourcePath,
    required this.sourceStartMs,
    required this.sourceEndMs,
    this.arEffectId,
    this.automatic = false,
    this.score,
  });

  final String id;
  final String sourcePath;
  final int sourceStartMs;
  final int sourceEndMs;
  final String? arEffectId;
  final bool automatic;

  /// 이 구간의 멀티모달 사건 점수(0~1). AI 컷이 서버 scoreTimeline에서
  /// 계산해 채운다. 점수 없이 만든 클립(직접 추가 등)은 null이다.
  final double? score;

  int get durationMs => math.max(0, sourceEndMs - sourceStartMs);

  /// 같은 원본에서 다음 프레임으로 그대로 이어 재생할 수 있는 클립인가.
  /// 30fps 한 프레임의 반올림 오차(34ms)까지는 연속으로 본다.
  bool isPlaybackContiguousWith(EditorClip next) =>
      sourcePath == next.sourcePath &&
      (next.sourceStartMs - sourceEndMs).abs() <= 34;

  EditorClip copyWith({
    String? id,
    int? sourceStartMs,
    int? sourceEndMs,
    String? arEffectId,
    bool clearArEffect = false,
    bool? automatic,
    double? score,
  }) => EditorClip(
    id: id ?? this.id,
    sourcePath: sourcePath,
    sourceStartMs: sourceStartMs ?? this.sourceStartMs,
    sourceEndMs: sourceEndMs ?? this.sourceEndMs,
    arEffectId: clearArEffect ? null : arEffectId ?? this.arEffectId,
    automatic: automatic ?? this.automatic,
    score: score ?? this.score,
  );

  Map<String, Object?> toMap({required int timelineStartMs}) => {
    'id': id,
    'sourcePath': sourcePath,
    'sourceStartMs': sourceStartMs,
    'sourceEndMs': sourceEndMs,
    'timelineStartMs': timelineStartMs,
    'timelineEndMs': timelineStartMs + durationMs,
    'arEffectId': arEffectId,
    'automatic': automatic,
  };

  /// 값으로 비교한다. 되돌리기 이력이 "손가락이 지나갔다"가 아니라 "실제로
  /// 달라졌다"만 기록하려면 필요하다 — 구간 손잡이를 잡았다가 제자리에 놓으면
  /// 이력이 쌓이지 않아야 한다.
  @override
  bool operator ==(Object other) =>
      other is EditorClip &&
      other.id == id &&
      other.sourcePath == sourcePath &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceEndMs == sourceEndMs &&
      other.arEffectId == arEffectId &&
      other.automatic == automatic &&
      other.score == score;

  @override
  int get hashCode => Object.hash(
    id,
    sourcePath,
    sourceStartMs,
    sourceEndMs,
    arEffectId,
    automatic,
    score,
  );
}

class EditorZoomSegment {
  const EditorZoomSegment({
    required this.id,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.scale,
    required this.focus,
    this.automatic = false,
    this.clipId,
  });

  final String id;
  final int sourceStartMs;
  final int sourceEndMs;
  final double scale;
  final NormalizedPoint focus;
  final bool automatic;

  /// 이 줌이 속한 클립. 줌은 원본 좌표를 쓰지만 **클립 하나에 묶인다** —
  /// 같은 원본 구간을 쓰는 클립이 여럿이어도 묶인 클립에서만 작동하고,
  /// 클립을 지우면 함께 사라진다. null이면 옛 데이터(원본 전체에 적용).
  final String? clipId;

  int get durationMs => math.max(0, sourceEndMs - sourceStartMs);

  /// 이 줌이 [clip]에서 작동하는가.
  bool worksIn(EditorClip clip) => clipId == null || clipId == clip.id;

  EditorZoomSegment copyWith({
    int? sourceStartMs,
    int? sourceEndMs,
    double? scale,
    NormalizedPoint? focus,
    String? clipId,
  }) => EditorZoomSegment(
    id: id,
    sourceStartMs: sourceStartMs ?? this.sourceStartMs,
    sourceEndMs: sourceEndMs ?? this.sourceEndMs,
    scale: (scale ?? this.scale).clamp(1.0, 2.8),
    focus: focus ?? this.focus,
    automatic: automatic,
    clipId: clipId ?? this.clipId,
  );

  @override
  bool operator ==(Object other) =>
      other is EditorZoomSegment &&
      other.id == id &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceEndMs == sourceEndMs &&
      other.scale == scale &&
      other.focus == focus &&
      other.automatic == automatic &&
      other.clipId == clipId;

  @override
  int get hashCode => Object.hash(
    id,
    sourceStartMs,
    sourceEndMs,
    scale,
    focus,
    automatic,
    clipId,
  );
}

class EditorCanvas {
  const EditorCanvas({
    required this.sourceAspectRatio,
    this.ratio = EditorCanvasRatio.original,
    this.fit = EditorCanvasFit.cover,
    this.outputWidth = 1280,
    this.outputHeight = 720,
    this.scale = 1,
    this.offsetX = 0,
    this.offsetY = 0,
    this.rotationDegrees = 0,
    this.backgroundColor = const Color(0xFF000000),
  });

  final double sourceAspectRatio;
  final EditorCanvasRatio ratio;
  final EditorCanvasFit fit;
  final int outputWidth;
  final int outputHeight;
  final double scale;
  final double offsetX;
  final double offsetY;
  final double rotationDegrees;
  final Color backgroundColor;

  double get aspectRatio => switch (ratio) {
    EditorCanvasRatio.original => sourceAspectRatio,
    EditorCanvasRatio.vertical => 9 / 16,
    EditorCanvasRatio.landscape => 16 / 9,
    EditorCanvasRatio.square => 1,
    EditorCanvasRatio.portrait => 4 / 5,
  };

  double get minimumScale {
    if (ratio == EditorCanvasRatio.original || fit == EditorCanvasFit.contain) {
      return 1;
    }
    final source = sourceAspectRatio;
    final target = aspectRatio;
    return source >= target ? source / target : target / source;
  }

  EditorCanvas copyWith({
    EditorCanvasRatio? ratio,
    EditorCanvasFit? fit,
    int? outputWidth,
    int? outputHeight,
    double? scale,
    double? offsetX,
    double? offsetY,
    double? rotationDegrees,
    Color? backgroundColor,
  }) {
    final nextRatio = ratio ?? this.ratio;
    final nextFit = fit ?? this.fit;
    final provisional = EditorCanvas(
      sourceAspectRatio: sourceAspectRatio,
      ratio: nextRatio,
      fit: nextFit,
      outputWidth: outputWidth ?? this.outputWidth,
      outputHeight: outputHeight ?? this.outputHeight,
      scale: 1,
      offsetX: 0,
      offsetY: 0,
      rotationDegrees: rotationDegrees ?? this.rotationDegrees,
      backgroundColor: backgroundColor ?? this.backgroundColor,
    );
    final nextScale = math
        .max(scale ?? this.scale, provisional.minimumScale)
        .clamp(1.0, 4.0);
    final radians = provisional.rotationDegrees.abs() * math.pi / 180;
    final source = sourceAspectRatio;
    final target = provisional.aspectRatio;
    final halfWidth = source >= target ? 1.0 : source / target;
    final halfHeight = source >= target ? target / source : 1.0;
    final extentX =
        nextScale *
        (math.cos(radians).abs() * halfWidth +
            math.sin(radians).abs() * halfHeight);
    final extentY =
        nextScale *
        (math.sin(radians).abs() * halfWidth +
            math.cos(radians).abs() * halfHeight);
    final maxX = math.min(
      1.0,
      math.max(
        0.0,
        nextFit == EditorCanvasFit.cover ? extentX - 1 : 1 - extentX,
      ),
    );
    final maxY = math.min(
      1.0,
      math.max(
        0.0,
        nextFit == EditorCanvasFit.cover ? extentY - 1 : 1 - extentY,
      ),
    );
    return EditorCanvas(
      sourceAspectRatio: sourceAspectRatio,
      ratio: nextRatio,
      fit: nextFit,
      outputWidth: outputWidth ?? this.outputWidth,
      outputHeight: outputHeight ?? this.outputHeight,
      scale: nextScale,
      offsetX: (offsetX ?? this.offsetX).clamp(-maxX, maxX),
      offsetY: (offsetY ?? this.offsetY).clamp(-maxY, maxY),
      rotationDegrees: provisional.rotationDegrees,
      backgroundColor: backgroundColor ?? this.backgroundColor,
    );
  }

  Map<String, Object> toMap() => {
    'ratio': ratio.name,
    'fit': fit.name,
    'aspectRatio': aspectRatio,
    'outputWidth': outputWidth,
    'outputHeight': outputHeight,
    'scale': scale,
    'offsetX': offsetX,
    'offsetY': offsetY,
    'rotationDegrees': rotationDegrees,
    'backgroundColor': backgroundColor.toARGB32(),
  };
}

abstract class EditorTimedLayer {
  const EditorTimedLayer({
    required this.id,
    required this.position,
    required this.startMs,
    required this.endMs,
    this.scale = 1,
    this.rotationDegrees = 0,
  });

  final String id;
  final NormalizedPoint position;
  final int startMs;
  final int endMs;
  final double scale;
  final double rotationDegrees;

  /// 이 시각에 화면에 보이는가.
  ///
  /// 끝을 **포함**한다. 영상 끝까지 재생한 뒤 스티커를 놓으면 재생 위치가
  /// 정확히 `durationMs`인데, 끝을 빼고 따지면 방금 놓은 스티커가 보이지
  /// 않는다 — "눌러도 안 올라간다"의 정체였다.
  bool isVisibleAt(int positionMs) =>
      positionMs >= startMs && positionMs <= endMs;
}

class EditorTextLayer extends EditorTimedLayer {
  const EditorTextLayer({
    required super.id,
    required this.text,
    required super.position,
    required super.startMs,
    required super.endMs,
    super.scale,
    super.rotationDegrees,
    this.color = const Color(0xFFFFFFFF),
    // 배경 없는 글자가 기본이다. 영상 위에 투명한 글자 상자로 얹히고, 어두운
    // 화면에서도 읽히도록 미리보기·내보내기 모두 글자에 테두리를 그린다.
    this.backgroundColor = const Color(0x00000000),
    this.fontSize = 42,
    this.bold = true,
    this.italic = false,
    this.align = EditorTextAlign.center,
    this.clipId,
  });

  final String text;
  final Color color;
  final Color backgroundColor;
  final double fontSize;
  final bool bold;
  final bool italic;
  final EditorTextAlign align;

  /// 이 자막이 묶인 클립. [startMs]·[endMs]는 타임라인 절대 시각이지만,
  /// 클립이 옮겨지거나 잘리면 컨트롤러가 이 묶음을 따라 다시 계산한다.
  /// 클립을 지우면 자막도 함께 사라진다. null이면 어느 클립에도 묶이지
  /// 않은 옛 데이터다.
  final String? clipId;

  EditorTextLayer copyWith({
    String? text,
    NormalizedPoint? position,
    int? startMs,
    int? endMs,
    double? scale,
    double? rotationDegrees,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    bool? bold,
    bool? italic,
    EditorTextAlign? align,
    String? clipId,
  }) => EditorTextLayer(
    id: id,
    text: text ?? this.text,
    position: position ?? this.position,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    scale: (scale ?? this.scale).clamp(0.2, 4.0),
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    fontSize: (fontSize ?? this.fontSize).clamp(16.0, 160.0),
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    align: align ?? this.align,
    clipId: clipId ?? this.clipId,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'text': text,
    'position': position.toMap(),
    'startMs': startMs,
    'endMs': endMs,
    'scale': scale,
    'rotationDegrees': rotationDegrees,
    'color': color.toARGB32(),
    'backgroundColor': backgroundColor.toARGB32(),
    'fontSize': fontSize,
    'bold': bold,
    'italic': italic,
    'align': align.name,
    'clipId': clipId,
  };

  @override
  bool operator ==(Object other) =>
      other is EditorTextLayer &&
      other.id == id &&
      other.text == text &&
      other.position == position &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.scale == scale &&
      other.rotationDegrees == rotationDegrees &&
      other.color == color &&
      other.backgroundColor == backgroundColor &&
      other.fontSize == fontSize &&
      other.bold == bold &&
      other.italic == italic &&
      other.align == align &&
      other.clipId == clipId;

  @override
  int get hashCode => Object.hash(
    id,
    text,
    position,
    startMs,
    endMs,
    scale,
    rotationDegrees,
    color,
    backgroundColor,
    fontSize,
    bold,
    italic,
    align,
    clipId,
  );
}

class EditorStickerLayer extends EditorTimedLayer {
  const EditorStickerLayer({
    required super.id,
    required this.value,
    required super.position,
    required super.startMs,
    required super.endMs,
    super.scale,
    super.rotationDegrees,
    this.clipId,
    this.tracksFace = false,
    this.faceTrackId,
  });

  final String value;

  /// 따라갈 사람. 서버가 준 [EditorProject.faceTracks]의 id다. null이면
  /// 옛 데이터 — 한 줄 궤적([EditorProject.faceTrack])을 연속 구간으로
  /// 나눠 따라간다.
  final String? faceTrackId;

  /// 이 스티커가 묶인 클립. 자막과 같은 규칙이다 — 클립이 옮겨지거나 잘리면
  /// 컨트롤러가 이 묶음을 따라 다시 계산하고, 클립을 지우면 스티커도 함께
  /// 사라진다. null이면 어느 클립에도 묶이지 않은 옛 데이터다.
  final String? clipId;

  /// 얼굴을 따라다니는가(AR 탭). true면 [position]은 화면 좌표가 아니라
  /// **얼굴 중심에서의 오프셋**이다 — (0.5, 0.5)면 얼굴 정중앙에 붙는다.
  /// 실제 화면 위치는 프레임마다 [EditorProject.faceSampleForLayer]로 구한다.
  final bool tracksFace;

  EditorStickerLayer copyWith({
    String? value,
    NormalizedPoint? position,
    int? startMs,
    int? endMs,
    double? scale,
    double? rotationDegrees,
    String? clipId,
    bool? tracksFace,
    String? faceTrackId,
  }) => EditorStickerLayer(
    id: id,
    value: value ?? this.value,
    position: position ?? this.position,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    scale: (scale ?? this.scale).clamp(0.2, 4.0),
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    clipId: clipId ?? this.clipId,
    tracksFace: tracksFace ?? this.tracksFace,
    faceTrackId: faceTrackId ?? this.faceTrackId,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'value': value,
    'position': position.toMap(),
    'startMs': startMs,
    'endMs': endMs,
    'scale': scale,
    'rotationDegrees': rotationDegrees,
    'clipId': clipId,
    'tracksFace': tracksFace,
    'faceTrackId': faceTrackId,
  };

  @override
  bool operator ==(Object other) =>
      other is EditorStickerLayer &&
      other.id == id &&
      other.value == value &&
      other.position == position &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.scale == scale &&
      other.rotationDegrees == rotationDegrees &&
      other.clipId == clipId &&
      other.tracksFace == tracksFace &&
      other.faceTrackId == faceTrackId;

  @override
  int get hashCode => Object.hash(
    id,
    value,
    position,
    startMs,
    endMs,
    scale,
    rotationDegrees,
    clipId,
    tracksFace,
    faceTrackId,
  );
}

class EditorBlurLayer extends EditorTimedLayer {
  const EditorBlurLayer({
    required super.id,
    required super.position,
    required super.startMs,
    required super.endMs,
    super.scale,
    super.rotationDegrees,
    this.width = 0.24,
    this.height = 0.18,
    this.intensity = 0.5,
    this.isCircular = false,
  });

  final double width;
  final double height;
  final double intensity;
  final bool isCircular;

  Map<String, Object> toMap() => {
    'id': id,
    'position': position.toMap(),
    'startMs': startMs,
    'endMs': endMs,
    'scale': scale,
    'rotationDegrees': rotationDegrees,
    'width': width,
    'height': height,
    'intensity': intensity,
    'isCircular': isCircular,
  };
}

class EditorAudio {
  const EditorAudio({this.sourceVolume = 1, this.muted = false});

  final double sourceVolume;
  final bool muted;

  double get effectiveVolume => muted ? 0 : sourceVolume.clamp(0.0, 1.0);

  EditorAudio copyWith({double? sourceVolume, bool? muted}) => EditorAudio(
    sourceVolume: (sourceVolume ?? this.sourceVolume).clamp(0.0, 1.0),
    muted: muted ?? this.muted,
  );

  Map<String, Object> toMap() => {
    'sourceVolume': effectiveVolume,
    'muted': muted,
  };
}

class EditorExportState {
  const EditorExportState({
    this.phase = EditorExportPhase.idle,
    this.progress = 0,
    this.message,
  });

  final EditorExportPhase phase;
  final double progress;
  final String? message;

  bool get isBusy =>
      phase == EditorExportPhase.preparing ||
      phase == EditorExportPhase.rendering;

  EditorExportState copyWith({
    EditorExportPhase? phase,
    double? progress,
    String? message,
  }) => EditorExportState(
    phase: phase ?? this.phase,
    progress: (progress ?? this.progress).clamp(0.0, 1.0),
    message: message ?? this.message,
  );
}

/// 서버 분석(MediaPipe)이 뽑은 어느 순간의 얼굴 위치.
///
/// [sourceMs]는 **원본 영상 시각**이다 — 클립을 자르고 옮겨도 원본 기준
/// 좌표는 변하지 않아, 얼굴 추적 스티커가 클립 배치와 무관하게 맞는다.
/// [x]·[y]는 0~1 정규화 얼굴 중심, [height]는 화면 대비 얼굴 높이다.
class EditorFaceSample {
  const EditorFaceSample({
    required this.sourceMs,
    required this.x,
    required this.y,
    this.height = 0,
  });

  final int sourceMs;
  final double x;
  final double y;
  final double height;

  Map<String, Object> toMap() => {
    'ms': sourceMs,
    'x': x,
    'y': y,
    'h': height,
  };

  @override
  bool operator ==(Object other) =>
      other is EditorFaceSample &&
      other.sourceMs == sourceMs &&
      other.x == x &&
      other.y == y &&
      other.height == height;

  @override
  int get hashCode => Object.hash(sourceMs, x, y, height);
}

/// 한 사람의 얼굴 궤적. 서버가 창마다 검출한 얼굴들을 사람별로 이어 붙여
/// 준다 — 여러 명이 나와도 스티커가 "누구"를 따라갈지 id로 고른다.
class EditorFaceTrack {
  const EditorFaceTrack({required this.id, required this.samples});

  final String id;
  final List<EditorFaceSample> samples;

  /// 이 사람이 화면에 잡혀 있던 원본 시각 범위.
  int get firstMs => samples.isEmpty ? 0 : samples.first.sourceMs;
  int get lastMs => samples.isEmpty ? 0 : samples.last.sourceMs;

  Map<String, Object> toMap() => {
    'id': id,
    'samples': [for (final sample in samples) sample.toMap()],
  };
}

class EditorProject {
  const EditorProject({
    required this.sourceVideoPath,
    required this.sourceDurationMs,
    required this.sourceSize,
    required this.clips,
    required this.canvas,
    this.textLayers = const [],
    this.zoomSegments = const [],
    this.stickerLayers = const [],
    this.blurLayers = const [],
    this.faceTrack = const [],
    this.faceTracks = const [],
    this.audio = const EditorAudio(),
    this.look = EditorLook.none,
    this.arEffectId,
    this.selectedTool = EditorTool.cut,
    this.selectedClipId,
    this.selectedLayerId,
    this.selectedZoomId,
    this.recommendationMarker,
    this.playheadMs = 0,
    this.isPlaying = false,
    this.exportState = const EditorExportState(),
    this.revision = 0,
  });

  factory EditorProject.fromSource({
    required String sourceVideoPath,
    required int sourceDurationMs,
    required EditorSourceSize sourceSize,
  }) => EditorProject(
    sourceVideoPath: sourceVideoPath,
    sourceDurationMs: sourceDurationMs,
    sourceSize: sourceSize,
    clips: [
      EditorClip(
        id: 'clip-0',
        sourcePath: sourceVideoPath,
        sourceStartMs: 0,
        sourceEndMs: sourceDurationMs,
      ),
    ],
    canvas: EditorCanvas(sourceAspectRatio: sourceSize.aspectRatio),
    selectedClipId: 'clip-0',
  );

  final String sourceVideoPath;
  final int sourceDurationMs;
  final EditorSourceSize sourceSize;
  final List<EditorClip> clips;
  final EditorCanvas canvas;
  final List<EditorTextLayer> textLayers;
  final List<EditorZoomSegment> zoomSegments;
  final List<EditorStickerLayer> stickerLayers;
  final List<EditorBlurLayer> blurLayers;

  /// 서버 분석이 준 얼굴 궤적(원본 시각순). 얼굴 추적 스티커가 쓴다.
  /// [faceTracks]가 있으면 그쪽(사람별)이 우선이고, 이 한 줄짜리는
  /// 옛 초안·옛 서버와의 호환용이다.
  final List<EditorFaceSample> faceTrack;

  /// 사람별 얼굴 궤적. 스티커는 [EditorStickerLayer.faceTrackId]로
  /// 이 중 하나를 골라 따라간다.
  final List<EditorFaceTrack> faceTracks;
  final EditorAudio audio;
  final EditorLook look;

  /// 지금 적용된 앱 안 AR 효과. 패널에서 어느 카드가 켜져 있는지 표시할 때 쓴다.
  final String? arEffectId;

  final EditorTool selectedTool;
  final String? selectedClipId;
  final String? selectedLayerId;
  final String? selectedZoomId;
  final EditorRecommendationMarker? recommendationMarker;
  final int playheadMs;
  final bool isPlaying;
  final EditorExportState exportState;
  final int revision;

  int get durationMs =>
      clips.fold(0, (duration, clip) => duration + clip.durationMs);

  /// 조각들이 원본을 처음부터 끝까지 빈틈없이 덮는가.
  ///
  /// **왜 조각 수를 세지 않는가**: 나눠 놓고 아무것도 지우지 않으면 조각은
  /// 여럿이어도 이어 붙인 결과는 원본과 한 프레임도 다르지 않다. 그런데
  /// "조각이 하나일 때만 원본 그대로"로 보면 그 경우에 영상 전체를 다시
  /// 만들었다 — 똑같은 결과를 몇십 초 걸려 새로 인코딩한 셈이다.
  bool get _clipsCoverWholeSource {
    if (clips.isEmpty) return false;
    var cursor = 0;
    for (final clip in clips) {
      if (clip.sourcePath != sourceVideoPath) return false;
      if (clip.sourceStartMs != cursor) return false;
      cursor = clip.sourceEndMs;
    }
    return cursor == sourceDurationMs;
  }

  bool requiresRendering({bool hasCaptions = false}) {
    final directSource = _clipsCoverWholeSource;
    final originalCanvas =
        canvas.ratio == EditorCanvasRatio.original &&
        canvas.scale == 1 &&
        canvas.offsetX == 0 &&
        canvas.offsetY == 0 &&
        canvas.rotationDegrees == 0;
    final originalAudio = !audio.muted && audio.sourceVolume == 1;
    return !directSource ||
        !originalCanvas ||
        !originalAudio ||
        look != EditorLook.none ||
        textLayers.isNotEmpty ||
        stickerLayers.isNotEmpty ||
        blurLayers.isNotEmpty ||
        zoomSegments.isNotEmpty ||
        hasCaptions;
  }

  EditorClip? get selectedClip {
    final id = selectedClipId;
    if (id == null) return null;
    for (final clip in clips) {
      if (clip.id == id) return clip;
    }
    return null;
  }

  EditorTextLayer? get selectedTextLayer {
    final id = selectedLayerId;
    if (id == null) return null;
    for (final layer in textLayers) {
      if (layer.id == id) return layer;
    }
    return null;
  }

  EditorStickerLayer? get selectedStickerLayer {
    final id = selectedLayerId;
    if (id == null) return null;
    for (final layer in stickerLayers) {
      if (layer.id == id) return layer;
    }
    return null;
  }

  int timelineStartFor(String clipId) {
    var startMs = 0;
    for (final clip in clips) {
      if (clip.id == clipId) return startMs;
      startMs += clip.durationMs;
    }
    return startMs;
  }

  int? sourcePositionForTimeline(int timelineMs) {
    var cursor = 0;
    for (final clip in clips) {
      final end = cursor + clip.durationMs;
      if (timelineMs <= end) {
        return clip.sourceStartMs +
            (timelineMs - cursor).clamp(0, clip.durationMs);
      }
      cursor = end;
    }
    return clips.isEmpty ? null : clips.last.sourceEndMs;
  }

  /// 원본 시각이 타임라인의 어디에 놓이는지. 어느 클립에도 없으면 가장
  /// 가까운 클립 경계로 붙인다.
  int timelinePositionForSource(int sourceMs) {
    var cursor = 0;
    for (final clip in clips) {
      if (sourceMs < clip.sourceStartMs) return cursor;
      if (sourceMs <= clip.sourceEndMs) {
        return cursor + (sourceMs - clip.sourceStartMs);
      }
      cursor += clip.durationMs;
    }
    return durationMs;
  }

  EditorZoomSegment? zoomAtTimeline(int timelineMs) {
    var cursor = 0;
    for (var index = 0; index < clips.length; index++) {
      final clip = clips[index];
      final end = cursor + clip.durationMs;
      if (timelineMs < end || index == clips.length - 1) {
        final sourceMs =
            clip.sourceStartMs +
            (timelineMs - cursor).clamp(0, clip.durationMs);
        for (final zoom in zoomSegments.reversed) {
          // 줌은 묶인 클립 안에서만 작동한다 — 같은 원본 구간을 쓰는
          // 다른 클립에는 걸리지 않는다.
          if (zoom.worksIn(clip) &&
              sourceMs >= zoom.sourceStartMs &&
              sourceMs < zoom.sourceEndMs) {
            return zoom;
          }
        }
        return null;
      }
      cursor = end;
    }
    return null;
  }

  /// 이 원본 시각의 얼굴 중심. 트랙이 비었으면 null.
  ///
  /// 이웃 표본을 선형 보간하고, 트랙 바깥 시각은 가장 가까운 표본을 그대로
  /// 쓴다. 얼굴이 잠깐 사라진 구간도 이웃끼리 보간한다 — 스티커가 사라졌다
  /// 나타나며 깜빡이는 것보다 부드럽게 건너가는 쪽이 덜 거슬린다.
  EditorFaceSample? faceSampleAt(int sourceMs) =>
      _sampleOn(faceTrack, sourceMs);

  static EditorFaceSample? _sampleOn(
    List<EditorFaceSample> track,
    int sourceMs,
  ) {
    if (track.isEmpty) return null;
    if (sourceMs <= track.first.sourceMs) return track.first;
    if (sourceMs >= track.last.sourceMs) return track.last;
    for (var index = 1; index < track.length; index++) {
      final next = track[index];
      if (sourceMs > next.sourceMs) continue;
      final prev = track[index - 1];
      final span = next.sourceMs - prev.sourceMs;
      if (span <= 0) return next;
      final t = (sourceMs - prev.sourceMs) / span;
      return EditorFaceSample(
        sourceMs: sourceMs,
        x: prev.x + (next.x - prev.x) * t,
        y: prev.y + (next.y - prev.y) * t,
        height: prev.height + (next.height - prev.height) * t,
      );
    }
    return track.last;
  }

  /// 이웃 표본이 이보다 멀리 건너뛰면 분석 초점이 다른 얼굴로 옮겨간 것으로
  /// 본다. 0~1 정규화 화면 좌표 기준이다.
  static const _faceJumpDistance = 0.16;

  static double _faceDistance(EditorFaceSample a, EditorFaceSample b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// 궤적을 "같은 얼굴을 계속 본" 연속 구간으로 나눈다.
  ///
  /// 서버 궤적은 매 순간 가장 두드러진 얼굴 **한 점**만 준다. 여러 명이
  /// 나오면 초점이 사람 사이를 오가는데, 그 순간 표본이 화면을 크게
  /// 건너뛴다 — 스티커가 얼굴 사이를 왔다갔다 하던 원인. 건너뛴 자리에서
  /// 구간을 끊어 두면 "한 사람의 경로"만 골라 따라갈 수 있다.
  List<List<EditorFaceSample>> _faceTrackSegments() {
    final segments = <List<EditorFaceSample>>[];
    for (final sample in faceTrack) {
      final current = segments.isEmpty ? null : segments.last;
      final prev = current == null || current.isEmpty ? null : current.last;
      if (prev == null) {
        segments.add([sample]);
        continue;
      }
      final gapMs = sample.sourceMs - prev.sourceMs;
      // 표본은 250ms 간격이다. 오래 끊겼다 잡히면 그 사이 실제로 움직였을
      // 수 있으니 허용치를 시간에 비례해 (최대 3배까지) 늘린다.
      final allowed =
          _faceJumpDistance * (gapMs / 250).clamp(1.0, 3.0);
      if (gapMs > 1500 || _faceDistance(prev, sample) > allowed) {
        segments.add([sample]);
      } else {
        current!.add(sample);
      }
    }
    return segments;
  }

  /// [anchorSourceMs] 순간의 얼굴에서 이어지는 경로만 추린 궤적.
  ///
  /// 앵커 구간에서 시간 순으로 앞뒤를 훑으며, 끊긴 자리 **근처에서** 다시
  /// 시작하는 구간만 같은 얼굴로 보고 이어 붙인다. 멀리서 시작하는 구간은
  /// 다른 얼굴이므로 버린다 — 그 시간대에는 이웃 표본 사이에 머물러
  /// 스티커가 다른 사람에게 튀지 않는다.
  List<EditorFaceSample> _anchoredFaceTrack(int anchorSourceMs) {
    final segments = _faceTrackSegments();
    if (segments.length <= 1) return faceTrack;
    var anchorIndex = 0;
    var bestGapMs = 1 << 50;
    for (var index = 0; index < segments.length; index++) {
      final first = segments[index].first.sourceMs;
      final last = segments[index].last.sourceMs;
      if (anchorSourceMs >= first && anchorSourceMs <= last) {
        anchorIndex = index;
        break;
      }
      final gap = anchorSourceMs < first
          ? first - anchorSourceMs
          : anchorSourceMs - last;
      if (gap < bestGapMs) {
        bestGapMs = gap;
        anchorIndex = index;
      }
    }
    final chained = <List<EditorFaceSample>>[segments[anchorIndex]];
    var tail = segments[anchorIndex].last;
    for (var index = anchorIndex + 1; index < segments.length; index++) {
      if (_faceDistance(tail, segments[index].first) > _faceJumpDistance) {
        continue;
      }
      chained.add(segments[index]);
      tail = segments[index].last;
    }
    var head = segments[anchorIndex].first;
    for (var index = anchorIndex - 1; index >= 0; index--) {
      if (_faceDistance(segments[index].last, head) > _faceJumpDistance) {
        continue;
      }
      chained.insert(0, segments[index]);
      head = segments[index].first;
    }
    return [for (final segment in chained) ...segment];
  }

  /// 이 스티커가 어느 얼굴을 따라갈지 정하는 기준 시각(원본 ms).
  ///
  /// 구간 **시작 순간**에 잡힌 얼굴이 "그 얼굴"이다 — 타임라인에서 시작점을
  /// 옮기면 따라갈 얼굴도 그 순간의 얼굴로 바뀐다.
  int? faceAnchorFor(EditorStickerLayer layer) {
    if (layer.clipId != null) {
      for (final clip in clips) {
        if (clip.id != layer.clipId) continue;
        final offset = layer.startMs - timelineStartFor(clip.id);
        return (clip.sourceStartMs + offset).clamp(
          clip.sourceStartMs,
          clip.sourceEndMs,
        );
      }
    }
    return sourcePositionForTimeline(layer.startMs);
  }

  /// [layer]가 따라갈 얼굴의 궤적.
  ///
  /// 서버가 사람별 궤적([faceTracks])을 줬으면 스티커가 고른 사람
  /// ([EditorStickerLayer.faceTrackId])의 것을 쓴다. 옛 데이터는 한 줄
  /// 궤적을 연속 구간으로 나눠 앵커 얼굴의 경로만 추린다.
  List<EditorFaceSample> _trackForLayer(EditorStickerLayer layer) {
    if (layer.faceTrackId != null) {
      for (final track in faceTracks) {
        if (track.id == layer.faceTrackId) return track.samples;
      }
    }
    final anchor = faceAnchorFor(layer);
    return anchor == null ? faceTrack : _anchoredFaceTrack(anchor);
  }

  /// 이 원본 시각에 화면에 잡혀 있는 사람들. [near]를 주면 그 화면 위치에
  /// 가까운 순으로, 없으면 얼굴이 큰(가까이 있는) 순으로 돌려준다.
  ///
  /// "잡혀 있다"는 궤적 범위 ± 여유 안이라는 뜻이다 — 표본이 250ms
  /// 간격이라 정확히 그 순간 표본이 없어도 사람은 화면에 있다.
  List<EditorFaceTrack> faceTracksAt(int sourceMs, {NormalizedPoint? near}) {
    const toleranceMs = 500;
    final alive = [
      for (final track in faceTracks)
        if (track.samples.isNotEmpty &&
            sourceMs >= track.firstMs - toleranceMs &&
            sourceMs <= track.lastMs + toleranceMs)
          track,
    ];
    double rank(EditorFaceTrack track) {
      final sample = _sampleOn(track.samples, sourceMs)!;
      if (near == null) return -sample.height;
      final dx = sample.x - near.x;
      final dy = sample.y - near.y;
      return dx * dx + dy * dy;
    }

    alive.sort((a, b) => rank(a).compareTo(rank(b)));
    return alive;
  }

  /// [layer]가 따라가는 얼굴의 이 원본 시각 위치.
  ///
  /// 궤적 전체가 아니라 그 사람의 경로만 본다 — 자리를 비우거나 분석이
  /// 놓친 구간에서는 마지막으로 본 위치 근처에 머문다.
  EditorFaceSample? faceSampleForLayer(EditorStickerLayer layer, int sourceMs) {
    final track = _trackForLayer(layer);
    if (track.isEmpty) return null;
    return _sampleOn(track, sourceMs);
  }

  /// [layer]가 따라가는 얼굴이 화면에 잡혀 있는 **타임라인** 구간.
  /// 스티커는 이 밖으로 나갈 수 없다 — 얼굴이 없는데 따라다닐 수는 없다.
  /// 궤적이 없거나 클립과 겹치지 않으면 null이다.
  ({int startMs, int endMs})? faceCoverageFor(EditorStickerLayer layer) {
    final track = _trackForLayer(layer);
    if (track.isEmpty) return null;
    EditorClip? clip;
    if (layer.clipId != null) {
      for (final candidate in clips) {
        if (candidate.id == layer.clipId) {
          clip = candidate;
          break;
        }
      }
    }
    if (clip == null) {
      // 클립에 안 묶인 옛 스티커 — 타임라인 전체에서 잘라 준다.
      return (
        startMs: timelinePositionForSource(track.first.sourceMs),
        endMs: timelinePositionForSource(track.last.sourceMs),
      );
    }
    final overlapStart = math.max(clip.sourceStartMs, track.first.sourceMs);
    final overlapEnd = math.min(clip.sourceEndMs, track.last.sourceMs);
    if (overlapEnd <= overlapStart) return null;
    final clipTimelineStart = timelineStartFor(clip.id);
    return (
      startMs: clipTimelineStart + overlapStart - clip.sourceStartMs,
      endMs: clipTimelineStart + overlapEnd - clip.sourceStartMs,
    );
  }

  /// 얼굴 크기 배율의 안전 범위. 얼굴 높이 표본은 조명·각도에 따라 흔들려서
  /// 그대로 쓰면 스티커가 숨쉬듯 커졌다 작아진다.
  static const _faceScaleRange = (min: 0.55, max: 1.8);

  /// 스티커 위치·배율에 얼굴 크기와 구간 줌을 입힌다.
  ///
  /// 위치 = 얼굴 중심 + 끌어 둔 오프셋을 줌과 같은 식(p' = f + (p−f)·s)으로
  /// 옮긴 자리. 배율 = 얼굴이 앵커 순간보다 커진 비율 × 줌 배율 — 사람이
  /// 다가오거나 화면이 확대되면 스티커도 같이 커진다.
  ({NormalizedPoint position, double scale}) _composeFacePlacement(
    EditorStickerLayer layer,
    EditorFaceSample face,
    EditorFaceSample? anchorSample,
    EditorZoomSegment? zoom,
  ) {
    var x = face.x + layer.position.x - 0.5;
    var y = face.y + layer.position.y - 0.5;
    var scale = 1.0;
    final anchorHeight = anchorSample?.height ?? 0.0;
    if (anchorHeight > 0 && face.height > 0) {
      scale = (face.height / anchorHeight).clamp(
        _faceScaleRange.min,
        _faceScaleRange.max,
      );
    }
    if (zoom != null) {
      x = zoom.focus.x + (x - zoom.focus.x) * zoom.scale;
      y = zoom.focus.y + (y - zoom.focus.y) * zoom.scale;
      scale *= zoom.scale;
    }
    return (
      position: NormalizedPoint(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)),
      scale: scale,
    );
  }

  /// 이 타임라인 순간 얼굴 추적 스티커가 놓일 화면 위치와 배율 계수.
  /// 미리보기가 프레임마다 부르고, 내보내기도 같은 식으로 굽는다 —
  /// 화면에서 본 그대로 저장되는 것은 이 공유 계산 덕분이다.
  ({NormalizedPoint position, double scale})? faceStickerPlacementAt(
    EditorStickerLayer layer,
    int timelineMs,
  ) {
    final sourceMs = sourcePositionForTimeline(timelineMs);
    if (sourceMs == null) return null;
    final track = _trackForLayer(layer);
    final face = _sampleOn(track, sourceMs);
    if (face == null) return null;
    final anchor = faceAnchorFor(layer);
    final anchorSample = anchor == null ? null : _sampleOn(track, anchor);
    return _composeFacePlacement(
      layer,
      face,
      anchorSample,
      zoomAtTimeline(timelineMs),
    );
  }

  /// 얼굴 추적 스티커가 내보내기에서 쓸 키프레임. **타임라인 시각** 기준이고,
  /// 끌어 둔 오프셋·얼굴 크기 배율·구간 줌이 미리보기와 같은 식으로 구워져
  /// 있다(`s` = 배율 계수).
  List<Map<String, Object>> _faceTrackForExport(EditorStickerLayer layer) {
    // 미리보기와 같은 눈으로 — 이 스티커가 고른 사람의 경로만 굽는다.
    final track = _trackForLayer(layer);
    if (track.isEmpty) return const [];
    final anchor = faceAnchorFor(layer);
    final anchorSample = anchor == null ? null : _sampleOn(track, anchor);
    final samples = <Map<String, Object>>[];
    var timelineStartMs = 0;
    for (final clip in clips) {
      final times = <int>{
        for (final sample in track)
          if (sample.sourceMs >= clip.sourceStartMs &&
              sample.sourceMs <= clip.sourceEndMs)
            sample.sourceMs,
      };
      if (times.isEmpty) {
        timelineStartMs += clip.durationMs;
        continue;
      }
      // 줌 경계 직전·직후 키프레임. 없으면 영상은 그 순간 확대되는데
      // 스티커는 다음 표본까지 250ms에 걸쳐 미끄러진다.
      for (final zoom in zoomSegments) {
        if (!zoom.worksIn(clip)) continue;
        for (final boundary in [zoom.sourceStartMs, zoom.sourceEndMs]) {
          for (final t in [boundary - 1, boundary]) {
            if (t >= clip.sourceStartMs && t <= clip.sourceEndMs) times.add(t);
          }
        }
      }
      final sorted = times.toList()..sort();
      for (final sourceMs in sorted) {
        EditorZoomSegment? zoom;
        for (final candidate in zoomSegments.reversed) {
          if (candidate.worksIn(clip) &&
              sourceMs >= candidate.sourceStartMs &&
              sourceMs < candidate.sourceEndMs) {
            zoom = candidate;
            break;
          }
        }
        final placed = _composeFacePlacement(
          layer,
          _sampleOn(track, sourceMs)!,
          anchorSample,
          zoom,
        );
        samples.add({
          'ms': timelineStartMs + sourceMs - clip.sourceStartMs,
          'x': placed.position.x,
          'y': placed.position.y,
          's': placed.scale,
        });
      }
      timelineStartMs += clip.durationMs;
    }
    return samples;
  }

  EditorProject copyWith({
    List<EditorClip>? clips,
    EditorCanvas? canvas,
    List<EditorTextLayer>? textLayers,
    List<EditorZoomSegment>? zoomSegments,
    List<EditorStickerLayer>? stickerLayers,
    List<EditorBlurLayer>? blurLayers,
    List<EditorFaceSample>? faceTrack,
    List<EditorFaceTrack>? faceTracks,
    EditorAudio? audio,
    EditorLook? look,
    String? arEffectId,
    bool clearArEffect = false,
    EditorTool? selectedTool,
    String? selectedClipId,
    bool clearSelectedClip = false,
    String? selectedLayerId,
    bool clearSelectedLayer = false,
    String? selectedZoomId,
    bool clearSelectedZoom = false,
    EditorRecommendationMarker? recommendationMarker,
    bool clearRecommendationMarker = false,
    int? playheadMs,
    bool? isPlaying,
    EditorExportState? exportState,
    int? revision,
  }) => EditorProject(
    sourceVideoPath: sourceVideoPath,
    sourceDurationMs: sourceDurationMs,
    sourceSize: sourceSize,
    clips: List.unmodifiable(clips ?? this.clips),
    canvas: canvas ?? this.canvas,
    textLayers: List.unmodifiable(textLayers ?? this.textLayers),
    zoomSegments: List.unmodifiable(zoomSegments ?? this.zoomSegments),
    stickerLayers: List.unmodifiable(stickerLayers ?? this.stickerLayers),
    blurLayers: List.unmodifiable(blurLayers ?? this.blurLayers),
    faceTrack: List.unmodifiable(faceTrack ?? this.faceTrack),
    faceTracks: List.unmodifiable(faceTracks ?? this.faceTracks),
    audio: audio ?? this.audio,
    look: look ?? this.look,
    arEffectId: clearArEffect ? null : arEffectId ?? this.arEffectId,
    selectedTool: selectedTool ?? this.selectedTool,
    selectedClipId: clearSelectedClip
        ? null
        : selectedClipId ?? this.selectedClipId,
    selectedLayerId: clearSelectedLayer
        ? null
        : selectedLayerId ?? this.selectedLayerId,
    selectedZoomId: clearSelectedZoom
        ? null
        : selectedZoomId ?? this.selectedZoomId,
    recommendationMarker: clearRecommendationMarker
        ? null
        : recommendationMarker ?? this.recommendationMarker,
    playheadMs: (playheadMs ?? this.playheadMs).clamp(
      0,
      (clips ?? this.clips).fold(
        0,
        (duration, clip) => duration + clip.durationMs,
      ),
    ),
    isPlaying: isPlaying ?? this.isPlaying,
    exportState: exportState ?? this.exportState,
    revision: revision ?? this.revision,
  );

  /// 편집 상태를 그대로 저장하는 초안 지도. [toPlatformMap]과 달리 줌의
  /// 원본 좌표·클립 귀속까지 담아서, 읽으면 편집을 **그대로 이어서** 할 수
  /// 있다. 서버(editor-api)의 edit-projects에 이 모양으로 저장한다.
  Map<String, Object?> toDraftMap() => {
    'type': 'draft-v1',
    'sourceDurationMs': sourceDurationMs,
    'canvas': canvas.toMap(),
    'clips': [
      for (final clip in clips)
        {
          'id': clip.id,
          'sourceStartMs': clip.sourceStartMs,
          'sourceEndMs': clip.sourceEndMs,
          'automatic': clip.automatic,
          'score': clip.score,
        },
    ],
    'zoomSegments': [
      for (final zoom in zoomSegments)
        {
          'id': zoom.id,
          'sourceStartMs': zoom.sourceStartMs,
          'sourceEndMs': zoom.sourceEndMs,
          'scale': zoom.scale,
          'focusX': zoom.focus.x,
          'focusY': zoom.focus.y,
          'automatic': zoom.automatic,
          'clipId': zoom.clipId,
        },
    ],
    'textLayers': [for (final layer in textLayers) layer.toMap()],
    'stickerLayers': [for (final layer in stickerLayers) layer.toMap()],
    'faceTrack': [for (final sample in faceTrack) sample.toMap()],
    'faceTracks': [for (final track in faceTracks) track.toMap()],
    'audio': {'sourceVolume': audio.sourceVolume, 'muted': audio.muted},
    'look': look.name,
    if (recommendationMarker case final marker?)
      'recommendationMarker': {
        'preset': marker.preset,
        'sourceStartMs': marker.sourceStartMs,
        'sourceEndMs': marker.sourceEndMs,
      },
  };

  Map<String, Object?> toPlatformMap({
    required String outputPath,
    List<Map<String, Object>> captions = const [],
  }) {
    var timelineStartMs = 0;
    final clipMaps = <Map<String, Object?>>[];
    final zoomMaps = <Map<String, Object?>>[];
    for (final clip in clips) {
      clipMaps.add(clip.toMap(timelineStartMs: timelineStartMs));
      for (final zoom in zoomSegments) {
        if (!zoom.worksIn(clip)) continue;
        final overlapStart = math.max(clip.sourceStartMs, zoom.sourceStartMs);
        final overlapEnd = math.min(clip.sourceEndMs, zoom.sourceEndMs);
        if (overlapEnd > overlapStart) {
          zoomMaps.add({
            'startMs': timelineStartMs + overlapStart - clip.sourceStartMs,
            'endMs': timelineStartMs + overlapEnd - clip.sourceStartMs,
            'scale': zoom.scale,
            'focusX': zoom.focus.x,
            'focusY': zoom.focus.y,
          });
        }
      }
      timelineStartMs += clip.durationMs;
    }
    return {
      'sourceVideoPath': sourceVideoPath,
      'sourceDurationMs': sourceDurationMs,
      'sourceSize': sourceSize.toMap(),
      'outputPath': outputPath,
      'clips': clipMaps,
      'canvas': canvas.toMap(),
      'durationPreset': recommendationMarker?.preset,
      'textLayers': textLayers.map((layer) => layer.toMap()).toList(),
      'zoomSegments': zoomMaps,
      'stickerLayers': [
        for (final layer in stickerLayers)
          {
            ...layer.toMap(),
            // 얼굴 추적 스티커는 프레임별 위치 키프레임을 함께 넘긴다.
            // 네이티브(EditorLayerOverlay.kt)가 보간해 얼굴을 따라 그린다.
            if (layer.tracksFace) 'track': _faceTrackForExport(layer),
          },
      ],
      'blurLayers': blurLayers.map((layer) => layer.toMap()).toList(),
      'audio': audio.toMap(),
      'look': look.name,
      'captions': captions,
    };
  }
}

/// 미리보기가 캔버스를 **얼마나** 보여 줄지 정하는 기하.
///
/// 세로 캔버스(9:16)에 가로 영상을 contain으로 담으면 위아래가 검은
/// 여백으로 남는다. 작은 휴대폰 화면에서 그 여백을 항상 전부 그리면 정작
/// 영상은 손바닥만 해진다. 그래서 편집 중에는 캔버스를 **폭에 맞춰** 그리고,
/// 세로로 넘치는 검은 여백은 잘라 보여 준다 — 저장 결과가 달라지는 것이
/// 아니라 화면에 그리는 범위만 다르다.
///
/// 전체 캔버스를 그대로 보여 줘야 하는 경우는 잘라내지 않는다.
/// * 캔버스 탭 — 출력 비율 자체를 고르는 자리다.
/// * 검은 여백에 걸친 글자·스티커가 지금 보일 때 — 잘라 버리면 그 레이어를
///   만질 수 없다.
class EditorPreviewGeometry {
  const EditorPreviewGeometry._({
    required this.canvasAspectRatio,
    required this.videoHeightFraction,
    required this.letterboxClippable,
  });

  factory EditorPreviewGeometry.of(EditorProject project) {
    final canvas = project.canvas;
    final aspect = canvas.aspectRatio;
    final source = canvas.sourceAspectRatio;
    final letterboxed =
        canvas.fit == EditorCanvasFit.contain && source > aspect + 0.001;
    final videoHeightFraction = letterboxed
        ? (aspect / source).clamp(0.05, 1.0).toDouble()
        : 1.0;
    return EditorPreviewGeometry._(
      canvasAspectRatio: aspect,
      videoHeightFraction: videoHeightFraction,
      // 검은 여백은 더 이상 잘라 숨기지 않는다. 9:16은 사용자가 일부러
      // 고른 숏폼 구도이고, 위아래 검은 띠는 자막을 놓는 자리다 — 잘라
      // 버리면 그 자리를 보면서 편집할 수 없다.
      letterboxClippable: false,
    );
  }

  /// 잘라 보여 줄 때도 영상 창 위아래에 남기는 문맥 띠 배율.
  /// 1.16이면 영상 높이의 8%씩을 검은 여백으로 남겨 "캔버스가 더 있다"는
  /// 사실이 보이게 한다.
  static const _contextFactor = 1.16;

  final double canvasAspectRatio;

  /// 캔버스 높이에서 가로 영상 창이 차지하는 비율. 여백이 없으면 1이다.
  final double videoHeightFraction;

  /// 위아래 검은 여백을 잘라 보여 줘도 되는가.
  final bool letterboxClippable;

  /// 잘라 보여 줄 때 반드시 남기는 캔버스 높이 비율(영상 창 + 문맥 띠).
  double get minimumVisibleHeightFraction => letterboxClippable
      ? math.min(1.0, videoHeightFraction * _contextFactor)
      : 1.0;
}
