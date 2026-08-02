import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'editor_ar_effects.dart';
import 'edit_recommendation_client.dart';
import 'editor_project.dart';

class EditorProjectController extends ChangeNotifier {
  EditorProjectController(this._project);

  static const minimumClipDurationMs = 100;
  static const _historyLimit = 60;

  /// AR 효과가 놓은 스티커의 id 앞에 붙는다. 효과를 바꾸거나 지울 때 사용자가
  /// 손으로 놓은 스티커는 남기고 이것만 걷어낸다.
  static const _arLayerPrefix = 'ar-sticker-';

  EditorProject _project;
  final List<EditorProject> _undoStack = [];
  final List<EditorProject> _redoStack = [];
  int _idSeed = 1;

  /// 한 번의 손가락 동작이 시작될 때의 스냅샷.
  ///
  /// **왜 하나로 묶는가**: 예전에는 구간 손잡이를 끌면 프레임마다 `_commit`이
  /// 돌아 되돌리기 이력이 1ms짜리로 60칸을 가득 채웠다. 그래서 "되돌리기"를
  /// 눌러도 화면이 거의 그대로였다. 이제 손가락을 뗄 때 한 칸만 쌓는다.
  EditorProject? _gestureOrigin;

  EditorProject get project => _project;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  bool get canDeleteSelectedClip {
    final selected = _project.selectedClip;
    if (selected == null) return false;
    return _project.clips.length > 1 ||
        selected.sourceStartMs > 0 ||
        selected.sourceEndMs < _project.sourceDurationMs;
  }

  /// 지금 재생 위치에서 분할이 가능한지. 버튼을 눌러 보고 실패 안내를 띄우는
  /// 대신 미리 흐리게 만들어 "왜 안 되지"를 없앤다.
  bool get canSplitAtPlayhead {
    final location = _locateTimelinePosition(_project.playheadMs);
    if (location == null) return false;
    final clip = location.clip;
    final sourceSplitMs = clip.sourceStartMs + location.offsetMs;
    return sourceSplitMs - clip.sourceStartMs >= minimumClipDurationMs &&
        clip.sourceEndMs - sourceSplitMs >= minimumClipDurationMs;
  }

  /// 고른 클립 구간의 가운데(타임라인 기준). 고른 클립이 없으면 null.
  ///
  /// **왜 이게 필요한가**: 구간을 정한 직후 재생 위치는 구간 맨 앞에 붙어
  /// 있었다. 그러면 앞쪽에 남는 길이가 0이라 [canSplitAtPlayhead]가 false이고,
  /// **분할 단추가 편집기를 연 순간부터 흐려져 있었다** — 눌러도 아무 일이
  /// 없던 정체다. 가운데로 들이면 어느 쪽으로도 자를 수 있고, 남길 구간을
  /// 대표하는 프레임이 미리보기에 뜬다.
  int? timelineCenterOfSelectedClip() {
    final selected = _project.selectedClip;
    if (selected == null) return null;
    return _project.timelineStartFor(selected.id) + selected.durationMs ~/ 2;
  }

  /// 선택 클립을 더 잘라낼 여유가 있는지. 트림 손잡이를 흐리게 할 때 쓴다.
  bool get canTrimSelectedClip {
    final selected = _project.selectedClip;
    return selected != null && selected.durationMs > minimumClipDurationMs;
  }

  void selectTool(EditorTool tool) {
    if (_project.selectedTool == tool) return;
    _project = _project.copyWith(selectedTool: tool);
    notifyListeners();
  }

  void applyRecommendation(EditRecommendation recommendation) {
    final start = recommendation.cutStartMs.clamp(0, _project.sourceDurationMs);
    final end = recommendation.cutEndMs.clamp(
      start + minimumClipDurationMs,
      _project.sourceDurationMs,
    );
    final clip = EditorClip(
      id: _nextId('clip'),
      sourcePath: _project.sourceVideoPath,
      sourceStartMs: start,
      sourceEndMs: end,
      automatic: true,
    );
    final zooms = recommendation.zoomSegments.indexed
        .map((entry) {
          final value = entry.$2;
          return EditorZoomSegment(
            id: 'auto-zoom-${entry.$1}',
            sourceStartMs: (value['startMs'] as num).round(),
            sourceEndMs: (value['endMs'] as num).round(),
            scale: (value['scale'] as num).toDouble(),
            focus: NormalizedPoint(
              (value['focusX'] as num).toDouble(),
              (value['focusY'] as num).toDouble(),
            ),
            automatic: true,
          );
        })
        .toList(growable: false);
    _commit(
      _project.copyWith(
        clips: [clip],
        zoomSegments: zooms,
        selectedZoomId: zooms.isEmpty ? null : zooms.first.id,
        selectedClipId: clip.id,
        playheadMs: 0,
      ),
    );
  }

