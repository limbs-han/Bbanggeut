import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../ui/content_video_detail_screen.dart';
import '../../ui/profile_avatar.dart';
import '../../ui/widgets.dart';
import 'laugh_draw_controller.dart';
import 'laugh_draw_machine.dart';
import 'laugh_draw_models.dart';
import 'laugh_draw_repository.dart';
import 'laugh_memory_thumbnail.dart';

/// 추억 뽑기 — 커뮤니티 탭의 본 화면.
///
/// 최근 3일(72시간) 안에 실제로 저장된 우리 가족 웃음 영상 하나를 뽑기 기계에서
/// 꺼내 보고, 가족이 이모지 반응을 남긴다.
///
/// **영상은 언제나 서버에서 온다**: 개발용 데모 데이터를 쓰지 않는다. 뽑기의 값은
/// "정말 우리 집에서 있었던 일"이 나오는 데 있어서, 표본 영상이 섞이면 기능 자체가
/// 거짓이 된다. 서버가 답하지 못하면 표본으로 메우지 말고 empty·error 화면을 보여 준다.
///
/// **재생은 기존 상세 화면에 맡긴다**: 추억 목록·홈에서 쓰는
/// [ContentVideoDetailScreen]이 이미 재생 URL 발급, 재생기 정리, 탭 이동·백그라운드
/// 대응을 모두 하고 있다. 여기에 재생기를 하나 더 만들면 컨트롤러가 두 벌이 되고
/// 뽑기 효과음과 영상 소리가 겹친다.
class LaughDrawScreen extends StatefulWidget {
  const LaughDrawScreen({super.key, required this.app});

  final AppController app;

  @override
  State<LaughDrawScreen> createState() => _LaughDrawScreenState();
}

