import 'dart:math' as math;
import 'dart:ui';

/// 하단 네비게이션의 편집 도구. 나열 순서가 화면에 그려지는 순서다 —
/// `aiCaption`은 요청대로 `ar` 바로 왼쪽에 온다.
enum EditorTool { cut, ratio, text, audio, sticker, effect, aiCaption, ar }

enum EditorCanvasRatio { original, vertical, landscape, square, portrait }

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
  });

  final String id;
  final String sourcePath;
  final int sourceStartMs;
  final int sourceEndMs;
  final String? arEffectId;

  int get durationMs => math.max(0, sourceEndMs - sourceStartMs);

  EditorClip copyWith({
    String? id,
    int? sourceStartMs,
    int? sourceEndMs,
    String? arEffectId,
    bool clearArEffect = false,
  }) => EditorClip(
    id: id ?? this.id,
    sourcePath: sourcePath,
    sourceStartMs: sourceStartMs ?? this.sourceStartMs,
    sourceEndMs: sourceEndMs ?? this.sourceEndMs,
    arEffectId: clearArEffect ? null : arEffectId ?? this.arEffectId,
  );

  Map<String, Object?> toMap({required int timelineStartMs}) => {
    'id': id,
    'sourcePath': sourcePath,
    'sourceStartMs': sourceStartMs,
    'sourceEndMs': sourceEndMs,
    'timelineStartMs': timelineStartMs,
    'timelineEndMs': timelineStartMs + durationMs,
    'arEffectId': arEffectId,
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
      other.arEffectId == arEffectId;

  @override
  int get hashCode =>
      Object.hash(id, sourcePath, sourceStartMs, sourceEndMs, arEffectId);
}

class EditorCanvas {
  const EditorCanvas({
    required this.sourceAspectRatio,
    this.ratio = EditorCanvasRatio.original,
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

  EditorCanvas copyWith({
    EditorCanvasRatio? ratio,
    int? outputWidth,
    int? outputHeight,
    double? scale,
    double? offsetX,
    double? offsetY,
    double? rotationDegrees,
    Color? backgroundColor,
  }) => EditorCanvas(
    sourceAspectRatio: sourceAspectRatio,
    ratio: ratio ?? this.ratio,
    outputWidth: outputWidth ?? this.outputWidth,
    outputHeight: outputHeight ?? this.outputHeight,
    scale: (scale ?? this.scale).clamp(1.0, 4.0),
    offsetX: (offsetX ?? this.offsetX).clamp(-1.0, 1.0),
    offsetY: (offsetY ?? this.offsetY).clamp(-1.0, 1.0),
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
    backgroundColor: backgroundColor ?? this.backgroundColor,
  );

  Map<String, Object> toMap() => {
    'ratio': ratio.name,
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
  });

  final String text;
  final Color color;
  final Color backgroundColor;
  final double fontSize;
  final bool bold;
  final bool italic;
  final EditorTextAlign align;

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
  );

