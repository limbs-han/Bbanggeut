/// 만화 한 장을 크게 보는 화면.
///
/// **왜 따로 있나**: 예전에는 "크게 보기"와 카드 탭이 모두 [ComicScreen] —
/// 대사를 고쳐 다시 그리는 편집 화면 — 을 열었다. 크게 보려고 눌렀는데 편집
/// 화면이 뜨니 아무도 만화를 크게 볼 수 없었다.
///
/// **왜 대사를 여기서 그리나**: 만화 그림에는 말풍선이 없다(그림 프롬프트가
/// 일부러 막는다 — 모델이 그린 글자는 깨진 한글이 되기 때문이다). 그래서
/// 대사는 앱이 얹어야 하고, 그러지 않으면 "만화에 텍스트가 안 뜬다"가 된다.
/// 대사는 그림을 받을 때 함께 온 저장 구성(cuts)을 쓴다 — 새로 만들지 않으므로
/// 과금도, 사용자가 고친 대사를 덮을 일도 없다.
///
/// 대사는 **그림 위 자막 띠**([ComicCanvas])와 아래 대사 칸에 함께 둔다.
/// 띠는 어느 칸의 말인지 알려 주고, 아래 칸은 띠 글씨(11pt)가 작아 읽기 힘든
/// 사람을 위한 것이다. 하나만 두면 둘 중 한쪽이 아쉬워진다.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'comic_script.dart';
import 'panel_subtitle.dart';

class ComicViewerScreen extends StatelessWidget {
  const ComicViewerScreen({
    super.key,
    required this.title,
    required this.image,
    this.cuts,
    this.onEdit,
  });

  final String title;

  /// 2x2 격자 만화 한 장. 아직 못 받았으면 null이다.
  final Uint8List? image;

  /// 저장된 4컷 구성. 대사가 여기 있다. 없으면 대사 칸을 접는다.
  final List<ComicCut>? cuts;

  /// 만화를 고치러 가는 길. null이면 버튼을 감춘다.
  final VoidCallback? onEdit;

  /// 대사가 하나라도 있는 컷들. 상황만 있는 컷은 빼고 보여 준다.
  List<({int number, ComicCut cut})> get _spoken => [
    for (final (index, cut) in (cuts ?? const <ComicCut>[]).indexed)
      if ((cut.dialogue ?? '').trim().isNotEmpty)
        (number: index + 1, cut: cut),
  ];

  @override
  Widget build(BuildContext context) {
    final spoken = _spoken;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (onEdit != null)
            TextButton.icon(
              key: const Key('comic-viewer-edit'),
              onPressed: onEdit,
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('수정하기'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('comic-viewer-body'),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // 두 손가락으로 벌려 볼 수 있게 한다 — 4컷을 한 장에 담으면 글씨와
            // 표정이 작아진다.
            AspectRatio(
              aspectRatio: 1,
              child: image == null
                  ? const Center(
                      child: Text(
                        '만화를 불러오지 못했어요',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    )
                  : InteractiveViewer(
                      key: const Key('comic-viewer-image'),
                      maxScale: 4,
                      // 대사는 그림 위에 얹어야 만화가 된다. 아래 대사 칸만
                      // 두었더니 "만화에 글자가 없다"는 말이 그대로 남았다 —
                      // 그림과 말이 떨어져 있으면 어느 칸의 말인지 알 수 없다.
                      // 벌려 보면 띠도 함께 커진다.
                      child: cuts == null || cuts!.isEmpty
                          ? Image.memory(image!, fit: BoxFit.contain)
                          : ComicCanvas(image: image!, cuts: cuts!),
                    ),
            ),
            if (spoken.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '대사',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final entry in spoken)
                      Padding(
                        key: Key('comic-viewer-line-${entry.number}'),
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.coral,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                '${entry.number}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                entry.cut.dialogue!.trim(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