class _LaughDrawScreenState extends State<LaughDrawScreen>
    with WidgetsBindingObserver {
  static final _capturedAt = DateFormat('yyyy.MM.dd a h:mm', 'ko');
  static final _expiresAt = DateFormat('M월 d일', 'ko');

  /// 서버에 제목·메모가 없을 때 채우는 문구. 영상 내용을 앱이 지어내지 않도록
  /// 특정 사건을 가리키지 않는 말만 쓴다.
  static const _fallbackTitle = '우리 가족의 웃음 순간';
  static const _fallbackDescription = '그날 우리 가족은 한참 웃었어요';

  /// [VideoMemory.fromJson]이 제목 없는 영상에 넣는 기본값. 이 값이 화면에
  /// 그대로 나오면 "이름 없는 추억"이 뽑힌 것처럼 보여서 한 번 더 갈아 준다.
  static const _serverPlaceholderTitle = '이름 없는 추억';

  late final LaughDrawController controller;

  /// 앱이 앞에 있는가. 백그라운드에서는 공을 돌리지도, 소리를 내지도 않는다.
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    controller = LaughDrawController(
      widget.app.selectedVault!.id,
      RemoteLaughDrawRepository(widget.app.api),
    )..addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    // 오늘 이미 뽑았다면 그 결과를 되살린다.
    controller.restoreToday();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    if (!foreground) controller.quiet();
    if (mounted) setState(() => _foreground = foreground);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  Future<void> _draw() async {
    if (!controller.canDraw) return;
    await controller.draw();
    if (!mounted) return;
    final failure = controller.errorMessage;
    if (controller.phase == LaughDrawPhase.error && failure != null) {
      showAppSnack(context, failure, error: true);
    }
  }

  Future<void> _submitReaction() async {
    final ok = await controller.submitReaction();
    if (!mounted || ok) return;
    showAppSnack(
      context,
      controller.lastActionError ?? '반응을 남기지 못했어요.',
      error: true,
    );
  }

  /// 영상 재생. 뽑기 효과음이 영상 소리와 겹치지 않게 먼저 소리를 끊는다.
  void _openMemory(LaughMemory memory) {
    controller.quiet();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ContentVideoDetailScreen(
          controller: widget.app,
          video: memory.video,
        ),
      ),
    );
  }

  String _title(LaughMemory memory) {
    final title = memory.video.title.trim();
    return title.isEmpty || title == _serverPlaceholderTitle
        ? _fallbackTitle
        : title;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: AppBar(title: const Text('추억 뽑기')),
    body: AppBackdrop(
      child: SafeArea(
        top: false,
        // 뽑는 동안에는 기계가 주인공이라 화면 가운데를 통째로 쓴다. 결과가 나온
        // 뒤에는 영상이 주인공이라 기계를 헤더 옆으로 접어 둔다.
        child: controller.isDrawing ? _drawingBody() : _scrollBody(),
      ),
    ),
  );

  /// 뽑는 중: 기계를 화면 정중앙에 가로폭 80%로 크게 놓는다.
  Widget _drawingBody() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
    child: Column(
      children: [
        Text(
          '추억을 뽑고 있어요!',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        Text(
          '어떤 영상이 나올까요?',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        Expanded(child: _bigStage()),
        _drawButton(),
      ],
    ),
  );

  /// 뽑기 기계 + 빵긋이 + 반짝임. 기계는 가로폭의 80%.
  Widget _bigStage() => LayoutBuilder(
    builder: (context, constraints) {
      final machineWidth = constraints.maxWidth * 0.8;
      return Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            width: machineWidth,
            child: LaughDrawMachine(
              phase: controller.phase,
              animate: _foreground,
            ),
          ),
          // 빵긋이는 기계 왼쪽 아래에서 결과를 기다린다.
          Positioned(
            left: 0,
            bottom: constraints.maxHeight * 0.06,
            child: Image.asset(
              'assets/images/memory_peek_mascot.png',
              width: 92,
              fit: BoxFit.contain,
              cacheWidth: decodePixels(context, 92),
              semanticLabel: '빵긋 캐릭터',
            ),
          ),
          Positioned(
            right: 2,
            top: constraints.maxHeight * 0.12,
            child: const _Sparkle(size: 30),
          ),
          Positioned(
            left: 10,
            top: constraints.maxHeight * 0.3,
            child: const _Sparkle(size: 18),
          ),
          Positioned(
            right: 34,
            top: constraints.maxHeight * 0.36,
            child: const _Sparkle(size: 22),
          ),
        ],
      );
    },
  );

  Widget _scrollBody() {
    final memory = controller.memory;
    final showResult =
        controller.phase == LaughDrawPhase.success && memory != null;
    return ListView(
      key: const PageStorageKey('laugh-draw-scroll'),
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
      children: [
        if (showResult) ..._resultChildren(memory) else ..._entryChildren(),
      ],
    );
  }

  /// 아직 뽑지 않았을 때(또는 비었을 때·실패했을 때): 기계가 주인공이다.
  List<Widget> _entryChildren() => [
    Text('오늘은 어떤 영상이 나올까?', style: Theme.of(context).textTheme.headlineMedium),
    const SizedBox(height: 6),
    Text(
      '최근 3일간 저장된 우리 가족의 웃음 중\n하나를 랜덤으로 꺼내봐요!',
      style: Theme.of(context).textTheme.bodyLarge,
    ),
    const SizedBox(height: 8),
    LayoutBuilder(
      builder: (context, constraints) =>
          SizedBox(height: 300, child: _bigStage()),
    ),
    const SizedBox(height: 10),
    _drawButton(),
    const SizedBox(height: 14),
    switch (controller.phase) {
      LaughDrawPhase.empty => _empty(),
      LaughDrawPhase.error => _error(),
      _ => _hint(),
    },
  ];

  /// 결과가 나온 뒤: 영상이 주인공이고 기계는 헤더 옆으로 접힌다.
  ///
  /// 순서는 오늘 꺼낸 추억 → 영상 카드 → 반응 선택 → 저장 버튼 → 가족 반응 →
  /// 다시 뽑기 → 만료 안내.
  List<Widget> _resultChildren(LaughMemory memory) => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '오늘 꺼낸 추억',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 6),
              Text(
                '마음에 드는 추억이 나왔나요?\n가족에게 반응을 남겨 보세요.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // 접힌 기계. 여기서는 장식이라 애니메이션도 돌리지 않는다.
        SizedBox(
          width: 88,
          child: LaughDrawMachine(
            phase: LaughDrawPhase.success,
            animate: false,
          ),
        ),
      ],
    ),
    const SizedBox(height: 12),
    _memoryCard(memory),
    const SizedBox(height: 14),
    _reactions(memory),
    const SizedBox(height: 14),
    _familyReactions(memory),
    const SizedBox(height: 18),
    _drawButton(),
    if (memory.expiresAt != null)
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          '이 추억은 ${_expiresAt.format(memory.expiresAt!)}까지 볼 수 있어요',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ),
  ];

  Widget _drawButton() {
    final drawing = controller.isDrawing;
    final again = controller.hasResult;
    final label = drawing
        ? '추억을 찾고 있어요...'
        : controller.restoring
        ? '오늘 꺼낸 추억을 불러오는 중...'
        : again
        ? '다시 뽑기'
        : '추억 뽑기';
    return FilledButton.icon(
      key: const Key('laugh-draw-button'),
      // 연출 중에는 버튼을 잠근다 — 연속 탭이 요청과 효과음을 겹치게 한다.
      onPressed: controller.canDraw ? _draw : null,
      icon: drawing || controller.restoring
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Colors.white,
              ),
            )
          : Icon(again ? Icons.autorenew_rounded : Icons.casino_rounded),
      label: Text(label, textAlign: TextAlign.center),
    );
  }

  /// 영상 카드. 썸네일이나 카드를 누르면 기존 상세 화면으로 간다 —
  /// 별도의 재생 버튼은 두지 않는다.
  Widget _memoryCard(LaughMemory memory) => SoftCard(
    key: const Key('laugh-draw-result'),
    padding: EdgeInsets.zero,
    child: InkWell(
      key: const Key('laugh-draw-play'),
      borderRadius: BorderRadius.circular(22),
      onTap: () => _openMemory(memory),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LaughMemoryThumbnail(api: widget.app.api, video: memory.video),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0x59000000)],
                    ),
                  ),
                  child: SizedBox.expand(),
                ),
                const Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x73000000),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(11),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: _Chip(
                    label: durationLabel(memory.video.durationMs),
                    background: const Color(0xB3000000),
                    foreground: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.event_available_rounded,
                      size: 15,
                      color: AppColors.coralDark,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        memory.capturedAt == null
                            ? '시간 정보 없음'
                            : _capturedAt.format(memory.capturedAt!),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.coralDark,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  _title(memory),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 3),
                Text(
                  // 영상 메모 기능은 develop에서 제거됐다(6393a77). 서버가 설명을
                  // 주지 않으므로 뽑기 화면은 이 고정 문구만 쓴다.
                  _fallbackDescription,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                VideoEventTypePills(video: memory.video, compact: true),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  /// 이모지 반응. 고르기만 하고, 저장은 아래 버튼으로 확정한다.
  Widget _reactions(LaughMemory memory) => SoftCard(
    color: AppColors.pinkSoft,
    borderColor: AppColors.coralSoft,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('💗', style: TextStyle(fontSize: 17)),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                '이 추억, 어떤 느낌인가요?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
            ),
            if (controller.reacting)
              const SizedBox.square(
                dimension: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            final columnWidth = (constraints.maxWidth - spacing) / 2;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final reaction in LaughReactionType.values)
                  SizedBox(
                    width: columnWidth,
                    child: _ReactionChip(
                      reaction: reaction,
                      count: memory.countOf(reaction),
                      selected: controller.pendingReaction == reaction,
                      onTap: controller.canPickReaction
                          ? () => controller.selectReaction(reaction)
                          : null,
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        _reactionActions(),
      ],
    ),
  );

  /// 반응 남기기 / 반응 다시 고르기 / 변경사항 저장하기 + 취소.
  Widget _reactionActions() {
    final mode = controller.reactionMode;
    if (mode == LaughReactionMode.saved) {
      return OutlinedButton.icon(
        key: const Key('laugh-draw-reaction-edit'),
        onPressed: controller.reacting ? null : controller.startEditingReaction,
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('반응 다시 고르기'),
      );
    }
    final editing = mode == LaughReactionMode.editing;
    return Column(
      children: [
        FilledButton.icon(
          key: const Key('laugh-draw-reaction-submit'),
          onPressed: controller.canSubmitReaction ? _submitReaction : null,
          icon: Icon(
            editing ? Icons.save_outlined : Icons.edit_note_rounded,
            size: 19,
          ),
          label: Text(editing ? '변경사항 저장하기' : '반응 남기기'),
        ),
        if (editing)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton(
              key: const Key('laugh-draw-reaction-cancel'),
              onPressed: controller.reacting
                  ? null
                  : controller.cancelEditingReaction,
              child: const Text('취소'),
            ),
          ),
      ],
    );
  }

  /// 가족 반응. 서버가 준 구성원만, 서버가 준 이름과 반응으로 그린다.
  Widget _familyReactions(LaughMemory memory) => SoftCard(
    key: const Key('laugh-draw-family-reactions'),
    color: AppColors.surfaceWarm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.groups_rounded,
              size: 18,
              color: AppColors.inkSoft,
            ),
            const SizedBox(width: 6),
            const Text('가족 반응', style: TextStyle(fontWeight: FontWeight.w900)),
            const Spacer(),
            Text(
              '${memory.familyReactions.length}명',
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (memory.familyReactions.isEmpty)
          const Text(
            '아직 아무도 반응을 남기지 않았어요.\n첫 반응을 남겨 보세요!',
            style: TextStyle(fontSize: 12, color: AppColors.muted, height: 1.6),
          )
        else
          // 구성원이 많아도 넘치지 않게 감싼다.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: memory.familyReactions
                .map((member) => _FamilyReactionChip(member: member))
                .toList(growable: false),
          ),
      ],
    ),
  );

  /// 처음 들어왔을 때의 안내. 뽑기 규칙을 한 번만 짧게 알려 준다.
  Widget _hint() => SoftCard(
    color: AppColors.surfaceWarm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(
              Icons.lightbulb_outline_rounded,
              size: 18,
              color: AppColors.sageDark,
            ),
            SizedBox(width: 6),
            Text('이렇게 뽑아요', style: TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '• 최근 3일(72시간) 안에 저장된 웃음 영상만 뽑기에 들어가요.\n'
          '• 오늘 뽑은 추억은 하루 동안 이 화면에 그대로 남아요.\n'
          '• 마음에 남는 추억에는 이모지 반응을 남길 수 있어요.',
          style: TextStyle(fontSize: 12, color: AppColors.inkSoft, height: 1.7),
        ),
      ],
    ),
  );

  Widget _empty() => SoftCard(
    key: const Key('laugh-draw-empty'),
    color: AppColors.surfaceWarm,
    child: Column(
      children: [
        const Text('🫧', style: TextStyle(fontSize: 30)),
        const SizedBox(height: 6),
        const Text(
          '이번에는 꺼낼 영상이 없어요',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          '최근 3일 동안 웃음 영상이 저장되면\n다시 뽑아볼 수 있어요.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.inkSoft),
        ),
        if (controller.emptyMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              controller.emptyMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ),
      ],
    ),
  );

  Widget _error() => SoftCard(
    key: const Key('laugh-draw-error'),
    color: AppColors.pinkSoft,
    child: Column(
      children: [
        const Text(
          '추억 뽑기에 실패했어요.',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          controller.errorMessage ?? '잠시 후 다시 시도해 주세요.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.inkSoft),
        ),
      ],
    ),
  );
}