  Map<String, Object> toMap() => {
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
      other.align == align;

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
  });

  final String value;

  EditorStickerLayer copyWith({
    String? value,
    NormalizedPoint? position,
    int? startMs,
    int? endMs,
    double? scale,
    double? rotationDegrees,
  }) => EditorStickerLayer(
    id: id,
    value: value ?? this.value,
    position: position ?? this.position,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    scale: (scale ?? this.scale).clamp(0.2, 4.0),
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
  );

  Map<String, Object> toMap() => {
    'id': id,
    'value': value,
    'position': position.toMap(),
    'startMs': startMs,
    'endMs': endMs,
    'scale': scale,
    'rotationDegrees': rotationDegrees,
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
      other.rotationDegrees == rotationDegrees;

  @override
  int get hashCode =>
      Object.hash(id, value, position, startMs, endMs, scale, rotationDegrees);
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

class EditorProject {
  const EditorProject({
    required this.sourceVideoPath,
    required this.sourceDurationMs,
    required this.sourceSize,
    required this.clips,
    required this.canvas,
    this.textLayers = const [],
    this.stickerLayers = const [],
    this.blurLayers = const [],
    this.audio = const EditorAudio(),
    this.look = EditorLook.none,
    this.arEffectId,
    this.selectedTool = EditorTool.cut,
    this.selectedClipId,
    this.selectedLayerId,
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
  final List<EditorStickerLayer> stickerLayers;
  final List<EditorBlurLayer> blurLayers;
  final EditorAudio audio;
  final EditorLook look;

  /// 지금 적용된 앱 안 AR 효과. 패널에서 어느 카드가 켜져 있는지 표시할 때 쓴다.
  final String? arEffectId;

  final EditorTool selectedTool;
  final String? selectedClipId;
  final String? selectedLayerId;
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

  EditorProject copyWith({
    List<EditorClip>? clips,
    EditorCanvas? canvas,
    List<EditorTextLayer>? textLayers,
    List<EditorStickerLayer>? stickerLayers,
    List<EditorBlurLayer>? blurLayers,
    EditorAudio? audio,
    EditorLook? look,
    String? arEffectId,
    bool clearArEffect = false,
    EditorTool? selectedTool,
    String? selectedClipId,
    bool clearSelectedClip = false,
    String? selectedLayerId,
    bool clearSelectedLayer = false,
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
    stickerLayers: List.unmodifiable(stickerLayers ?? this.stickerLayers),
    blurLayers: List.unmodifiable(blurLayers ?? this.blurLayers),
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

  /// 얼굴 마스크를 구운 중간 파일을 **새 원본**으로 삼는다.
  ///
  /// Banuba는 컷 편집이 정한 조각들을 순서대로 이어 붙여 한 편으로 굽는다.
  /// 그래서 이 파일은 이미 잘려 있고, 남은 일(글자·스티커·색감·자막·비율·소리)만
  /// media3가 얹으면 된다 — 조각은 파일 전체 하나로 되돌린다.
  ///
  /// **레이어 시각은 그대로 둔다.** 글자·스티커·자막은 원본 시각이 아니라
  /// 이어 붙인 **타임라인** 시각을 들고 있고, 이어 붙인 결과가 곧 이 파일이라
  /// 옮길 것이 없다. 여기서 손대면 자막이 통째로 밀린다.
  ///
  /// [durationMs]와 [size]는 구워진 파일에서 실제로 읽은 값이다. 프레임 경계
  /// 때문에 요청한 길이와 몇 ms 다를 수 있어서 짐작하지 않는다.
  EditorProject withBakedSource({
    required String path,
    required int durationMs,
    required EditorSourceSize size,
  }) => EditorProject(
    sourceVideoPath: path,
    sourceDurationMs: durationMs,
    sourceSize: size,
    clips: List.unmodifiable([
      EditorClip(
        id: 'clip-baked',
        sourcePath: path,
        sourceStartMs: 0,
        sourceEndMs: durationMs,
      ),
    ]),
    canvas: canvas,
    textLayers: textLayers,
    stickerLayers: stickerLayers,
    blurLayers: blurLayers,
    audio: audio,
    look: look,
    arEffectId: arEffectId,
    selectedTool: selectedTool,
    selectedClipId: 'clip-baked',
    selectedLayerId: selectedLayerId,
    playheadMs: playheadMs.clamp(0, durationMs),
    isPlaying: isPlaying,
    exportState: exportState,
    revision: revision,
  );

  Map<String, Object?> toPlatformMap({
    required String outputPath,
    List<Map<String, Object>> captions = const [],
  }) {
    var timelineStartMs = 0;
    final clipMaps = <Map<String, Object?>>[];
    for (final clip in clips) {
      clipMaps.add(clip.toMap(timelineStartMs: timelineStartMs));
      timelineStartMs += clip.durationMs;
    }
    return {
      'sourceVideoPath': sourceVideoPath,
      'sourceDurationMs': sourceDurationMs,
      'sourceSize': sourceSize.toMap(),
      'outputPath': outputPath,
      'clips': clipMaps,
      'canvas': canvas.toMap(),
      'textLayers': textLayers.map((layer) => layer.toMap()).toList(),
      'stickerLayers': stickerLayers.map((layer) => layer.toMap()).toList(),
      'blurLayers': blurLayers.map((layer) => layer.toMap()).toList(),
      'audio': audio.toMap(),
      'look': look.name,
      'captions': captions,
    };
  }
}
