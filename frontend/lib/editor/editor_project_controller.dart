import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'editor_project.dart';

class EditorProjectController extends ChangeNotifier {
  EditorProjectController(this._project);

  static const minimumClipDurationMs = 100;
  static const _historyLimit = 60;

  EditorProject _project;
  final List<EditorProject> _undoStack = [];
  final List<EditorProject> _redoStack = [];
  int _idSeed = 1;
  EditorProject? _canvasGestureOrigin;

  EditorProject get project => _project;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void selectTool(EditorTool tool) {
    if (_project.selectedTool == tool) return;
    _project = _project.copyWith(selectedTool: tool);
    notifyListeners();
  }

  void selectClip(String clipId) {
    if (!_project.clips.any((clip) => clip.id == clipId)) return;
    _project = _project.copyWith(
      selectedClipId: clipId,
      clearSelectedLayer: true,
    );
    notifyListeners();
  }

  bool splitAt(int timelinePositionMs) {
    final location = _locateTimelinePosition(timelinePositionMs);
    if (location == null) return false;
    final clip = location.clip;
    final sourceSplitMs = clip.sourceStartMs + location.offsetMs;
    if (sourceSplitMs - clip.sourceStartMs < minimumClipDurationMs ||
        clip.sourceEndMs - sourceSplitMs < minimumClipDurationMs) {
      return false;
    }
    final left = clip.copyWith(id: _nextId('clip'), sourceEndMs: sourceSplitMs);
    final right = clip.copyWith(
      id: _nextId('clip'),
      sourceStartMs: sourceSplitMs,
    );
    final next = [..._project.clips]
      ..removeAt(location.index)
      ..insertAll(location.index, [left, right]);
    _commit(
      _project.copyWith(
        clips: next,
        selectedClipId: right.id,
        playheadMs: timelinePositionMs,
      ),
    );
    return true;
  }

  bool deleteSelectedClip() {
    final selected = _project.selectedClip;
    if (selected == null || _project.clips.length <= 1) return false;
    final index = _project.clips.indexWhere((clip) => clip.id == selected.id);
    final next = [..._project.clips]..removeAt(index);
    final nextIndex = math.min(index, next.length - 1);
    _commit(
      _project.copyWith(
        clips: next,
        selectedClipId: next[nextIndex].id,
        playheadMs: math.min(_project.playheadMs, _durationOf(next)),
      ),
    );
    return true;
  }

  bool duplicateSelectedClip() {
    final selected = _project.selectedClip;
    if (selected == null) return false;
    final index = _project.clips.indexWhere((clip) => clip.id == selected.id);
    final copy = selected.copyWith(id: _nextId('clip'));
    final next = [..._project.clips]..insert(index + 1, copy);
    _commit(_project.copyWith(clips: next, selectedClipId: copy.id));
    return true;
  }

  bool trimSelectedClip({int? sourceStartMs, int? sourceEndMs}) {
    final selected = _project.selectedClip;
    if (selected == null) return false;
    final start = (sourceStartMs ?? selected.sourceStartMs).clamp(
      0,
      _project.sourceDurationMs,
    );
    final end = (sourceEndMs ?? selected.sourceEndMs).clamp(
      0,
      _project.sourceDurationMs,
    );
    if (end - start < minimumClipDurationMs) return false;
    final index = _project.clips.indexWhere((clip) => clip.id == selected.id);
    final next = [..._project.clips]
      ..[index] = selected.copyWith(sourceStartMs: start, sourceEndMs: end);
    _commit(
      _project.copyWith(
        clips: next,
        playheadMs: math.min(_project.playheadMs, _durationOf(next)),
      ),
    );
    return true;
  }

  void setCanvasRatio(EditorCanvasRatio ratio) {
    if (_project.canvas.ratio == ratio) return;
    _commit(_project.copyWith(canvas: _project.canvas.copyWith(ratio: ratio)));
  }

  void setCanvasTransform({
    required double scale,
    required double offsetX,
    required double offsetY,
    required double rotationDegrees,
  }) {
    final next = _project.canvas.copyWith(
      scale: scale,
      offsetX: offsetX,
      offsetY: offsetY,
      rotationDegrees: rotationDegrees,
    );
    _commit(_project.copyWith(canvas: next));
  }

  void resetCanvasTransform() {
    setCanvasTransform(scale: 1, offsetX: 0, offsetY: 0, rotationDegrees: 0);
  }

  void setSourceVolume(double volume) {
    _commit(
      _project.copyWith(
        audio: _project.audio.copyWith(sourceVolume: volume, muted: false),
      ),
    );
  }

  void beginCanvasGesture() {
    _canvasGestureOrigin ??= _project;
  }

  void updateCanvasGesture({
    required double scale,
    required double offsetX,
    required double offsetY,
    required double rotationDegrees,
  }) {
    _project = _project.copyWith(
      canvas: _project.canvas.copyWith(
        scale: scale,
        offsetX: offsetX,
        offsetY: offsetY,
        rotationDegrees: rotationDegrees,
      ),
    );
    notifyListeners();
  }

  void endCanvasGesture() {
    final origin = _canvasGestureOrigin;
    _canvasGestureOrigin = null;
    if (origin == null ||
        origin.canvas.scale == _project.canvas.scale &&
            origin.canvas.offsetX == _project.canvas.offsetX &&
            origin.canvas.offsetY == _project.canvas.offsetY &&
            origin.canvas.rotationDegrees == _project.canvas.rotationDegrees) {
      return;
    }
    _undoStack.add(origin);
    if (_undoStack.length > _historyLimit) _undoStack.removeAt(0);
    _redoStack.clear();
    _project = _project.copyWith(revision: origin.revision + 1);
    notifyListeners();
  }