/// 이모지 반응 칩. 이모지를 크게 두고, 고른 것은 코랄 테두리와 체크로 알린다 —
/// 색만으로 선택을 표현하지 않는다.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.reaction,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final LaughReactionType reaction;
  final int count;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? AppColors.coralSoft : AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(
        color: selected ? AppColors.coral : AppColors.line,
        width: selected ? 1.8 : 1.1,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        // 손가락이 닿는 자리는 최소 48dp.
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          child: Row(
            children: [
              Text(reaction.emoji, style: const TextStyle(fontSize: 21)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  reaction.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    fontWeight: FontWeight.w800,
                    color: selected ? AppColors.coralDark : AppColors.ink,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 2),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 15,
                    color: AppColors.coral,
                  ),
                ),
              _Chip(
                label: '$count',
                background: selected
                    ? Colors.white.withValues(alpha: 0.85)
                    : AppColors.surfaceWarm,
                foreground: selected ? AppColors.coralDark : AppColors.muted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 가족 반응 한 줄: 아바타 + 이름 + 이모지 + 문구.
class _FamilyReactionChip extends StatelessWidget {
  const _FamilyReactionChip({required this.member});

  final LaughReactionMember member;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: member.isMe ? AppColors.coral : AppColors.line,
        width: member.isMe ? 1.5 : 1.1,
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 프로필 사진은 기기에만 있는 값이라 본인 것만 실제 아바타로 그린다.
        if (member.isMe)
          const ProfileAvatarView(radius: 17)
        else
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
              color: AppColors.sageSoft,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              member.initial,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: AppColors.sageDark,
              ),
            ),
          ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              member.isMe ? '${member.displayName} (나)' : member.displayName,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 1),
            Text(
              '${member.reaction.emoji} ${member.reaction.label}',
              style: const TextStyle(fontSize: 11, color: AppColors.inkSoft),
            ),
          ],
        ),
      ],
    ),
  );
}

/// 작은 알약 라벨. 재생 시간과 반응 개수가 같은 모양을 쓴다.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w900,
        color: foreground,
      ),
    ),
  );
}

/// 뽑는 동안 옆에서 반짝이는 장식. 그림을 새로 만들지 않고 이모지 하나로 끝낸다.
class _Sparkle extends StatelessWidget {
  const _Sparkle({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Text('✨', style: TextStyle(fontSize: size)),
  );
}
