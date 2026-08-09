import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'editor_ar_effects.dart';
import 'edit_recommendation_client.dart';
import 'editor_project.dart';

class EditorProjectController extends ChangeNotifier {
  EditorProjectController(this._project);

  static const minimumClipDurationMs = 100;

  /// 자동 줌이 노리는 얼굴 크기 — 화면 높이의 몇 할을 얼굴이 차지할지.
  ///
  /// **이 값 하나가 자동 줌의 세기다.** 서버는 0.28~0.33을 노리는데 작은
  /// 휴대폰 화면에서는 확대한 티가 안 나서, 화면의 45%까지 끌어올린다.
  /// 다만 가장자리에 선 얼굴은 서버가 주는 `maxScale`이 먼저 막는다.
  static const autoZoomFaceHeight = 0.45;

  /// 자막 한 줄이 화면에 머무는 최소 시간. 이보다 짧으면 읽을 수 없다.
  ///
  /// 전사가 주는 시각은 낱말이 처음 인식된 시점으로 역산한 근사치라 0.1초
  /// 짜리 조각이 흔하다. 그런 줄은 **버리지 않고 이 길이까지 늘린다** —
  /// 버리면 컷 안에 있는 대사가 소리 없이 사라진다
  /// ([applyTranscriptCaptions] 참조).
  static const minimumCaptionDurationMs = 200;
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
    _project = _project.copyWith(
      selectedTool: tool,
      // 자막 탭을 나가면 이동·크기 손잡이도 함께 걷는다. 남겨 두면 다른
      // 탭에서 영상 위에 조절 상자가 계속 떠 있다.
      clearSelectedLayer: tool != EditorTool.text && tool != EditorTool.sticker,
    );
    _autoSelectForScope();
    notifyListeners();
  }

  /// 줌·자막 탭에서 고른 클립의 첫 항목을 자동으로 골라 둔다.
  ///
  /// 하나라도 있으면 "선택돼 있고 바로 만질 수 있는" 상태가 기본이어야
  /// 한다 — 빈 선택 상태는 타임라인도 슬라이더도 죽어 있는 것처럼 보인다.
  /// 이미 이 클립의 항목을 고르고 있었다면 그대로 둔다.
  void _autoSelectForScope() {
    final clip =
        _project.selectedClip ??
        (_project.clips.isEmpty ? null : _project.clips.first);
    if (clip == null) return;
    if (_project.selectedTool == EditorTool.zoom) {
      final zooms = _project.zoomSegments
          .where((zoom) => zoom.worksIn(clip))
          .toList(growable: false);
      if (!zooms.any((zoom) => zoom.id == _project.selectedZoomId)) {
        _project = _project.copyWith(
          selectedZoomId: zooms.isEmpty ? null : zooms.first.id,
          clearSelectedZoom: zooms.isEmpty,
        );
      }
    } else if (_project.selectedTool == EditorTool.text) {
      final layers = _project.textLayers
          .where((layer) => layer.clipId == null || layer.clipId == clip.id)
          .toList(growable: false);
      if (!layers.any((layer) => layer.id == _project.selectedLayerId)) {
        _project = _project.copyWith(
          selectedLayerId: layers.isEmpty ? null : layers.first.id,
          clearSelectedLayer: layers.isEmpty,
        );
      }
    }
  }

  /// 클립 배열이 바뀔 때, 클립에 묶인 자막의 절대 시각을 클립을 따라
  /// 다시 계산한다. 클립 안에서의 상대 위치는 그대로 유지되고, 묶인 클립이
  /// 사라졌으면 자막도 함께 사라진다.
  List<EditorTextLayer> _textLayersFollowing(
    List<EditorClip> oldClips,
    List<EditorClip> newClips,
  ) {
    int? startOf(List<EditorClip> clips, String id) {
      var cursor = 0;
      for (final clip in clips) {
        if (clip.id == id) return cursor;
        cursor += clip.durationMs;
      }
      return null;
    }

    EditorClip? clipOf(List<EditorClip> clips, String id) {
      for (final clip in clips) {
        if (clip.id == id) return clip;
      }
      return null;
    }

    final layers = <EditorTextLayer>[];
    for (final layer in _project.textLayers) {
      final clipId = layer.clipId;
      if (clipId == null) {
        layers.add(layer);
        continue;
      }
      final newStart = startOf(newClips, clipId);
      final newClip = clipOf(newClips, clipId);
      if (newStart == null || newClip == null) continue;
      final oldStart = startOf(oldClips, clipId) ?? newStart;
      final span = newClip.durationMs;
      final int relStart = (layer.startMs - oldStart)
          .clamp(0, math.max(0, span - 100))
          .toInt();
      final int relEnd = (layer.endMs - oldStart)
          .clamp(math.min(relStart + 100, span), span)
          .toInt();
      layers.add(
        layer.copyWith(startMs: newStart + relStart, endMs: newStart + relEnd),
      );
    }
    return layers;
  }

  /// 클립 배열이 바뀔 때, 클립에 묶인 스티커의 절대 시각을 클립을 따라
  /// 다시 계산한다. 자막([_textLayersFollowing])과 같은 규칙이다.
  List<EditorStickerLayer> _stickerLayersFollowing(
    List<EditorClip> oldClips,
    List<EditorClip> newClips,
  ) {
    int? startOf(List<EditorClip> clips, String id) {
      var cursor = 0;
      for (final clip in clips) {
        if (clip.id == id) return cursor;
        cursor += clip.durationMs;
      }
      return null;
    }

    EditorClip? clipOf(List<EditorClip> clips, String id) {
      for (final clip in clips) {
        if (clip.id == id) return clip;
      }
      return null;
    }

    final layers = <EditorStickerLayer>[];
    for (final layer in _project.stickerLayers) {
      final clipId = layer.clipId;
      if (clipId == null) {
        layers.add(layer);
        continue;
      }
      final newStart = startOf(newClips, clipId);
      final newClip = clipOf(newClips, clipId);
      if (newStart == null || newClip == null) continue;
      final oldStart = startOf(oldClips, clipId) ?? newStart;
      final span = newClip.durationMs;
      final int relStart = (layer.startMs - oldStart)
          .clamp(0, math.max(0, span - 100))
          .toInt();
      final int relEnd = (layer.endMs - oldStart)
          .clamp(math.min(relStart + 100, span), span)
          .toInt();
      layers.add(
        layer.copyWith(startMs: newStart + relStart, endMs: newStart + relEnd),
      );
    }
    return layers;
  }

  /// 지워진 클립에 묶여 있던 줌을 걷어낸 목록.
  List<EditorZoomSegment> _zoomsWithoutClip(String clipId) => _project
      .zoomSegments
      .where((zoom) => zoom.clipId != clipId)
      .toList(growable: false);

  /// 저장해 둔 초안(toDraftMap 결과)을 그대로 되살린다. 편집을 이어서
  /// 하는 진입이므로 되돌리기 이력은 쌓지 않는다.
  void loadDraftRecipe(Map<String, dynamic> recipe) {
    if (recipe['type'] != 'draft-v1') return;
    final total = _project.sourceDurationMs;
    int msOf(Object? value, {int fallback = 0}) =>
        (value as num?)?.round().clamp(0, total) ?? fallback;

    final clips = <EditorClip>[];
    for (final raw in recipe['clips'] as List? ?? const []) {
      final map = Map<String, dynamic>.from(raw as Map);
      final start = msOf(map['sourceStartMs']);
      final end = msOf(map['sourceEndMs'], fallback: total);
      if (end - start < minimumClipDurationMs) continue;
      clips.add(
        EditorClip(
          id: map['id'] as String? ?? _nextId('clip'),
          sourcePath: _project.sourceVideoPath,
          sourceStartMs: start,
          sourceEndMs: end,
          automatic: map['automatic'] == true,
          score: (map['score'] as num?)?.toDouble(),
        ),
      );
    }
    if (clips.isEmpty) return;

    final zooms = <EditorZoomSegment>[];
    for (final raw in recipe['zoomSegments'] as List? ?? const []) {
      final map = Map<String, dynamic>.from(raw as Map);
      final start = msOf(map['sourceStartMs']);
      final end = msOf(map['sourceEndMs']);
      if (end <= start) continue;
      zooms.add(
        EditorZoomSegment(
          id: map['id'] as String? ?? _nextId('zoom'),
          sourceStartMs: start,
          sourceEndMs: end,
          scale: ((map['scale'] as num?)?.toDouble() ?? 1.35).clamp(1.0, 2.8),
          focus: NormalizedPoint(
            (map['focusX'] as num?)?.toDouble() ?? 0.5,
            (map['focusY'] as num?)?.toDouble() ?? 0.5,
          ),
          automatic: map['automatic'] == true,
          clipId: map['clipId'] as String?,
          focusTrack: _zoomFocusTrackFrom(map['focusTrack']),
          faceTrackId: map['faceTrackId'] as String?,
          // 표시가 없는 옛 초안은 옛 기하로 그린다 — 사용자가 잡아 둔
          // 프레이밍이 말없이 달라지지 않게.
          focusModel: _zoomFocusModelFrom(map['focusModel']),
        ),
      );
    }

    final texts = <EditorTextLayer>[];
    for (final raw in recipe['textLayers'] as List? ?? const []) {
      final map = Map<String, dynamic>.from(raw as Map);
      final text = (map['text'] as String? ?? '').trim();
      if (text.isEmpty) continue;
      final position = Map<String, dynamic>.from(
        map['position'] as Map? ?? const {},
      );
      texts.add(
        EditorTextLayer(
          id: map['id'] as String? ?? _nextId('text'),
          text: text,
          position: NormalizedPoint(
            (position['x'] as num?)?.toDouble() ?? 0.5,
            (position['y'] as num?)?.toDouble() ?? 0.78,
          ),
          startMs: (map['startMs'] as num?)?.round() ?? 0,
          endMs: (map['endMs'] as num?)?.round() ?? 3000,
          scale: (map['scale'] as num?)?.toDouble() ?? 1,
          rotationDegrees: (map['rotationDegrees'] as num?)?.toDouble() ?? 0,
          color: Color((map['color'] as num?)?.toInt() ?? 0xFFFFFFFF),
          backgroundColor: Color(
            (map['backgroundColor'] as num?)?.toInt() ?? 0,
          ),
          fontSize: (map['fontSize'] as num?)?.toDouble() ?? 42,
          bold: map['bold'] != false,
          italic: map['italic'] == true,
          align:
              EditorTextAlign.values.asNameMap()[map['align']] ??
              EditorTextAlign.center,
          clipId: map['clipId'] as String?,
        ),
      );
    }

    final stickers = <EditorStickerLayer>[];
    for (final raw in recipe['stickerLayers'] as List? ?? const []) {
      final map = Map<String, dynamic>.from(raw as Map);
      final value = map['value'] as String? ?? '';
      if (value.isEmpty) continue;
      final position = Map<String, dynamic>.from(
        map['position'] as Map? ?? const {},
      );
      stickers.add(
        EditorStickerLayer(
          id: map['id'] as String? ?? _nextId('sticker'),
          value: value,
          position: NormalizedPoint(
            (position['x'] as num?)?.toDouble() ?? 0.5,
            (position['y'] as num?)?.toDouble() ?? 0.5,
          ),
          startMs: (map['startMs'] as num?)?.round() ?? 0,
          endMs: (map['endMs'] as num?)?.round() ?? 3000,
          scale: (map['scale'] as num?)?.toDouble() ?? 1,
          rotationDegrees: (map['rotationDegrees'] as num?)?.toDouble() ?? 0,
          clipId: map['clipId'] as String?,
          tracksFace: map['tracksFace'] == true,
          faceTrackId: map['faceTrackId'] as String?,
        ),
      );
    }

    final faceTrack = <EditorFaceSample>[
      for (final raw in recipe['faceTrack'] as List? ?? const [])
        _faceSampleFrom(Map<String, dynamic>.from(raw as Map)),
    ];
    final faceTracks = _faceTracksFrom(recipe['faceTracks']);

    final canvasMap = Map<String, dynamic>.from(
      recipe['canvas'] as Map? ?? const {},
    );
    final canvas =
        EditorCanvas(
          sourceAspectRatio: _project.canvas.sourceAspectRatio,
          ratio:
              EditorCanvasRatio.values.asNameMap()[canvasMap['ratio']] ??
              EditorCanvasRatio.original,
          fit:
              EditorCanvasFit.values.asNameMap()[canvasMap['fit']] ??
              EditorCanvasFit.cover,
          outputWidth: (canvasMap['outputWidth'] as num?)?.round() ?? 1280,
          outputHeight: (canvasMap['outputHeight'] as num?)?.round() ?? 720,
        ).copyWith(
          scale: (canvasMap['scale'] as num?)?.toDouble() ?? 1,
          offsetX: (canvasMap['offsetX'] as num?)?.toDouble() ?? 0,
          offsetY: (canvasMap['offsetY'] as num?)?.toDouble() ?? 0,
          rotationDegrees:
              (canvasMap['rotationDegrees'] as num?)?.toDouble() ?? 0,
        );

    final audioMap = Map<String, dynamic>.from(
      recipe['audio'] as Map? ?? const {},
    );
    final markerMap = recipe['recommendationMarker'] as Map?;

    // 복원한 id들과 새로 만들 id가 부딪히지 않게 씨앗을 올려 둔다.
    for (final id in [
      for (final clip in clips) clip.id,
      for (final zoom in zooms) zoom.id,
      for (final layer in texts) layer.id,
      for (final layer in stickers) layer.id,
    ]) {
      final tail = int.tryParse(id.split('-').last);
      if (tail != null && tail >= _idSeed) _idSeed = tail + 1;
    }

    _project = _project.copyWith(
      clips: clips,
      zoomSegments: zooms,
      textLayers: texts,
      stickerLayers: stickers,
      faceTrack: faceTrack,
      faceTracks: faceTracks,
      canvas: canvas,
      audio: EditorAudio(
        sourceVolume: (audioMap['sourceVolume'] as num?)?.toDouble() ?? 1,
        muted: audioMap['muted'] == true,
      ),
      look: EditorLook.values.asNameMap()[recipe['look']] ?? EditorLook.none,
      recommendationMarker: markerMap == null
          ? null
          : EditorRecommendationMarker(
              preset: markerMap['preset'] as String? ?? 'medium',
              sourceStartMs: msOf(markerMap['sourceStartMs']),
              sourceEndMs: msOf(markerMap['sourceEndMs']),
            ),
      selectedClipId: clips.first.id,
      playheadMs: 0,
    );
    notifyListeners();
  }

  /// 서버 추천(구간·줌)을 컷으로 적용한다.
  void applyRecommendation(EditRecommendation recommendation) {
    _applyScoredCut(
      preset: recommendation.durationPreset,
      recommendation: recommendation,
    );
  }

  /// 추천 서버 없이 길이 프리셋만으로 컷을 다시 만든다.
  void applyPreset(String preset) => _applyScoredCut(preset: preset);

  /// 프리셋 컷은 **고른 클립 하나의 구간만** 이어진 한 구간으로 바꾼다 —
  /// 짧게 ~45초, 중간 ~90초, 길게 90초 이상. 사용자가 추가해 둔 다른
  /// 클립은 절대 지우지도, 건드리지도 않는다.
  ///
  /// 어느 구간으로 바꿀지는 점수가 정한다. 서버 recipe가 있으면 셀렉터
  /// (video_editor의 adaptive_selector + duration_presets)가 웃음·말소리·
  /// 음량 상승·모션·얼굴 특징의 `eventScore`로 이미 골라 준 cut 구간을
  /// 그대로 쓰고, scoreTimeline의 평균 점수를 그 클립에 실어 보여 준다.
  /// 서버가 없으면 원본 가운데에서 목표 길이만큼 잡는다(점수 표시 없음).
  void _applyScoredCut({
    required String preset,
    EditRecommendation? recommendation,
  }) {
    final total = _project.sourceDurationMs;
    if (total < minimumClipDurationMs || _project.clips.isEmpty) return;
    final targetClip = _project.selectedClip ?? _project.clips.first;
    final autoZooms = _automaticZoomsFor(recommendation, targetClip);

    final int start;
    final int end;
    if (recommendation != null) {
      // 서버 셀렉터가 점수로 고른 연속 하이라이트 구간.
      start = recommendation.cutStartMs.clamp(0, total);
      end = recommendation.cutEndMs.clamp(
        math.min(total, start + minimumClipDurationMs),
        total,
      );
    } else {
      // 서버가 없을 때의 기본 창 — 프리셋 길이 약속만 지킨다.
      final targetMs = math.min(total, switch (preset) {
        'short' => 45000,
        'long' => math.max(90000, (total * 0.8).round()),
        _ => 90000,
      });
      start = ((total - targetMs) / 2).round();
      end = start + targetMs;
    }

    final timeline = recommendation?.scoreTimeline ?? const [];

    /// [rangeStart, rangeEnd) 구간의 사건 점수(길이 가중 평균).
    /// 타임라인이 그 구간을 덮지 않으면 null.
    double? eventScore(int rangeStart, int rangeEnd) {
      var weighted = 0.0;
      var covered = 0.0;
      for (final row in timeline) {
        final rowStart = (row['startMs'] as num?)?.round() ?? 0;
        final rowEnd = (row['endMs'] as num?)?.round() ?? 0;
        final overlap =
            (math.min(rangeEnd, rowEnd) - math.max(rangeStart, rowStart))
                .toDouble();
        if (overlap <= 0) continue;
        weighted += overlap * ((row['eventScore'] as num?)?.toDouble() ?? 0);
        covered += overlap;
      }
      return covered == 0 ? null : weighted / covered;
    }

    // 고른 클립의 구간만 바꾼다. id를 그대로 두므로 순서·다른 클립·선택
    // 상태가 전부 유지된다.
    final target = targetClip;
    final updated = EditorClip(
      id: target.id,
      sourcePath: target.sourcePath,
      sourceStartMs: start,
      sourceEndMs: end,
      arEffectId: target.arEffectId,
      automatic: true,
      // "왜 이 구간인지"를 칩에서 보여 줄 실제 사건 점수. 서버 타임라인이
      // 없으면 null — 점수를 지어내 표시하지 않는다.
      score: eventScore(start, end),
    );
    final clips = [
      for (final clip in _project.clips) clip.id == target.id ? updated : clip,
    ];
    // 서버 줌은 자동 줌만 갈아 끼운다. 사용자가 직접 만든 줌은 남긴다.
    final manualZooms = _project.zoomSegments
        .where((zoom) => !zoom.automatic)
        .toList(growable: false);
    final zooms = autoZooms.isEmpty
        ? _project.zoomSegments
        : [...autoZooms, ...manualZooms];
    // 얼굴 궤적은 원본 시각 기준이라 컷과 무관하게 그대로 싣는다.
    final faceTracks = recommendation == null
        ? _project.faceTracks
        : _faceTracksFrom(recommendation.faceTracks);
    final faceTrack = recommendation == null
        ? _project.faceTrack
        : [
            for (final sample in recommendation.faceTrack)
              EditorFaceSample(
                sourceMs: (sample['ms'] as num?)?.round() ?? 0,
                x: (sample['x'] as num?)?.toDouble() ?? 0.5,
                y: (sample['y'] as num?)?.toDouble() ?? 0.5,
                height: (sample['h'] as num?)?.toDouble() ?? 0,
              ),
          ];
    _commit(
      _project.copyWith(
        clips: clips,
        zoomSegments: zooms,
        textLayers: _textLayersFollowing(_project.clips, clips),
        stickerLayers: _stickerLayersFollowing(_project.clips, clips),
        faceTrack: faceTrack,
        faceTracks: faceTracks,
        recommendationMarker: EditorRecommendationMarker(
          preset: preset,
          sourceStartMs: start,
          sourceEndMs: end,
        ),
        selectedZoomId: autoZooms.isEmpty ? null : autoZooms.first.id,
        selectedClipId: target.id,
        // 바뀐 클립의 시작을 바로 보여 준다.
        playheadMs: clips
            .takeWhile((clip) => clip.id != target.id)
            .fold<int>(0, (sum, clip) => sum + clip.durationMs),
      ),
    );
  }

  /// 서버 추천의 자동 줌을 [clip]에 붙는 줌 구간으로 옮긴다.
  ///
  /// 배율은 서버 값을 그대로 쓰지 않는다 — 서버(zoom_planner)는 얼굴 높이를
  /// 화면의 0.28~0.33으로 맞추는데, 작은 휴대폰 화면에서 1/3짜리 얼굴은
  /// 확대한 티가 안 난다. 함께 오는 targetFaceHeight로 실제 얼굴 크기를
  /// 되짚어 [autoZoomFaceHeight] 기준으로 다시 잡는다.
  List<EditorZoomSegment> _automaticZoomsFor(
    EditRecommendation? recommendation,
    EditorClip clip,
  ) => (recommendation?.zoomSegments ?? const []).indexed
      .map((entry) {
        final value = entry.$2;
        var scale = (value['scale'] as num).toDouble();
        final targetFaceHeight =
            (value['targetFaceHeight'] as num?)?.toDouble() ?? 0;
        if (targetFaceHeight > 0) {
          scale = (scale * autoZoomFaceHeight / targetFaceHeight).clamp(
            1.2,
            2.8,
          );
        }
        // 다만 화면 가장자리에 선 사람은 조금만 키워도 얼굴이 잘려 나간다.
        // 서버가 얼굴 상자로 계산해 준 기하학적 상한을 넘지 않는다 —
        // 크게 보이는 것보다 얼굴이 온전한 쪽이 먼저다.
        final maxScale = (value['maxScale'] as num?)?.toDouble();
        if (maxScale != null && maxScale > 0) {
          scale = math.min(scale, math.max(1.2, maxScale));
        }
        return EditorZoomSegment(
          id: 'auto-zoom-${entry.$1}',
          sourceStartMs: (value['startMs'] as num).round(),
          sourceEndMs: (value['endMs'] as num).round(),
          scale: scale,
          focus: NormalizedPoint(
            (value['focusX'] as num).toDouble(),
            (value['focusY'] as num).toDouble(),
          ),
          automatic: true,
          clipId: clip.id,
          // 서버가 잡은 얼굴이 움직이면 초점도 따라간다. 확대해 둔 채로
          // 그 사람이 화면 밖으로 나가 버리던 것을 막는다.
          focusTrack: _zoomFocusTrackFrom(value['focusTrack']),
          faceTrackId: value['faceTrackId'] as String?,
          focusModel: _zoomFocusModelFrom(value['focusModel']),
        );
      })
      .toList(growable: false);

  /// AI가 고른 줌을 지금 클립에 다시 깐다. **컷도 자막도 건드리지 않는다** —
  /// 줌만 지웠다가 되돌리고 싶을 때 쓴다.
  ///
  /// 손으로 만든 줌은 그대로 두고 자동 줌만 갈아 끼운다. 클립 구간에 걸치지
  /// 않는 줌은 버린다 — 컷을 옮겼으면 그 장면은 이미 화면에서 잘려 나갔고,
  /// 보이지도 않는 줌을 목록에 쌓아 둘 이유가 없다.
  ///
  /// 되돌릴 줌이 하나도 없으면 아무것도 바꾸지 않고 false.
  bool restoreAutomaticZooms(EditRecommendation recommendation) {
    if (_project.clips.isEmpty) return false;
    final clip = _project.selectedClip ?? _project.clips.first;
    final restored = [
      for (final zoom in _automaticZoomsFor(recommendation, clip))
        if (zoom.sourceStartMs < clip.sourceEndMs &&
            zoom.sourceEndMs > clip.sourceStartMs)
          zoom,
    ];
    if (restored.isEmpty) return false;
    _commit(
      _project.copyWith(
        zoomSegments: [
          ...restored,
          for (final zoom in _project.zoomSegments)
            if (!zoom.automatic) zoom,
        ],
        selectedZoomId: restored.first.id,
        selectedClipId: clip.id,
      ),
    );
    return true;
  }

  /// 재생 위치에서 3초짜리 클립을 하나 더 얹는다. 고른 클립 뒤에 들어가고,
  /// 구간은 손잡이·창 끌기로 바로 다듬는다.
  bool addClipAtPlayhead() {
    final sourceMs = _project.sourcePositionForTimeline(_project.playheadMs);
    if (sourceMs == null) return false;
    final start = math.min(
      sourceMs,
      math.max(0, _project.sourceDurationMs - minimumClipDurationMs),
    );
    final end = math.min(_project.sourceDurationMs, start + 3000);
    if (end - start < minimumClipDurationMs) return false;
    final clip = EditorClip(
      id: _nextId('clip'),
      sourcePath: _project.sourceVideoPath,
      sourceStartMs: start,
      sourceEndMs: end,
    );
    final selectedIndex = _project.clips.indexWhere(
      (item) => item.id == _project.selectedClipId,
    );
    final next = [..._project.clips]
      ..insert(
        selectedIndex < 0 ? _project.clips.length : selectedIndex + 1,
        clip,
      );
    _commit(
      _project.copyWith(
        clips: next,
        textLayers: _textLayersFollowing(_project.clips, next),
        stickerLayers: _stickerLayersFollowing(_project.clips, next),
        selectedClipId: clip.id,
      ),
    );
    return true;
  }

  /// 재생 위치가 속한 클립 안에 줌을 하나 만든다. 그 자리에 이미 줌이
  /// 있으면 막지 않고 **클립 안의 가장 가까운 빈 틈**에 만든다. 클립이
  /// 줌으로 가득 차 틈이 없을 때만 false를 준다.
  bool addZoomAtPlayhead() {
    final location = _locateTimelinePosition(_project.playheadMs);
    if (location == null) return false;
    final clip = location.clip;
    final sourceMs = clip.sourceStartMs + location.offsetMs;
    // 이 클립에 묶인 줌들 사이의 빈 틈을 모은다.
    final occupied =
        _project.zoomSegments.where((zoom) => zoom.worksIn(clip)).toList()
          ..sort((a, b) => a.sourceStartMs.compareTo(b.sourceStartMs));
    final gaps = <(int, int)>[];
    var cursor = clip.sourceStartMs;
    for (final zoom in occupied) {
      if (zoom.sourceStartMs - cursor >= 300) {
        gaps.add((cursor, zoom.sourceStartMs));
      }
      cursor = math.max(cursor, zoom.sourceEndMs);
    }
    if (clip.sourceEndMs - cursor >= 300) gaps.add((cursor, clip.sourceEndMs));
    if (gaps.isEmpty) return false;
    // 재생 위치를 품은 틈이 있으면 거기, 없으면 가장 가까운 틈에.
    (int, int) best = gaps.first;
    var bestDistance = 1 << 30;
    for (final gap in gaps) {
      final distance = sourceMs < gap.$1
          ? gap.$1 - sourceMs
          : sourceMs >= gap.$2
          ? sourceMs - gap.$2
          : 0;
      if (distance < bestDistance) {
        best = gap;
        bestDistance = distance;
      }
    }
    var start = math.max(best.$1, math.min(sourceMs - 1000, best.$2 - 3000));
    var end = math.min(best.$2, start + 3000);
    start = math.max(best.$1, end - 3000);
    final zoom = EditorZoomSegment(
      id: _nextId('zoom'),
      sourceStartMs: start,
      sourceEndMs: end,
      scale: 1.35,
      focus: NormalizedPoint.center,
      clipId: clip.id,
      // 새로 만드는 줌은 창 모델이다 — 가장자리로 끌어도 잘리지 않는다.
      focusModel: EditorZoomFocusModel.window,
    );
    _commit(
      _project.copyWith(
        zoomSegments: [..._project.zoomSegments, zoom],
        selectedZoomId: zoom.id,
        // 줌이 묶인 클립을 함께 고른다 — 줌 탭은 고른 클립의 줌만 보여
        // 주므로, 방금 만든 줌이 바로 보여야 한다.
        selectedClipId: clip.id,
      ),
    );
    return true;
  }

  /// 줌을 고르고 재생 위치를 그 장면 시작으로 옮긴다.
  ///
  /// 줌은 클립에 귀속되므로 **묶인 클립**을 함께 고른다 — 장면 카드를
  /// 누르면 그 클립의 타임라인 위 제자리로 간다. 묶이지 않은 옛 줌은
  /// 시작 시각을 품은 클립을 찾아 고른다(못 찾아도 선택은 된다 — 반응
  /// 없는 카드처럼 보이면 안 된다).
  void selectZoom(String zoomId) {
    EditorZoomSegment? zoom;
    for (final item in _project.zoomSegments) {
      if (item.id == zoomId) zoom = item;
    }
    if (zoom == null) return;
    EditorClip? boundClip;
    var boundTimelineStart = 0;
    var cursor = 0;
    for (final clip in _project.clips) {
      final matches = zoom.clipId == null
          ? zoom.sourceStartMs >= clip.sourceStartMs &&
                zoom.sourceStartMs < clip.sourceEndMs
          : clip.id == zoom.clipId;
      if (matches) {
        boundClip = clip;
        boundTimelineStart = cursor;
        break;
      }
      cursor += clip.durationMs;
    }
    _project = _project.copyWith(
      selectedZoomId: zoomId,
      selectedClipId: boundClip?.id ?? _project.selectedClipId,
      playheadMs: boundClip == null
          ? _project.playheadMs
          : boundTimelineStart +
                (zoom.sourceStartMs - boundClip.sourceStartMs).clamp(
                  0,
                  boundClip.durationMs,
                ),
    );
    notifyListeners();
  }

  void updateZoom(EditorZoomSegment segment) {
    final next = _project.zoomSegments
        .map((item) => item.id == segment.id ? segment : item)
        .toList(growable: false);
    _commit(_project.copyWith(zoomSegments: next));
  }

  /// 손가락 동작(슬라이더·손잡이·핀치) 도중의 줌 갱신. 이력에 쌓지 않고,
  /// 손을 뗄 때 [endGesture]가 한 칸으로 확정한다. [beginGesture]를 먼저
  /// 부르지 않았다면 여기서 대신 시작해 둔다.
  void updateZoomGesture(EditorZoomSegment segment, {bool notify = true}) {
    beginGesture();
    final next = _project.zoomSegments
        .map((item) => item.id == segment.id ? segment : item)
        .toList(growable: false);
    _project = _project.copyWith(
      zoomSegments: next,
      selectedZoomId: segment.id,
    );
    if (notify) notifyListeners();
  }

  /// 손가락 동작 도중의 자막 구간 갱신. 확정은 [endGesture]가 한다.
  void updateTextLayerRangeGesture(
    String id,
    int startMs,
    int endMs, {
    bool notify = true,
  }) {
    if (endMs - startMs < minimumCaptionDurationMs) return;
    beginGesture();
    var changed = false;
    final texts = [
      for (final layer in _project.textLayers)
        if (layer.id == id)
          (() {
            changed = true;
            return layer.copyWith(startMs: startMs, endMs: endMs);
          })()
        else
          layer,
    ];
    if (!changed) return;
    _project = _project.copyWith(textLayers: texts, selectedLayerId: id);
    if (notify) notifyListeners();
  }

  /// 손가락 동작 도중의 스티커 구간 갱신. 확정은 [endGesture]가 한다.
  ///
  /// 얼굴 추적 스티커는 그 얼굴이 화면에 잡혀 있는 구간 밖으로 나가지
  /// 않는다 — 손잡이를 더 끌어도 얼굴 범위 끝에서 멈춘다.
  void updateStickerLayerRangeGesture(
    String id,
    int startMs,
    int endMs, {
    bool notify = true,
  }) {
    if (endMs - startMs < minimumCaptionDurationMs) return;
    beginGesture();
    var changed = false;
    final stickers = [
      for (final layer in _project.stickerLayers)
        if (layer.id == id)
          (() {
            var start = startMs;
            var end = endMs;
            if (layer.tracksFace) {
              final coverage = _project.faceCoverageFor(layer);
              if (coverage != null) {
                start = math.max(start, coverage.startMs);
                end = math.min(end, coverage.endMs);
              }
            }
            if (end - start < 200) return layer;
            changed = true;
            return layer.copyWith(startMs: start, endMs: end);
          })()
        else
          layer,
    ];
    if (!changed) return;
    _project = _project.copyWith(stickerLayers: stickers, selectedLayerId: id);
    if (notify) notifyListeners();
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
      _project.copyWith(
        clips: next,
        // 클립에 묶인 자막은 클립을 따라 함께 움직인다.
        textLayers: _textLayersFollowing(_project.clips, next),
        stickerLayers: _stickerLayersFollowing(_project.clips, next),
        selectedClipId: moved.id,
        playheadMs: 0,
      ),
    );
  }

  /// 이미 고른 클립이면 **아무것도 하지 않는다.**
  ///
  /// **왜 막아야 하나**: 타임라인을 문지르면 손가락이 움직일 때마다
  /// `_seekToPosition`이 이걸 부른다. 그런데 문지르는 내내 클립은 대개 그대로다.
  /// 막지 않으면 손가락 한 번 움직일 때마다 프로젝트를 통째로 새로 만들고
  /// (조각·글자·스티커·블러 목록을 전부 복사한다) 편집 화면을 다시 그린다 —
  /// 바로 뒤의 `setPlayhead`가 어차피 한 번 더 그리므로 두 배로 그리는 셈이다.
  /// 문지를 때 뚝뚝 끊기던 원인이다.
  ///
  /// 덤으로 고쳐지는 것: 예전에는 문지르는 동안 [clearSelectedLayer] 때문에
  /// 골라 둔 글자·스티커가 계속 풀렸다. 클립이 실제로 바뀔 때만 푼다.
  void selectClip(String clipId) {
    if (_project.selectedClipId == clipId) return;
    if (!_project.clips.any((clip) => clip.id == clipId)) return;
    _project = _project.copyWith(
      selectedClipId: clipId,
      clearSelectedLayer: true,
    );
    // 줌·자막 탭이라면 새 클립의 첫 항목이 곧바로 골라진다.
    _autoSelectForScope();
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
    // 나뉜 클립에 묶여 있던 줌·자막은 각자 시작 위치가 속한 반쪽으로
    // 다시 묶는다. 타임라인 전체 길이는 그대로라 절대 시각은 안 바뀐다.
    final splitTimelineMs =
        _project.timelineStartFor(clip.id) + location.offsetMs;
    final zooms = [
      for (final zoom in _project.zoomSegments)
        zoom.clipId != clip.id
            ? zoom
            : zoom.sourceStartMs < sourceSplitMs
            ? zoom.copyWith(
                clipId: left.id,
                sourceEndMs: math.min(zoom.sourceEndMs, sourceSplitMs),
              )
            : zoom.copyWith(clipId: right.id),
    ];
    final layers = [
      for (final layer in _project.textLayers)
        layer.clipId != clip.id
            ? layer
            : layer.startMs < splitTimelineMs
            ? layer.copyWith(
                clipId: left.id,
                endMs: math.min(layer.endMs, splitTimelineMs),
              )
            : layer.copyWith(clipId: right.id),
    ];
    final stickers = [
      for (final layer in _project.stickerLayers)
        layer.clipId != clip.id
            ? layer
            : layer.startMs < splitTimelineMs
            ? layer.copyWith(
                clipId: left.id,
                endMs: math.min(layer.endMs, splitTimelineMs),
              )
            : layer.copyWith(clipId: right.id),
    ];
    _commit(
      _project.copyWith(
        clips: next,
        zoomSegments: zooms,
        textLayers: layers,
        stickerLayers: stickers,
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
          zoomSegments: _zoomsWithoutClip(selected.id),
          textLayers: _textLayersFollowing(_project.clips, remaining),
          stickerLayers: _stickerLayersFollowing(_project.clips, remaining),
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
        // 클립을 지우면 거기 묶인 줌·자막도 함께 사라진다.
        zoomSegments: _zoomsWithoutClip(selected.id),
        textLayers: _textLayersFollowing(_project.clips, next),
        stickerLayers: _stickerLayersFollowing(_project.clips, next),
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
    _commit(
      _project.copyWith(
        clips: next,
        textLayers: _textLayersFollowing(_project.clips, next),
        stickerLayers: _stickerLayersFollowing(_project.clips, next),
        selectedClipId: copy.id,
      ),
    );
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
      // 뒤 클립들에 묶인 자막이 길이 변화를 따라간다.
      textLayers: _textLayersFollowing(_project.clips, next),
      stickerLayers: _stickerLayersFollowing(_project.clips, next),
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

  /// 출력 비율을 바꾼다.
  ///
  /// 9:16은 가로 영상을 **중앙에 그대로** 놓고 위아래를 검은 띠로 남긴다
  /// (숏폼 구도 — 띠는 자막 자리다). 확대해서 가득 채우면 영상이 3배로
  /// 확대돼 알아볼 수 없었다. 원본·16:9는 영상이 캔버스와 같거나 넓어
  /// 채우기(cover)로 두면 여백이 없다.
  void setCanvasRatio(EditorCanvasRatio ratio) {
    if (_project.canvas.ratio == ratio) return;
    _commit(
      _project.copyWith(
        canvas: _project.canvas.copyWith(
          ratio: ratio,
          fit: switch (ratio) {
            // 원본보다 좁은 비율은 중앙에 그대로 놓고 띠를 남긴다.
            EditorCanvasRatio.vertical ||
            EditorCanvasRatio.square ||
            EditorCanvasRatio.portrait => EditorCanvasFit.contain,
            EditorCanvasRatio.original ||
            EditorCanvasRatio.landscape => EditorCanvasFit.cover,
          },
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
    NormalizedPoint? position,
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
      position: position ?? NormalizedPoint(0.5, 0.78),
      startMs: startMs ?? _project.playheadMs,
      endMs: endMs ?? _project.durationMs,
      clipId: _locateTimelinePosition(startMs ?? _project.playheadMs)?.clip.id,
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
        // 자막이 붙은 클립이 곧 지금 편집 중인 클립이다.
        //
        // **왜 여기서 클립까지 옮기는가**: 자막은 **재생 위치가 속한** 클립에
        // 붙는데, 고른 클립은 그와 다를 수 있다 — 클립을 나눈 뒤 앞 클립을
        // 골라 둔 채 재생 위치만 뒤 클립으로 옮겼을 때가 그렇다. 그대로 두면
        // 자막 판은 여전히 앞 클립을 펼치고 있어서, 방금 만든 자막이 타임라인
        // 막대에도 자막 카드에도 나타나지 않았다.
        selectedClipId: layer.clipId ?? _project.selectedClipId,
      ),
    );
  }

  /// AI 자막이 만들어 둔 레이어가 있는가. 다시 만들면 이것들이 갈아
  /// 끼워지므로, 화면이 경고를 띄울지 정할 때 쓴다.
  bool get hasTranscriptCaptions =>
      _project.textLayers.any((layer) => layer.id.startsWith('ai-caption-'));

  /// AI 자막(전사) 결과를 **일반 자막 레이어**로 바꿔 얹는다.
  ///
  /// [sourceCaptions]의 시각은 원본 영상 시각이다. 지금 클립 배치에 맞춰
  /// 타임라인 시각으로 바꾸고, 겹치는 클립에 귀속시킨다 — 이후 편집·이동·
  /// 저장·내보내기는 손으로 만든 자막과 완전히 같은 길을 탄다.
  ///
  /// 다시 부르면 **이 함수가 전에 만든 레이어만** 갈아 끼운다. 사용자가
  /// 직접 만든 자막은 건드리지 않는다.
  void applyTranscriptCaptions(
    List<({int startMs, int endMs, String text})> sourceCaptions,
  ) {
    const prefix = 'ai-caption-';
    final kept = _project.textLayers
        .where((layer) => !layer.id.startsWith(prefix))
        .toList(growable: false);
    final added = <EditorTextLayer>[];
    var timelineStartMs = 0;
    for (final clip in _project.clips) {
      for (final caption in sourceCaptions) {
        final text = caption.text.trim();
        if (text.isEmpty) continue;
        final overlapStart = caption.startMs.clamp(
          clip.sourceStartMs,
          clip.sourceEndMs,
        );
        final overlapEnd = caption.endMs.clamp(
          clip.sourceStartMs,
          clip.sourceEndMs,
        );
        // 겹치는 구간이 아예 없다 = 잘라 낸 자리의 대사다. 그 장면은 영상에
        // 없으니 자막도 없다.
        if (overlapEnd <= overlapStart) continue;
        var start = overlapStart;
        var end = overlapEnd;
        if (end - start < minimumCaptionDurationMs) {
          // 컷 **안**인데 너무 짧다. 버리면 "컷 안 자막인데 안 들어간다"가
          // 된다 — 전사가 주는 시각은 낱말이 처음 인식된 시점으로 역산한
          // 근사치라 0.1초짜리 조각이 흔하다. 읽을 수 있는 길이까지 늘려
          // 준다. 뒤로 못 늘리면 앞으로 당긴다.
          end = math.min(clip.sourceEndMs, start + minimumCaptionDurationMs);
          if (end - start < minimumCaptionDurationMs) {
            start = math.max(
              clip.sourceStartMs,
              end - minimumCaptionDurationMs,
            );
          }
          // 클립 자체가 그보다 짧다. 이건 정말로 넣을 자리가 없다.
          if (end - start < minimumCaptionDurationMs) continue;
        }
        added.add(
          EditorTextLayer(
            id: _nextId('ai-caption'),
            text: text,
            position: NormalizedPoint(0.5, 0.78),
            startMs: timelineStartMs + start - clip.sourceStartMs,
            endMs: timelineStartMs + end - clip.sourceStartMs,
            fontSize: 28,
            clipId: clip.id,
          ),
        );
      }
      timelineStartMs += clip.durationMs;
    }
    if (added.isEmpty && kept.length == _project.textLayers.length) return;
    final previousSelectionStillExists = kept.any(
      (layer) => layer.id == _project.selectedLayerId,
    );
    _commit(
      _project.copyWith(
        textLayers: [...kept, ...added],
        selectedLayerId: added.isEmpty ? null : added.first.id,
        clearSelectedLayer: added.isEmpty && !previousSelectionStillExists,
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
    // 자막은 재생 위치부터 3초가 기본이되, **재생 위치가 속한 클립 안**에
    // 머문다 — 자막 편집이 클립별로 분리된다. 예전에는 영상 전체에 깔려서
    // 두 번째 자막부터는 서로 평생 겹쳤다. 구간은 타임라인 손잡이로 언제든
    // 다시 잡고, 구간이 겹치면 같은 시각에 함께 뜬다(동시 자막).
    final location = _locateTimelinePosition(_project.playheadMs);
    final clipTimelineStart = location == null
        ? 0
        : _project.timelineStartFor(location.clip.id);
    final clipTimelineEnd = location == null
        ? _project.durationMs
        : clipTimelineStart + location.clip.durationMs;
    final int startMs = _project.playheadMs
        .clamp(
          clipTimelineStart,
          math.max(clipTimelineStart, clipTimelineEnd - 1000),
        )
        .toInt();
    final endMs = math.min(clipTimelineEnd, startMs + 3000);
    final layer = EditorTextLayer(
      id: _nextId('text'),
      text: '',
      position: NormalizedPoint(0.5, 0.5),
      startMs: startMs,
      endMs: math.max(endMs, startMs + 500),
      clipId: location?.clip.id,
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

  /// 자막 레이어 하나를 이력에 남기며 지운다.
  void removeTextLayer(String id) {
    final texts = _project.textLayers.where((layer) => layer.id != id).toList();
    if (texts.length == _project.textLayers.length) return;
    _commit(
      _project.copyWith(
        textLayers: texts,
        clearSelectedLayer: _project.selectedLayerId == id,
      ),
    );
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

  static EditorFaceSample _faceSampleFrom(Map<String, dynamic> map) =>
      EditorFaceSample(
        sourceMs: (map['ms'] as num?)?.round() ?? 0,
        x: (map['x'] as num?)?.toDouble() ?? 0.5,
        y: (map['y'] as num?)?.toDouble() ?? 0.5,
        height: (map['h'] as num?)?.toDouble() ?? 0,
      );

  /// 서버·초안의 `faceTracks`([{id, samples}]) 목록.
  static List<EditorFaceTrack> _faceTracksFrom(Object? raw) {
    final tracks = <EditorFaceTrack>[];
    for (final entry in raw as List? ?? const []) {
      final map = Map<String, dynamic>.from(entry as Map);
      final id = map['id'] as String? ?? '';
      final samples = [
        for (final sample in map['samples'] as List? ?? const [])
          _faceSampleFrom(Map<String, dynamic>.from(sample as Map)),
      ];
      if (id.isEmpty || samples.isEmpty) continue;
      tracks.add(EditorFaceTrack(id: id, samples: samples));
    }
    return tracks;
  }

  /// 서버·초안의 줌 `focusModel`. 값이 없으면 옛 기하([EditorZoomFocusModel
  /// .anchor])다 — 이 필드가 생기기 전에 저장된 줌이라는 뜻이다.
  static EditorZoomFocusModel _zoomFocusModelFrom(Object? raw) =>
      EditorZoomFocusModel.values.asNameMap()[raw] ??
      EditorZoomFocusModel.anchor;

  /// 서버·초안의 줌 `focusTrack`([{ms, dx, dy}]). 사람을 따라가는 줌이
  /// 초점을 기준 자리에서 얼마나 옮길지를 시간 순으로 담고 있다.
  static List<EditorZoomFocusSample> _zoomFocusTrackFrom(Object? raw) {
    final samples = <EditorZoomFocusSample>[];
    for (final entry in raw as List? ?? const []) {
      final map = Map<String, dynamic>.from(entry as Map);
      final ms = (map['ms'] as num?)?.round();
      if (ms == null) continue;
      samples.add(
        EditorZoomFocusSample(
          sourceMs: ms,
          dx: (map['dx'] as num?)?.toDouble() ?? 0,
          dy: (map['dy'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
    samples.sort((a, b) => a.sourceMs.compareTo(b.sourceMs));
    return samples;
  }

  /// 지금 만지고 있는 클립. 고른 클립이 우선, 없으면 재생 위치의 클립이다.
  EditorClip? get _faceStickerScope =>
      _project.selectedClip ??
      _locateTimelinePosition(_project.playheadMs)?.clip ??
      (_project.clips.isEmpty ? null : _project.clips.first);

  /// 지금 클립에 씌워져 있는 얼굴 추적 스티커. 없으면 null.
  ///
  /// 클립에 안 묶인 옛 초안의 얼굴 스티커는 어느 클립에서나 보인다.
  EditorStickerLayer? get faceSticker {
    final scope = _faceStickerScope;
    for (final layer in _project.stickerLayers) {
      if (layer.tracksFace &&
          (layer.clipId == null || layer.clipId == scope?.id)) {
        return layer;
      }
    }
    return null;
  }

  /// 얼굴 추적 스티커를 지금 클립에 씌우거나(null이면 전부) 벗긴다.
  /// **사람마다 하나**다 — 같은 사람에게 다른 이모지를 누르면 갈아 끼우고,
  /// 다른 사람에게는 따로 붙는다(할머니에겐 왕관, 아기에겐 선글라스).
  ///
  /// 자막·일반 스티커처럼 클립에 귀속되고, 구간은 타임라인에서 조절하되
  /// **그 얼굴이 화면에 잡혀 있는 구간 안**으로만 움직인다. 어느 얼굴인지는
  /// 재생 위치에 잡힌 얼굴로 시작하고, 스티커를 다른 사람 위로 끌어 놓으면
  /// 그 사람으로 갈아탄다.
  ///
  /// 지금 재생 위치 근처에 얼굴이 없으면 아무것도 하지 않고 false를
  /// 돌려준다 — 화면이 안내를 띄운다.
  bool setFaceSticker(String? value) {
    final scope = _faceStickerScope;
    bool inScope(EditorStickerLayer layer) =>
        layer.tracksFace && (layer.clipId == null || layer.clipId == scope?.id);
    if (value == null || value.isEmpty) {
      // 벗기기 — 이 클립의 얼굴 스티커를 전부 걷어낸다.
      final others = _project.stickerLayers
          .where((layer) => !inScope(layer))
          .toList(growable: false);
      if (others.length == _project.stickerLayers.length) return true;
      final removedSelected = _project.stickerLayers.any(
        (layer) => layer.id == _project.selectedLayerId && inScope(layer),
      );
      _commit(
        _project.copyWith(
          stickerLayers: others,
          clearSelectedLayer: removedSelected,
        ),
      );
      return true;
    }
    // 재생 위치의 원본 시각. 고른 클립 밖이면 클립 첫 프레임으로 본다.
    var probeMs = _project.sourcePositionForTimeline(_project.playheadMs);
    if (scope != null &&
        (probeMs == null ||
            probeMs < scope.sourceStartMs ||
            probeMs >= scope.sourceEndMs)) {
      probeMs = scope.sourceStartMs;
    }
    // 이 순간 화면에 잡힌 사람 중, 아직 스티커가 없는 사람을 우선으로
    // 얼굴이 큰(가까운) 순서로 고른다 — 두 번째 이모지는 자연스럽게
    // 다른 사람에게 간다.
    final candidates = probeMs == null
        ? const <EditorFaceTrack>[]
        : _project.faceTracksAt(probeMs);
    final wearing = {
      for (final layer in _project.stickerLayers)
        if (inScope(layer) && layer.faceTrackId != null) layer.faceTrackId!,
    };
    final fresh = [
      for (final track in candidates)
        if (!wearing.contains(track.id)) track,
    ];
    final trackId = fresh.isNotEmpty
        ? fresh.first.id
        : (candidates.isEmpty ? null : candidates.first.id);
    if (_project.faceTracks.isNotEmpty && trackId == null) return false;
    if (_project.faceTracks.isEmpty && _project.faceTrack.isEmpty) {
      return false;
    }
    // 같은 사람의 기존 스티커만 갈아 끼운다. 옛 데이터(사람 구분 없음)는
    // 클립당 하나로 본다.
    final others = _project.stickerLayers
        .where((layer) => !(inScope(layer) && layer.faceTrackId == trackId))
        .toList(growable: false);
    final clipStart = scope == null ? 0 : _project.timelineStartFor(scope.id);
    var layer = EditorStickerLayer(
      id: _nextId('ar-face'),
      value: value,
      // 얼굴 정중앙. 끌면 얼굴 기준 오프셋으로 저장된다.
      position: NormalizedPoint.center,
      startMs: clipStart,
      endMs: scope == null ? _project.durationMs : clipStart + scope.durationMs,
      scale: 1.6,
      clipId: scope?.id,
      tracksFace: true,
      faceTrackId: trackId,
    );
    // 구간을 그 얼굴이 잡혀 있는 범위로 줄인다 — 얼굴이 없는 시간에
    // 따라다닐 수는 없다.
    final coverage = _project.faceCoverageFor(layer);
    if (coverage == null) return false;
    layer = layer.copyWith(
      startMs: math.max(layer.startMs, coverage.startMs),
      endMs: math.min(layer.endMs, coverage.endMs),
    );
    if (layer.endMs - layer.startMs < 200) return false;
    _commit(
      _project.copyWith(
        stickerLayers: [...others, layer],
        selectedLayerId: layer.id,
      ),
    );
    return true;
  }

  /// 화면 절대 좌표를 얼굴 기준 오프셋으로 되돌린다.
  ///
  /// 얼굴 추적 스티커의 [EditorStickerLayer.position]은 오프셋이라, 끌어
  /// 놓은 화면 위치에서 지금 재생 위치의 얼굴 중심을 빼야 한다. 구간 줌이
  /// 걸려 있으면 화면 좌표를 줌 이전 자리로 먼저 되돌린다 — 그려질 때
  /// 다시 줌이 입혀지므로, 여기서 안 빼면 두 번 적용된다.
  NormalizedPoint _faceOffsetFor(
    EditorStickerLayer layer,
    NormalizedPoint absolute,
  ) {
    final sourceMs = _project.sourcePositionForTimeline(_project.playheadMs);
    final face = sourceMs == null
        ? null
        : _project.faceSampleForLayer(layer, sourceMs);
    if (face == null) return absolute;
    var x = absolute.x;
    var y = absolute.y;
    final zoom = _project.zoomAtTimeline(_project.playheadMs);
    if (zoom != null && zoom.scale > 0) {
      x = zoom.focus.x + (x - zoom.focus.x) / zoom.scale;
      y = zoom.focus.y + (y - zoom.focus.y) / zoom.scale;
    }
    return NormalizedPoint(0.5 + x - face.x, 0.5 + y - face.y);
  }

  /// 얼굴 추적 스티커가 지금 화면에서 몇 배로 그려지는가(얼굴 크기·줌 반영).
  /// 핀치로 받은 화면 배율을 저장 배율로 되돌릴 때 나눈다.
  double _faceDisplayFactor(EditorStickerLayer layer) =>
      _project.faceStickerPlacementAt(layer, _project.playheadMs)?.scale ?? 1.0;

  /// 얼굴 추적 스티커를 끌어 놓았을 때. 놓은 자리에서 가장 가까운 사람으로
  /// 갈아타고("누구 얼굴에 붙일지"는 끌어다 놓기로 정한다), 그 얼굴 기준
  /// 오프셋으로 저장한다. 갈아타면 구간도 그 사람의 검출 범위로 맞춘다.
  EditorStickerLayer _faceStickerDragged(
    EditorStickerLayer layer,
    NormalizedPoint absolute,
  ) {
    final sourceMs = _project.sourcePositionForTimeline(_project.playheadMs);
    var next = layer;
    if (sourceMs != null && _project.faceTracks.isNotEmpty) {
      // 사람 찾기는 줌 이전 좌표로 한다 — 궤적이 그 좌표계다.
      var x = absolute.x;
      var y = absolute.y;
      final zoom = _project.zoomAtTimeline(_project.playheadMs);
      if (zoom != null && zoom.scale > 0) {
        x = zoom.focus.x + (x - zoom.focus.x) / zoom.scale;
        y = zoom.focus.y + (y - zoom.focus.y) / zoom.scale;
      }
      final candidates = _project.faceTracksAt(
        sourceMs,
        near: NormalizedPoint(x, y),
      );
      if (candidates.isNotEmpty && candidates.first.id != layer.faceTrackId) {
        final switched = layer.copyWith(faceTrackId: candidates.first.id);
        final coverage = _project.faceCoverageFor(switched);
        if (coverage != null && coverage.endMs - coverage.startMs >= 200) {
          next = switched.copyWith(
            startMs: switched.startMs.clamp(
              coverage.startMs,
              coverage.endMs - 200,
            ),
            endMs: switched.endMs.clamp(coverage.startMs + 200, coverage.endMs),
          );
        }
      }
    }
    return next.copyWith(position: _faceOffsetFor(next, absolute));
  }

  /// 새 스티커가 놓일 자리. 전에는 늘 정중앙이라 여러 개를 누르면 같은
  /// 자리에 겹겹이 쌓여 **하나만 있는 것처럼** 보였다 — 이미 스티커가
  /// 있는 자리는 피해 대각선으로 한 칸씩 비켜 놓는다.
  NormalizedPoint _vacantStickerSpot() {
    bool taken(NormalizedPoint spot) => _project.stickerLayers.any((layer) {
      // 얼굴 스티커는 어차피 얼굴을 따라 움직이니 자리를 차지하지 않는다.
      if (layer.tracksFace) return false;
      return (layer.position.x - spot.x).abs() < 0.05 &&
          (layer.position.y - spot.y).abs() < 0.05;
    });
    var spot = NormalizedPoint.center;
    for (var step = 1; step <= 8 && taken(spot); step++) {
      final offset = 0.09 * step;
      spot = NormalizedPoint(
        (0.5 + offset).clamp(0.1, 0.92),
        (0.5 + offset).clamp(0.1, 0.92),
      );
    }
    return spot;
  }

  void addSticker(String value) {
    if (value.isEmpty) return;
    // 스티커는 재생 위치가 속한 클립에 묶여 그 클립 구간에 깔린다 —
    // 자막과 같은 규칙이라 클립을 옮기면 따라가고, 지우면 함께 사라진다.
    final location = _locateTimelinePosition(_project.playheadMs);
    final clipStart = location == null
        ? 0
        : _project.timelineStartFor(location.clip.id);
    final clipEnd = location == null
        ? _project.durationMs
        : clipStart + location.clip.durationMs;
    final layer = EditorStickerLayer(
      id: _nextId('sticker'),
      value: value,
      position: _vacantStickerSpot(),
      startMs: clipStart,
      endMs: clipEnd,
      clipId: location?.clip.id,
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
        if (layer.id == selected)
          // 얼굴 추적 스티커는 놓은 자리의 사람으로 갈아타고 얼굴 기준
          // 오프셋으로 저장한다. 일반 스티커는 그대로 화면 좌표다.
          (layer.tracksFace
              ? _faceStickerDragged(layer, position)
              : layer.copyWith(position: position))
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
                // 얼굴 추적 스티커의 position은 얼굴 기준 오프셋이고,
                // scale도 화면 배율(얼굴 크기·줌 포함)을 저장 배율로 되돌린다.
                position: layer.tracksFace
                    ? _faceOffsetFor(layer, position)
                    : position,
                scale: layer.tracksFace
                    ? scale / _faceDisplayFactor(layer)
                    : scale,
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
        layer.id == selected
            ? layer.copyWith(
                // 얼굴 추적 스티커는 화면 배율을 저장 배율로 되돌린다.
                scale: layer.tracksFace
                    ? scale / _faceDisplayFactor(layer)
                    : scale,
              )
            : layer,
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
      a.canvas.fit == b.canvas.fit &&
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