  void setMuted(bool muted) {
    _commit(_project.copyWith(audio: _project.audio.copyWith(muted: muted)));
  }

  void addTextLayer({required String text, int? startMs, int? endMs}) {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;
    final layer = EditorTextLayer(
      id: _nextId('text'),
      text: cleanText,
      position: NormalizedPoint(0.5, 0.78),
      startMs: startMs ?? _project.playheadMs,
      endMs: endMs ?? _project.durationMs,
    );
    _commit(
      _project.copyWith(
        textLayers: [..._project.textLayers, layer],
        selectedLayerId: layer.id,
      ),
    );
  }

  void addSticker(String value) {
    if (value.isEmpty) return;
    final layer = EditorStickerLayer(
      id: _nextId('sticker'),
      value: value,
      position: NormalizedPoint.center,
      startMs: _project.playheadMs,
      endMs: _project.durationMs,
    );
    _commit(
      _project.copyWith(
        stickerLayers: [..._project.stickerLayers, layer],
        selectedLayerId: layer.id,
      ),
    );
  }

  bool moveSelectedLayer(NormalizedPoint position) {
    final selected = _project.selectedLayerId;
    if (selected == null) return false;
    final texts = [
      for (final layer in _project.textLayers)
        if (layer.id == selected)
          EditorTextLayer(
            id: layer.id,
            text: layer.text,
            position: position,
            startMs: layer.startMs,
            endMs: layer.endMs,
            scale: layer.scale,
            rotationDegrees: layer.rotationDegrees,
            color: layer.color,
            backgroundColor: layer.backgroundColor,
            fontSize: layer.fontSize,
            bold: layer.bold,
          )
        else
          layer,
    ];
    final stickers = [
      for (final layer in _project.stickerLayers)
        if (layer.id == selected)
          EditorStickerLayer(
            id: layer.id,
            value: layer.value,
            position: position,
            startMs: layer.startMs,
            endMs: layer.endMs,
            scale: layer.scale,
            rotationDegrees: layer.rotationDegrees,
          )
        else
          layer,
    ];
    if (listEquals(texts, _project.textLayers) &&
        listEquals(stickers, _project.stickerLayers)) {
      return false;
    }
    _commit(_project.copyWith(textLayers: texts, stickerLayers: stickers));
    return true;
  }

  bool deleteSelectedLayer() {
    final selected = _project.selectedLayerId;
    if (selected == null) return false;
    final texts = _project.textLayers
        .where((layer) => layer.id != selected)
        .toList();
    final stickers = _project.stickerLayers
        .where((layer) => layer.id != selected)
        .toList();
    final blurs = _project.blurLayers
        .where((layer) => layer.id != selected)
        .toList();
    if (texts.length == _project.textLayers.length &&
        stickers.length == _project.stickerLayers.length &&
        blurs.length == _project.blurLayers.length) {
      return false;
    }
    _commit(
      _project.copyWith(
        textLayers: texts,
        stickerLayers: stickers,
        blurLayers: blurs,
        clearSelectedLayer: true,
      ),
    );
    return true;
  }

  void setPlayhead(int positionMs, {bool notify = true}) {
    final next = positionMs.clamp(0, _project.durationMs);
    if (_project.playheadMs == next) return;
    _project = _project.copyWith(playheadMs: next);
    if (notify) notifyListeners();
  }

  void setPlaying(bool playing) {
    if (_project.isPlaying == playing) return;
    _project = _project.copyWith(isPlaying: playing);
    notifyListeners();
  }

  void setExportState(EditorExportState state) {
    _project = _project.copyWith(exportState: state);
    notifyListeners();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_project);
    _project = _undoStack.removeLast();
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_project);
    _project = _redoStack.removeLast();
    notifyListeners();
  }

  void _commit(EditorProject next) {
    _undoStack.add(_project);
    if (_undoStack.length > _historyLimit) _undoStack.removeAt(0);
    _redoStack.clear();
    _project = next.copyWith(revision: _project.revision + 1);
    notifyListeners();
  }

  _TimelineLocation? _locateTimelinePosition(int timelinePositionMs) {
    if (_project.clips.isEmpty) return null;
    final target = timelinePositionMs.clamp(0, _project.durationMs);
    var timelineStartMs = 0;
    for (var index = 0; index < _project.clips.length; index++) {
      final clip = _project.clips[index];
      final timelineEndMs = timelineStartMs + clip.durationMs;
      if (target >= timelineStartMs && target <= timelineEndMs) {
        return _TimelineLocation(
          index: index,
          clip: clip,
          offsetMs: (target - timelineStartMs).clamp(0, clip.durationMs),
        );
      }
      timelineStartMs = timelineEndMs;
    }
    return null;
  }

  int _durationOf(List<EditorClip> clips) =>
      clips.fold(0, (duration, clip) => duration + clip.durationMs);

  String _nextId(String prefix) => '$prefix-${_idSeed++}';
}

class _TimelineLocation {
  const _TimelineLocation({
    required this.index,
    required this.clip,
    required this.offsetMs,
  });

  final int index;
  final EditorClip clip;
  final int offsetMs;
}
