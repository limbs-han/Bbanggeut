/// 앱 안에서 도는 AR 효과 목록.
///
/// **왜 앱 안인가**: 예전에는 AR 탭이 Banuba 편집 화면(별도 Activity)을 띄웠다.
/// 앱을 벗어나 UI/UX가 통째로 바뀌고, 돌아온 결과를 다시 편집기에 밀어넣어야
/// 했다. 이제 효과는 우리 미리보기 위에 바로 얹히고, 저장할 때 media3
/// 오버레이·색 보정으로 그대로 구워진다. 화면을 벗어나지 않는다.
///
/// 각 효과는 두 부분이다.
/// - 얼굴에 얹는 스티커: 얼굴이 있을 만한 자리에 미리 놓아 두고, 사용자가 끌어
///   옮기거나 크기를 바꿀 수 있다(스티커 레이어와 같은 조작).
/// - 화면 색감([EditorLook]): 미리보기와 내보내기가 같은 값을 쓴다.
///
/// **여기 있는 것은 손으로 얹는 그림뿐이다.** 얼굴을 따라다니는 진짜 Banuba
/// 마스크는 목록도 미리보기 그림도 네이티브가 준다(`banuba_mask_channel.dart`의
/// `BanubaMask`). 효과 폴더를 갈아 끼워도 Dart 쪽 목록을 고칠 일이 없도록
/// 그렇게 옮겼다.
library;

import 'editor_project.dart';

/// AR 효과가 놓는 스티커 한 개.
///
/// 좌표를 [NormalizedPoint]가 아니라 double 두 개로 들고 있는 이유: 그쪽
/// 생성자는 값을 잘라내야 해서 const가 될 수 없다. 여기 목록은 const로 두고
/// 적용하는 순간에 점을 만든다.
class EditorArSticker {
  const EditorArSticker({
    required this.value,
    required this.x,
    required this.y,
    this.scale = 1,
  });

  final String value;
  final double x;
  final double y;
  final double scale;

  NormalizedPoint get position => NormalizedPoint(x, y);
}

class EditorArEffect {
  const EditorArEffect({
    required this.id,
    required this.label,
    required this.badge,
    required this.hint,
    this.stickers = const [],
    this.look = EditorLook.none,
  });

  /// 효과 식별자. 프로젝트에 저장해 어느 카드가 켜져 있는지 표시한다.
  final String id;

  /// 패널 카드에 쓰는 이름.
  final String label;

  /// 카드에 크게 보여줄 대표 이모지.
  final String badge;

  /// 적용한 뒤 안내 문구.
  final String hint;

  final List<EditorArSticker> stickers;
  final EditorLook look;

  static const all = <EditorArEffect>[
    EditorArEffect(
      id: 'puppy',
      label: '강아지',
      badge: '🐶',
      hint: '강아지를 얼굴 위로 끌어 올려 보세요.',
      stickers: [
        EditorArSticker(value: '🐶', x: 0.5, y: 0.17, scale: 1.5),
        EditorArSticker(value: '🐾', x: 0.82, y: 0.78, scale: 0.9),
      ],
      look: EditorLook.soft,
    ),
    EditorArEffect(
      id: 'crown',
      label: '왕관',
      badge: '👑',
      hint: '왕관을 머리 위로 옮기고 크기를 맞춰 보세요.',
      stickers: [EditorArSticker(value: '👑', x: 0.5, y: 0.13, scale: 1.4)],
      look: EditorLook.warm,
    ),
    EditorArEffect(
      id: 'sunglasses',
      label: '선글라스',
      badge: '🕶️',
      hint: '선글라스를 눈 위치로 끌어 맞춰 보세요.',
      stickers: [EditorArSticker(value: '🕶️', x: 0.5, y: 0.36, scale: 1.3)],
      look: EditorLook.vivid,
    ),
    EditorArEffect(
      id: 'hearts',
      label: '반짝 하트',
      badge: '💖',
      hint: '하트와 반짝임을 원하는 자리로 옮겨 보세요.',
      stickers: [
        EditorArSticker(value: '💖', x: 0.28, y: 0.24, scale: 1.1),
        EditorArSticker(value: '✨', x: 0.74, y: 0.2),
        EditorArSticker(value: '💖', x: 0.62, y: 0.7, scale: 0.8),
      ],
      look: EditorLook.soft,
    ),
    EditorArEffect(
      id: 'party',
      label: '파티',
      badge: '🥳',
      hint: '축하 스티커를 가족 얼굴 옆으로 옮겨 보세요.',
      stickers: [
        EditorArSticker(value: '🎉', x: 0.2, y: 0.22, scale: 1.2),
        EditorArSticker(value: '🥳', x: 0.5, y: 0.15, scale: 1.3),
        EditorArSticker(value: '🎈', x: 0.82, y: 0.7, scale: 1.1),
      ],
      look: EditorLook.vivid,
    ),
    EditorArEffect(
      id: 'rainbow',
      label: '무지개',
      badge: '🌈',
      hint: '무지개를 배경 쪽으로 옮겨 보세요.',
      stickers: [
        EditorArSticker(value: '🌈', x: 0.5, y: 0.2, scale: 1.5),
        EditorArSticker(value: '☀️', x: 0.85, y: 0.14),
      ],
      look: EditorLook.warm,
    ),
    EditorArEffect(
      id: 'film',
      label: '흑백 필름',
      badge: '🎞️',
      hint: '영상 전체가 흑백으로 바뀌었어요.',
      look: EditorLook.mono,
    ),
    EditorArEffect(
      id: 'glow',
      label: '보정 글로우',
      badge: '🌤️',
      hint: '얼굴빛을 한 톤 밝고 부드럽게 바꿨어요.',
      look: EditorLook.soft,
    ),
  ];

  static EditorArEffect? byId(String? id) {
    if (id == null) return null;
    for (final effect in all) {
      if (effect.id == id) return effect;
    }
    return null;
  }

  /// 스티커 탭에 함께 올릴 이모지들. 예전 AR 탭에 있던 것들이 여기로 왔다 —
  /// 진짜 AR은 Banuba가 맡고, 손으로 얹는 그림은 스티커 탭 한 곳에 모은다.
  static List<String> get stickerValues {
    final values = <String>[];
    for (final effect in all) {
      for (final sticker in effect.stickers) {
        if (!values.contains(sticker.value)) values.add(sticker.value);
      }
    }
    return values;
  }
}