  void addZoomAtPlayhead() {
    final sourceMs = _project.sourcePositionForTimeline(_project.playheadMs);
    if (sourceMs == null) return;
    final start = math.max(0, sourceMs - 1000);
    final end = math.min(_project.sourceDurationMs, sourceMs + 2000);
    final zoom = EditorZoomSegment(
      id: _nextId('zoom'),
      sourceStartMs: start,
      sourceEndMs: end,
      scale: 1.35,
      focus: NormalizedPoint.center,
    );
    _commit(
      _project.copyWith(
        zoomSegments: [..._project.zoomSegments, zoom],
        selectedZoomId: zoom.id,
      ),
    );
  }

  void selectZoom(String zoomId) {
    EditorZoomSegment? zoom;
    for (final item in _project.zoomSegments) {
      if (item.id == zoomId) zoom = item;
    }
    if (zoom == null) return;
    var timelineStart = 0;
    for (final clip in _project.clips) {
      if (zoom.sourceStartMs >= clip.sourceStartMs &&
          zoom.sourceStartMs < clip.sourceEndMs) {
        _project = _project.copyWith(
          selectedZoomId: zoomId,
          selectedClipId: clip.id,
          playheadMs: timelineStart + zoom.sourceStartMs - clip.sourceStartMs,
        );
        notifyListeners();
        return;
      }
      timelineStart += clip.durationMs;
    }
  }

  void updateZoom(EditorZoomSegment segment) {
    final next = _project.zoomSegments
        .map((item) => item.id == segment.id ? segment : item)
        .toList(growable: false);
    _commit(_project.copyWith(zoomSegments: next));
  }

  void removeZoom(EditorZoomSegment segment) {
    _commit(
      _project.copyWith(
        zoomSegments: _project.zoomSegments
            .where((item) => item.id != segment.id)
            .toList(),
        clearSelectedZoom: _project.selectedZoomId == segment.id,
      ),
    );
  }

