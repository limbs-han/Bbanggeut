import 'dart:math' as math;
import 'dart:ui';

enum EditorTool { cut, ratio, text, audio, sticker, ar }

enum EditorCanvasRatio { original, vertical, landscape, square, portrait }

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

  bool isVisibleAt(int positionMs) =>
      positionMs >= startMs && positionMs < endMs;
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
    this.backgroundColor = const Color(0x99000000),
    this.fontSize = 42,
    this.bold = true,
  });

  final String text;
  final Color color;
  final Color backgroundColor;
  final double fontSize;
  final bool bold;

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
  };
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

  Map<String, Object> toMap() => {
    'id': id,
    'value': value,
    'position': position.toMap(),
    'startMs': startMs,
    'endMs': endMs,
    'scale': scale,
    'rotationDegrees': rotationDegrees,
  };
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
  final EditorTool selectedTool;
  final String? selectedClipId;
  final String? selectedLayerId;
  final int playheadMs;
  final bool isPlaying;
  final EditorExportState exportState;
  final int revision;

  int get durationMs =>
      clips.fold(0, (duration, clip) => duration + clip.durationMs);

  EditorClip? get selectedClip {
    final id = selectedClipId;
    if (id == null) return null;
    for (final clip in clips) {
      if (clip.id == id) return clip;
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
      'captions': captions,
    };
  }
}
