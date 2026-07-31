import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
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