  void reorderClip(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _project.clips.length) return;
    if (newIndex == oldIndex ||
        newIndex < 0 ||
        newIndex >= _project.clips.length) {
      return;
    }
    final next = [..._project.clips];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    _commit(
      _project.copyWith(clips: next, selectedClipId: moved.id, playheadMs: 0),
    );
  }

  void selectClip(String clipId) {
    if (!_project.clips.any((clip) => clip.id == clipId)) return;
    _project = _project.copyWith(
      selectedClipId: clipId,
      clearSelectedLayer: true,
    );
    notifyListeners();
  }

  /// 타임라인에서 어느 시각을 짚었을 때 그 자리의 클립을 고른다.
  void selectClipAtTimeline(int timelineMs) {
    final location = _locateTimelinePosition(timelineMs);
    if (location == null) return;
    selectClip(location.clip.id);
  }

  /// 글자·스티커 레이어를 고른다.
  ///
  /// **클립 선택은 건드리지 않는다.** 예전에는 여기서 선택 클립을 지웠는데,
  /// 그러면 텍스트를 한 번 만진 뒤로는 컷 편집의 분할·삭제·복제가 전부
  /// 조용히 실패했다(선택 클립이 없으니 전부 false를 돌려준다).
  void selectLayer(String layerId) {
    final exists =
        _project.textLayers.any((layer) => layer.id == layerId) ||
        _project.stickerLayers.any((layer) => layer.id == layerId);
    if (!exists || _project.selectedLayerId == layerId) return;
    _project = _project.copyWith(selectedLayerId: layerId);
    notifyListeners();
  }

  /// 영상 빈 곳을 눌렀을 때. 조절 손잡이를 감춘다.
  void deselectLayer() {
    if (_project.selectedLayerId == null) return;
    _project = _project.copyWith(clearSelectedLayer: true);
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
    if (selected == null || !canDeleteSelectedClip) return false;
    if (_project.clips.length == 1) {
      final remaining = <EditorClip>[
        if (selected.sourceStartMs >= minimumClipDurationMs)
          selected.copyWith(
            id: _nextId('clip'),
            sourceStartMs: 0,
            sourceEndMs: selected.sourceStartMs,
          ),
        if (_project.sourceDurationMs - selected.sourceEndMs >=
            minimumClipDurationMs)
          selected.copyWith(
            id: _nextId('clip'),
            sourceStartMs: selected.sourceEndMs,
            sourceEndMs: _project.sourceDurationMs,
          ),
      ];
      if (remaining.isEmpty) return false;
      _commit(
        _project.copyWith(
          clips: remaining,
          selectedClipId: remaining.first.id,
          playheadMs: 0,
        ),
      );
      return true;
    }
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

  /// 선택 클립의 구간을 정한다.
  ///
  /// [commit]이 false면 되돌리기 이력에 쌓지 않는다 — 손잡이를 끄는 동안에는
  /// 값만 따라가고, 손가락을 뗄 때 [endGesture]가 한 칸으로 확정한다.
  /// [notify]가 false면 듣는 쪽에 알리지 않는다. 구간 막대는 제 손으로 그리고
  /// 있어서, 매 프레임 편집 화면 전체를 다시 그리면 오히려 끊긴다.
  bool trimSelectedClip({
    int? sourceStartMs,
    int? sourceEndMs,
    bool commit = true,
    bool notify = true,
  }) {
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
    if (start == selected.sourceStartMs && end == selected.sourceEndMs) {
      return true;
    }
    final index = _project.clips.indexWhere((clip) => clip.id == selected.id);
    final next = [..._project.clips]
      ..[index] = selected.copyWith(sourceStartMs: start, sourceEndMs: end);
    final updated = _project.copyWith(
      clips: next,
      playheadMs: math.min(_project.playheadMs, _durationOf(next)),
    );
    if (commit) {
      _commit(updated);
    } else {
      _project = updated;
      if (notify) notifyListeners();
    }
    return true;
  }

  void setCanvasRatio(EditorCanvasRatio ratio) {
    if (_project.canvas.ratio == ratio) return;
    _commit(
      _project.copyWith(
        canvas: _project.canvas.copyWith(
          ratio: ratio,
          scale: 1,
          offsetX: 0,
          offsetY: 0,
          rotationDegrees: 0,
        ),
      ),
    );
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

  /// 볼륨 손잡이를 끄는 동안. 화면은 값을 따라가야 하므로 알리되, 이력은
  /// 손가락을 뗄 때([endGesture]) 한 칸만 쌓는다.
  void setSourceVolume(double volume) {
    beginGesture();
    _project = _project.copyWith(
      audio: _project.audio.copyWith(sourceVolume: volume, muted: false),
    );
    notifyListeners();
  }

  /// 한 번의 손가락 동작을 시작한다. 여러 번 불러도 처음 것만 남는다.
  void beginGesture() {
    _gestureOrigin ??= _project;
  }

  /// 손가락을 뗐다. 시작할 때와 달라진 게 있으면 되돌리기 이력에 한 칸 쌓는다.
  void endGesture() {
    final origin = _gestureOrigin;
    _gestureOrigin = null;
    if (origin == null) return;
    if (_sameEdits(origin, _project)) {
      notifyListeners();
      return;
    }
    _pushUndo(origin);
    _project = _project.copyWith(revision: origin.revision + 1);
    notifyListeners();
  }

  void beginCanvasGesture() => beginGesture();

  /// 영상을 두 손가락으로 벌리거나 옮기는 동안.
  ///
  /// [notify]가 false면 알리지 않는다 — 레이어 조작과 같은 이유다. 조작 중인
  /// 위젯이 제 손으로 그리고, 손을 뗄 때 한 번만 알린다.
  void updateCanvasGesture({
    required double scale,
    required double offsetX,
    required double offsetY,
    required double rotationDegrees,
    bool notify = true,
  }) {
    _project = _project.copyWith(
      canvas: _project.canvas.copyWith(
        scale: scale,
        offsetX: offsetX,
        offsetY: offsetY,
        rotationDegrees: rotationDegrees,
      ),
    );
    if (notify) notifyListeners();
  }

  void endCanvasGesture() => endGesture();

  void setMuted(bool muted) {
    _commit(_project.copyWith(audio: _project.audio.copyWith(muted: muted)));
  }

  void setLook(EditorLook look) {
    if (_project.look == look) return;
    _commit(_project.copyWith(look: look));
  }

  /// 앱 안 AR 효과를 입힌다. 색감과 얼굴 스티커를 한 번에 바꾼다.
  ///
  /// 앞서 켰던 AR 스티커는 걷어내고 새 것으로 갈아 끼운다. 사용자가 스티커
  /// 탭에서 손으로 놓은 것들은 그대로 남는다.
  void applyArEffect(EditorArEffect effect) {
    final kept = _project.stickerLayers
        .where((layer) => !layer.id.startsWith(_arLayerPrefix))
        .toList();
    final timelineEndMs = math.max(_project.durationMs, 1);
    final added = [
      for (final sticker in effect.stickers)
        EditorStickerLayer(
          id: '$_arLayerPrefix${_idSeed++}',
          value: sticker.value,
          position: sticker.position,
          startMs: 0,
          endMs: timelineEndMs,
          scale: sticker.scale,
        ),
    ];
    _commit(
      _project.copyWith(
        stickerLayers: [...kept, ...added],
        look: effect.look,
        arEffectId: effect.id,
        selectedLayerId: added.isEmpty ? null : added.first.id,
        clearSelectedLayer: added.isEmpty,
      ),
    );
  }

  void clearArEffect() {
    final kept = _project.stickerLayers
        .where((layer) => !layer.id.startsWith(_arLayerPrefix))
        .toList();
    if (kept.length == _project.stickerLayers.length &&
        _project.look == EditorLook.none &&
        _project.arEffectId == null) {
      return;
    }
    _commit(
      _project.copyWith(
        stickerLayers: kept,
        look: EditorLook.none,
        clearArEffect: true,
        clearSelectedLayer: true,
      ),
    );
  }

  void addTextLayer({
    required String text,
    int? startMs,
    int? endMs,
    Color color = const Color(0xFFFFFFFF),
    Color backgroundColor = const Color(0x00000000),
    double fontSize = 42,
    bool bold = true,
    bool italic = false,
    EditorTextAlign align = EditorTextAlign.center,
  }) {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;
    final layer = EditorTextLayer(
      id: _nextId('text'),
      text: cleanText,
      position: NormalizedPoint(0.5, 0.78),
      startMs: startMs ?? _project.playheadMs,
      endMs: endMs ?? _project.durationMs,
      color: color,
      backgroundColor: backgroundColor,
      fontSize: fontSize,
      bold: bold,
      italic: italic,
      align: align,
    );
    _commit(
      _project.copyWith(
        textLayers: [..._project.textLayers, layer],
        selectedLayerId: layer.id,
      ),
    );
  }

  /// 아직 글이 없는 글자 레이어를 만들고 그 id를 준다.
  ///
  /// 영상 위에서 바로 타이핑하려면 글이 한 글자도 없는 상태의 레이어가 먼저
  /// 있어야 한다. 이력은 여기서 쌓지 않는다 — 만들기부터 다 쓰고 손을 떼기
  /// 까지가 되돌리기 한 칸이다([endGesture]).
  String beginTextLayer({
    Color color = const Color(0xFFFFFFFF),
    Color backgroundColor = const Color(0x00000000),
    double fontSize = 64,
    bool bold = true,
    bool italic = false,
    EditorTextAlign align = EditorTextAlign.center,
  }) {
    beginGesture();
    final layer = EditorTextLayer(
      id: _nextId('text'),
      text: '',
      position: NormalizedPoint(0.5, 0.5),
      startMs: 0,
      endMs: _project.durationMs,
      color: color,
      backgroundColor: backgroundColor,
      fontSize: fontSize,
      bold: bold,
      italic: italic,
      align: align,
    );
    _project = _project.copyWith(
      textLayers: [..._project.textLayers, layer],
      selectedLayerId: layer.id,
    );
    notifyListeners();
    return layer.id;
  }

  /// 영상 위에서 글자를 고치는 동안. 이력은 [endGesture]가 한 번에 쌓는다.
  void updateTextLayer(
    String id, {
    String? text,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    bool? bold,
    bool? italic,
    EditorTextAlign? align,
  }) {
    var changed = false;
    final texts = [
      for (final layer in _project.textLayers)
        if (layer.id == id)
          (() {
            changed = true;
            return layer.copyWith(
              text: text,
              color: color,
              backgroundColor: backgroundColor,
              fontSize: fontSize,
              bold: bold,
              italic: italic,
              align: align,
            );
          })()
        else
          layer,
    ];
    if (!changed) return;
    _project = _project.copyWith(textLayers: texts);
    notifyListeners();
  }

  /// 레이어 하나를 걷어낸다. 빈 글자로 끝난 편집을 정리할 때 쓴다.
  void removeLayer(String id) {
    final texts = _project.textLayers.where((layer) => layer.id != id).toList();
    final stickers = _project.stickerLayers
        .where((layer) => layer.id != id)
        .toList();
    if (texts.length == _project.textLayers.length &&
        stickers.length == _project.stickerLayers.length) {
      return;
    }
    _project = _project.copyWith(
      textLayers: texts,
      stickerLayers: stickers,
      clearSelectedLayer: _project.selectedLayerId == id,
    );
    notifyListeners();
  }

  void addSticker(String value) {
    if (value.isEmpty) return;
    final layer = EditorStickerLayer(
      id: _nextId('sticker'),
      value: value,
      position: NormalizedPoint.center,
      startMs: 0,
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
        if (layer.id == selected) layer.copyWith(position: position) else layer,
    ];
    final stickers = [
      for (final layer in _project.stickerLayers)
        if (layer.id == selected) layer.copyWith(position: position) else layer,
    ];
    if (listEquals(texts, _project.textLayers) &&
        listEquals(stickers, _project.stickerLayers)) {
      return false;
    }
    _commit(_project.copyWith(textLayers: texts, stickerLayers: stickers));
    return true;
  }

  void beginLayerGesture(String layerId) {
    selectLayer(layerId);
    beginGesture();
  }

  /// 글자·스티커를 끌거나 벌리는 동안.
  ///
  /// [notify]가 false면 듣는 쪽에 알리지 않는다. 조작 중인 레이어 위젯은 제
  /// 손으로 그리고 있어서, 매 프레임 편집 화면(타임라인 썸네일까지)을 통째로
  /// 다시 그리면 손가락을 못 따라온다 — 이게 "부드럽지 않다"의 정체였다.
  void updateSelectedLayerTransform({
    required NormalizedPoint position,
    required double scale,
    required double rotationDegrees,
    bool notify = true,
  }) {
    final selected = _project.selectedLayerId;
    if (selected == null) return;
    final texts = [
      for (final layer in _project.textLayers)
        layer.id == selected
            ? layer.copyWith(
                position: position,
                scale: scale,
                rotationDegrees: rotationDegrees,
              )
            : layer,
    ];
    final stickers = [
      for (final layer in _project.stickerLayers)
        layer.id == selected
            ? layer.copyWith(
                position: position,
                scale: scale,
                rotationDegrees: rotationDegrees,
              )
            : layer,
    ];
    _project = _project.copyWith(textLayers: texts, stickerLayers: stickers);
    if (notify) notifyListeners();
  }

  /// 모서리 손잡이를 한 손가락으로 끌 때. 위치와 회전은 그대로 두고 크기만
  /// 바꾼다. 확정은 [endLayerGesture]가 한다.
  void updateSelectedLayerScale(double scale, {bool notify = true}) {
    final selected = _project.selectedLayerId;
    if (selected == null) return;
    final texts = [
      for (final layer in _project.textLayers)
        layer.id == selected ? layer.copyWith(scale: scale) : layer,
    ];
    final stickers = [
      for (final layer in _project.stickerLayers)
        layer.id == selected ? layer.copyWith(scale: scale) : layer,
    ];
    _project = _project.copyWith(textLayers: texts, stickerLayers: stickers);
    if (notify) notifyListeners();
  }

  void endLayerGesture() => endGesture();

  bool updateSelectedTextLayer({
    required String text,
    required Color color,
    required double fontSize,
    required bool bold,
    Color? backgroundColor,
    bool? italic,
    EditorTextAlign? align,
  }) {
    final selected = _project.selectedLayerId;
    final cleanText = text.trim();
    if (selected == null || cleanText.isEmpty) return false;
    var updated = false;
    final texts = [
      for (final layer in _project.textLayers)
        if (layer.id == selected)
          (() {
            updated = true;
            return layer.copyWith(
              text: cleanText,
              color: color,
              backgroundColor: backgroundColor,
              fontSize: fontSize,
              bold: bold,
              italic: italic,
              align: align,
            );
          })()
        else
          layer,
    ];
    if (!updated) return false;
    _commit(_project.copyWith(textLayers: texts));
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

  /// 한 단계 되돌린다.
  ///
  /// 되돌리는 것은 **편집 결과**뿐이다. 지금 열어 둔 도구 탭이나 저장 진행
  /// 상태까지 옛날 것으로 돌아가면, 텍스트 탭에서 되돌리기를 눌렀을 뿐인데
  /// 컷 편집 탭으로 튕겨 나간다.
  void undo() {
    if (_undoStack.isEmpty) return;
    final current = _project;
    _redoStack.add(current);
    if (_redoStack.length > _historyLimit) _redoStack.removeAt(0);
    _project = _withViewStateOf(_undoStack.removeLast(), current);
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    final current = _project;
    _undoStack.add(current);
    if (_undoStack.length > _historyLimit) _undoStack.removeAt(0);
    _project = _withViewStateOf(_redoStack.removeLast(), current);
    notifyListeners();
  }

  EditorProject _withViewStateOf(
    EditorProject snapshot,
    EditorProject current,
  ) => snapshot.copyWith(
    selectedTool: current.selectedTool,
    exportState: current.exportState,
    isPlaying: false,
    // 옛 재생 위치가 지금 길이보다 길 수 있다. copyWith가 잘라 준다.
    playheadMs: current.playheadMs,
    revision: current.revision + 1,
  );

  void _commit(EditorProject next) {
    _pushUndo(_project);
    _project = next.copyWith(revision: _project.revision + 1);
    notifyListeners();
  }

  void _pushUndo(EditorProject snapshot) {
    _undoStack.add(snapshot);
    if (_undoStack.length > _historyLimit) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  /// 두 스냅샷의 **편집 결과**가 같은가. 고른 클립·재생 위치·열어 둔 탭 같은
  /// 화면 상태는 이력을 만들 이유가 없으므로 비교에서 뺀다.
  bool _sameEdits(EditorProject a, EditorProject b) =>
      listEquals(a.clips, b.clips) &&
      listEquals(a.zoomSegments, b.zoomSegments) &&
      listEquals(a.textLayers, b.textLayers) &&
      listEquals(a.stickerLayers, b.stickerLayers) &&
      listEquals(a.blurLayers, b.blurLayers) &&
      a.canvas.ratio == b.canvas.ratio &&
      a.canvas.scale == b.canvas.scale &&
      a.canvas.offsetX == b.canvas.offsetX &&
      a.canvas.offsetY == b.canvas.offsetY &&
      a.canvas.rotationDegrees == b.canvas.rotationDegrees &&
      a.audio.sourceVolume == b.audio.sourceVolume &&
      a.audio.muted == b.audio.muted &&
      a.look == b.look &&
      a.arEffectId == b.arEffectId;

  _TimelineLocation? _locateTimelinePosition(int timelinePositionMs) {
    if (_project.clips.isEmpty) return null;
    final target = timelinePositionMs.clamp(0, _project.durationMs);
    var timelineStartMs = 0;
    for (var index = 0; index < _project.clips.length; index++) {
      final clip = _project.clips[index];
      final timelineEndMs = timelineStartMs + clip.durationMs;
      final isLast = index == _project.clips.length - 1;
      // **왜 `<`인가**: 이음매(앞 클립의 끝 = 뒤 클립의 시작)를 `<=`로 따지면
      // 그 시각이 앞 클립의 **맨 끝**으로 잡힌다. 뒤 클립의 시작을 짚었는데도
      // 앞 클립이 골라지고, 남는 길이가 0이라 분할도 막힌다. 마지막 클립만
      // 예외로 끝 시각을 품는다.
      if (target < timelineEndMs || isLast) {
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
