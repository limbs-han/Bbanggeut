import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_ar_effects.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';

void main() {
  EditorProjectController controller() => EditorProjectController(
    EditorProject.fromSource(
      sourceVideoPath: '/tmp/source.mp4',
      sourceDurationMs: 10 * 1000,
      sourceSize: const EditorSourceSize(width: 1920, height: 1080),
    ),
  );

  test('원본 비율을 유지하고 명시적으로 선택한 비율만 적용한다', () {
    final subject = controller();

    expect(subject.project.canvas.aspectRatio, 16 / 9);

    subject.setCanvasRatio(EditorCanvasRatio.vertical);

    expect(subject.project.canvas.aspectRatio, 9 / 16);
  });

  test('편집하지 않은 원본만 재인코딩을 생략한다', () {
    final subject = controller();

    expect(subject.project.requiresRendering(), isFalse);
    expect(subject.project.requiresRendering(hasCaptions: true), isTrue);

    subject.trimSelectedClip(sourceStartMs: 1000);
    expect(subject.project.requiresRendering(), isTrue);
  });

  test('구간을 정한 직후에도 분할할 수 있다', () {
    final subject = controller();

    // 편집기를 열면 재생 위치는 맨 앞이다. 그 자리에서는 앞쪽에 남는 길이가 0이라
    // 나눌 수 없다 — 분할 단추가 흐려져 있는 게 맞다.
    expect(subject.project.playheadMs, 0);
    expect(subject.canSplitAtPlayhead, isFalse);

    // 구간을 정하면 화면이 재생 위치를 구간 가운데로 들인다. 그러면 어느 쪽으로도
    // 자를 수 있다. 예전에는 구간 맨 앞에 그대로 붙어 있어서, 구간을 정한 뒤에도
    // 분할이 영영 흐린 채였다.
    subject.trimSelectedClip(sourceStartMs: 3000, sourceEndMs: 9000);
    final center = subject.timelineCenterOfSelectedClip();
    expect(center, isNotNull);
    subject.setPlayhead(center!);

    expect(subject.canSplitAtPlayhead, isTrue);
    expect(subject.splitAt(center), isTrue);
    expect(subject.project.clips, hasLength(2));
    // 나뉜 두 조각을 이으면 정해 둔 구간 그대로다.
    expect(subject.project.clips.first.sourceStartMs, 3000);
    expect(subject.project.clips.last.sourceEndMs, 9000);
    expect(
      subject.project.clips.first.sourceEndMs,
      subject.project.clips.last.sourceStartMs,
    );
  });

  test('재생 위치는 고른 구간 안에 머문다', () {
    final subject = controller();

    subject.trimSelectedClip(sourceStartMs: 4000, sourceEndMs: 6000);
    final center = subject.timelineCenterOfSelectedClip()!;
    final clip = subject.project.clips.single;

    // 타임라인 기준 가운데는 구간 길이의 절반이다(앞 클립이 없으므로 0에서 시작).
    expect(center, clip.durationMs ~/ 2);
    expect(center, greaterThan(0));
    expect(center, lessThan(subject.project.durationMs));
  });

  test('나누기만 하고 아무것도 지우지 않으면 다시 만들 것이 없다', () {
    final subject = controller();

    expect(subject.splitAt(4000), isTrue);
    expect(subject.project.clips, hasLength(2));
    // 이어 붙이면 원본 그대로다 — 몇십 초짜리 재인코딩을 할 이유가 없다.
    expect(subject.project.requiresRendering(), isFalse);

    // 가운데가 비면 이야기가 다르다. 그건 실제로 다른 영상이다.
    subject.selectClip(subject.project.clips.first.id);
    subject.deleteSelectedClip();
    expect(subject.project.requiresRendering(), isTrue);
  });

  test('재생 헤드에서 분할하고 타임라인 길이를 보존한다', () {
    final subject = controller();

    expect(subject.splitAt(4000), isTrue);

    expect(subject.project.clips, hasLength(2));
    expect(subject.project.clips[0].sourceStartMs, 0);
    expect(subject.project.clips[0].sourceEndMs, 4000);
    expect(subject.project.clips[1].sourceStartMs, 4000);
    expect(subject.project.clips[1].sourceEndMs, 10000);
    expect(subject.project.durationMs, 10000);
  });

  test('최소 길이보다 짧은 분할과 마지막 클립 삭제를 거부한다', () {
    final subject = controller();

    expect(subject.splitAt(50), isFalse);
    expect(subject.deleteSelectedClip(), isFalse);
    expect(subject.project.clips, hasLength(1));
  });

  test('선택 클립의 시작과 끝을 트림하고 최소 길이를 지킨다', () {
    final subject = controller();

    expect(
      subject.trimSelectedClip(sourceStartMs: 1200, sourceEndMs: 7600),
      isTrue,
    );
    expect(subject.project.selectedClip?.sourceStartMs, 1200);
    expect(subject.project.selectedClip?.sourceEndMs, 7600);
    expect(subject.project.durationMs, 6400);
    expect(subject.trimSelectedClip(sourceStartMs: 7550), isFalse);
  });

  test('단일 영상에서 설정한 구간을 삭제하면 앞뒤 구간을 보존한다', () {
    final subject = controller();
    subject.trimSelectedClip(sourceStartMs: 1200, sourceEndMs: 7600);

    expect(subject.canDeleteSelectedClip, isTrue);
    expect(subject.deleteSelectedClip(), isTrue);
    expect(subject.project.clips, hasLength(2));
    expect(subject.project.clips[0].sourceStartMs, 0);
    expect(subject.project.clips[0].sourceEndMs, 1200);
    expect(subject.project.clips[1].sourceStartMs, 7600);
    expect(subject.project.clips[1].sourceEndMs, 10000);
  });

  test('선택 클립을 복제·삭제하고 재생 헤드를 유효 범위로 보정한다', () {
    final subject = controller();
    subject.setPlayhead(9000);

    expect(subject.duplicateSelectedClip(), isTrue);
    expect(subject.project.durationMs, 20000);
    expect(subject.project.clips, hasLength(2));

    expect(subject.deleteSelectedClip(), isTrue);
    expect(subject.project.durationMs, 10000);
    expect(subject.project.playheadMs, 9000);
  });

  test('실행 취소와 다시 실행이 편집 스냅샷을 복원한다', () {
    final subject = controller();

    subject.splitAt(5000);
    subject.duplicateSelectedClip();
    expect(subject.project.clips, hasLength(3));

    subject.undo();
    expect(subject.project.clips, hasLength(2));

    subject.undo();
    expect(subject.project.clips, hasLength(1));

    subject.redo();
    expect(subject.project.clips, hasLength(2));
  });

  test('정규화 좌표와 캔버스 변환을 안전 범위로 제한한다', () {
    final subject = controller();
    final point = NormalizedPoint(-3, 4);

    expect(point.x, 0);
    expect(point.y, 1);

    subject.setCanvasTransform(
      scale: 9,
      offsetX: -3,
      offsetY: 2,
      rotationDegrees: 30,
    );

    expect(subject.project.canvas.scale, 4);
    expect(subject.project.canvas.offsetX, -1);
    expect(subject.project.canvas.offsetY, 1);
    expect(subject.project.canvas.rotationDegrees, 30);
  });

  test('플랫폼 DTO에는 클립별 누적 타임라인과 정규화 레이어가 들어간다', () {
    final subject = controller();
    subject.splitAt(2500);
    subject.addTextLayer(text: '기억');
    subject.addSticker('😊');

    final dto = subject.project.toPlatformMap(outputPath: '/tmp/out.mp4');
    final clips = dto['clips']! as List<Map<String, Object?>>;
    final texts = dto['textLayers']! as List<Map<String, Object>>;

    expect(clips[0]['timelineStartMs'], 0);
    expect(clips[1]['timelineStartMs'], 2500);
    expect(texts.single['position'], {'x': 0.5, 'y': 0.78});
    expect(dto['outputPath'], '/tmp/out.mp4');
  });

  test('텍스트 굵기와 크기를 바꾸고 영상 위에서 이동·확대할 수 있다', () {
    final subject = controller();
    subject.addTextLayer(text: '우리 가족', startMs: 0, fontSize: 48, bold: false);
    final id = subject.project.selectedLayerId!;

    expect(
      subject.updateSelectedTextLayer(
        text: '행복한 우리 가족',
        color: const Color(0xFFFF725B),
        fontSize: 72,
        bold: true,
      ),
      isTrue,
    );
    subject.beginLayerGesture(id);
    subject.updateSelectedLayerTransform(
      position: NormalizedPoint(0.25, 0.35),
      scale: 1.8,
      rotationDegrees: 12,
    );
    subject.endLayerGesture();

    final layer = subject.project.textLayers.single;
    expect(layer.text, '행복한 우리 가족');
    expect(layer.bold, isTrue);
    expect(layer.fontSize, 72);
    expect(layer.position, NormalizedPoint(0.25, 0.35));
    expect(layer.scale, 1.8);
    expect(layer.rotationDegrees, 12);
  });

  test('새 글자는 배경 없이 만들어진다', () {
    final subject = controller();
    subject.addTextLayer(text: '배경 없는 글자');

    expect(subject.project.textLayers.single.backgroundColor.a, 0);
  });

  test('모서리 손잡이로 크기만 바꾸면 위치와 회전은 그대로다', () {
    final subject = controller();
    subject.addSticker('⭐');
    final id = subject.project.selectedLayerId!;
    subject.beginLayerGesture(id);
    subject.updateSelectedLayerTransform(
      position: NormalizedPoint(0.3, 0.4),
      scale: 1,
      rotationDegrees: 20,
    );
    subject.endLayerGesture();

    subject.beginLayerGesture(id);
    subject.updateSelectedLayerScale(2.5);
    subject.endLayerGesture();

    final layer = subject.project.stickerLayers.single;
    expect(layer.scale, 2.5);
    expect(layer.position, NormalizedPoint(0.3, 0.4));
    expect(layer.rotationDegrees, 20);
  });

  test('레이어를 골라도 선택 클립은 유지되고, 빈 곳을 누르면 선택이 풀린다', () {
    final subject = controller();
    subject.addTextLayer(text: '기억');
    final id = subject.project.textLayers.single.id;

    subject.selectLayer(id);
    expect(subject.project.selectedLayerId, id);
    // 컷 편집이 계속 동작해야 한다 — 선택 클립이 사라지면 분할·삭제·복제가
    // 전부 조용히 실패한다.
    expect(subject.project.selectedClip, isNotNull);
    expect(subject.duplicateSelectedClip(), isTrue);

    subject.deselectLayer();
    expect(subject.project.selectedLayerId, isNull);
  });

  test('재생 위치가 클립 끝에 붙어 있으면 분할할 수 없다고 미리 알려준다', () {
    final subject = controller();

    subject.setPlayhead(0);
    expect(subject.canSplitAtPlayhead, isFalse);

    subject.setPlayhead(5000);
    expect(subject.canSplitAtPlayhead, isTrue);

    subject.setPlayhead(10000);
    expect(subject.canSplitAtPlayhead, isFalse);
  });

  test('타임라인 시각으로 클립을 고른다', () {
    final subject = controller();
    subject.splitAt(4000);

    subject.selectClipAtTimeline(6000);
    expect(subject.project.selectedClip?.sourceStartMs, 4000);

    subject.selectClipAtTimeline(1000);
    expect(subject.project.selectedClip?.sourceStartMs, 0);

    // 이음매를 짚으면 뒤 클립이다. 앞 클립의 맨 끝으로 잡히면 그 자리에서
    // 남는 길이가 0이라 분할도 막히고, 고른 클립도 사용자가 짚은 것과 달라진다.
    subject.selectClipAtTimeline(4000);
    expect(subject.project.selectedClip?.sourceStartMs, 4000);

    // 마지막 클립만 끝 시각을 품는다 — 그래야 맨 끝을 짚을 수 있다.
    subject.selectClipAtTimeline(subject.project.durationMs);
    expect(subject.project.selectedClip?.sourceStartMs, 4000);
  });

  test('앱 안 AR 효과는 색감과 얼굴 스티커를 함께 켜고 끈다', () {
    final subject = controller();
    subject.addSticker('⭐');
    final puppy = EditorArEffect.all.firstWhere((it) => it.id == 'puppy');
    final film = EditorArEffect.all.firstWhere((it) => it.id == 'film');

    subject.applyArEffect(puppy);
    expect(subject.project.arEffectId, 'puppy');
    expect(subject.project.look, EditorLook.soft);
    expect(
      subject.project.stickerLayers,
      hasLength(1 + puppy.stickers.length),
      reason: '손으로 놓은 스티커는 남아야 한다',
    );
    expect(subject.project.requiresRendering(), isTrue);

    // 효과를 바꾸면 앞서 켠 AR 스티커만 갈아 끼운다.
    subject.applyArEffect(film);
    expect(subject.project.look, EditorLook.mono);
    expect(subject.project.stickerLayers, hasLength(1));

    subject.clearArEffect();
    expect(subject.project.arEffectId, isNull);
    expect(subject.project.look, EditorLook.none);
    expect(subject.project.stickerLayers.single.value, '⭐');
  });

  test('플랫폼 DTO에 색감을 함께 넘긴다', () {
    final subject = controller();
    subject.setLook(EditorLook.vivid);

    final dto = subject.project.toPlatformMap(outputPath: '/tmp/out.mp4');

    expect(dto['look'], 'vivid');
  });

  test('스티커를 영상 위에서 이동하고 크기와 회전을 조절할 수 있다', () {
    final subject = controller();
    subject.addSticker('⭐');
    final id = subject.project.selectedLayerId!;

    subject.beginLayerGesture(id);
    subject.updateSelectedLayerTransform(
      position: NormalizedPoint(0.72, 0.18),
      scale: 2.2,
      rotationDegrees: -18,
    );
    subject.endLayerGesture();

    final layer = subject.project.stickerLayers.single;
    expect(layer.startMs, 0);
    expect(layer.endMs, subject.project.durationMs);
    expect(layer.position, NormalizedPoint(0.72, 0.18));
    expect(layer.scale, 2.2);
    expect(layer.rotationDegrees, -18);
  });
}
