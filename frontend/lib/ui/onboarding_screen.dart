import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import 'widgets.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onFinished});

  final Future<void> Function() onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _page = 0;
  bool _finishing = false;

  static const _pages = [
    (
      eyebrow: '1 / 4',
      title: '우리집 웃음을 놓치지 않을게요.',
      body: '빵긋이가 소중한 순간을 감지하고\n따뜻한 추억으로 기록해요.',
      type: _OnboardingVisual.mascot,
    ),
    (
      eyebrow: '2 / 4',
      title: '쉽게 보고, 예쁘게 편집해요',
      body: '기록된 순간을 모아\n나만의 가족 이야기를 만들어보세요.',
      type: _OnboardingVisual.edit,
    ),
    (
      eyebrow: '3 / 4',
      title: '가족과 함께 추억을 나눠요',
      body: '언제 어디서든 함께 보고\n우리 집의 웃음을 공유할 수 있어요.',
      type: _OnboardingVisual.family,
    ),
    (
      eyebrow: '4 / 4',
      title: '매일의 웃음이 우리집 보물이 돼요',
      body: '오늘부터 빵긋이와 함께\n소중한 순간을 차곡차곡 모아봐요.',
      type: _OnboardingVisual.ready,
    ),
  ];

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.onFinished();
  }

  void _next() {
    if (_page == _pages.length - 1) {
      _finish();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 18, 0),
              child: Row(
                children: [
                  Image.asset(
                    'assets/images/bbanggeut_logo.png',
                    width: 104,
                    height: 42,
                    fit: BoxFit.contain,
                    cacheWidth: decodePixels(context, 104),
                  ),
                  const Spacer(),
                  if (_page != _pages.length - 1)
                    TextButton(
                      onPressed: _finishing ? null : _finish,
                      child: const Text('건너뛰기'),
                    )
                  else
                    const SizedBox(width: 80),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (value) => setState(() => _page = value),
                itemBuilder: (context, index) {
                  final data = _pages[index];
                  return _OnboardingPage(
                    eyebrow: data.eyebrow,
                    title: data.title,
                    body: data.body,
                    visual: data.type,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (_page > 0)
                        _CircleAction(
                          icon: Icons.arrow_back_rounded,
                          onPressed: () => _pageController.previousPage(
                            duration: const Duration(milliseconds: 360),
                            curve: Curves.easeOutCubic,
                          ),
                        )
                      else
                        const SizedBox(width: 52),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            _pages.length,
                            (index) => AnimatedContainer(
                              duration: const Duration(milliseconds: 260),
                              width: index == _page ? 22 : 7,
                              height: 7,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: index == _page
                                    ? AppColors.coral
                                    : AppColors.line,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_page == _pages.length - 1)
                        const SizedBox(width: 52)
                      else
                        _CircleAction(
                          icon: Icons.arrow_forward_rounded,
                          onPressed: _finishing ? null : _next,
                        ),
                    ],
                  ),
                  if (_page == _pages.length - 1) ...[
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _finishing ? null : _finish,
                        child: _finishing
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              )
                            : const Text('로그인하러 가기'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum _OnboardingVisual { mascot, edit, family, ready }

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.visual,
  });

  final String eyebrow;
  final String title;
  final String body;
  final _OnboardingVisual visual;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 12, 28, 4),
    child: Column(
      children: [
        StatusPill(label: eyebrow, color: AppColors.coralSoft),
        const SizedBox(height: 22),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            height: 1.28,
            fontSize: 29,
            color: const Color(0xFF5A432D),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          body,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(color: AppColors.muted, height: 1.6),
        ),
        const SizedBox(height: 14),
        Expanded(child: _Visual(type: visual)),
      ],
    ),
  );
}

class _Visual extends StatelessWidget {
  const _Visual({required this.type});
  final _OnboardingVisual type;

  @override
  Widget build(BuildContext context) {
    if (type == _OnboardingVisual.edit) {
      return Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 520,
            child: SoftCard(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      const _OnboardingFamilyPhoto(borderRadius: 18),
                      Container(
                        width: 54,
                        height: 54,
                        decoration: const BoxDecoration(
                          color: Color(0x9A3A2C22),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: List.generate(
                      5,
                      (index) => Expanded(
                        child: Container(
                          height: 38,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceWarm,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: AppColors.line),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Opacity(
                            opacity: index == 2 ? 1 : .72,
                            child: const _OnboardingFamilyPhoto(
                              borderRadius: 0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _EditTool(Icons.content_cut_rounded, '자르기'),
                      _EditTool(Icons.music_note_rounded, '음악'),
                      _EditTool(Icons.mood_rounded, '스티커'),
                      _EditTool(Icons.title_rounded, '텍스트'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (type == _OnboardingVisual.family) {
      return Center(
        child: Image.asset(
          'assets/images/family_network_cutout.png',
          width: 365,
          fit: BoxFit.contain,
          cacheWidth: decodePixels(context, 365),
        ),
      );
    }

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Positioned(
            left: 18,
            top: 50,
            child: Icon(
              Icons.favorite_rounded,
              color: AppColors.coral,
              size: 30,
            ),
          ),
          const Positioned(
            right: 22,
            top: 92,
            child: Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.yellow,
              size: 28,
            ),
          ),
          Image.asset(
            'assets/images/bbanggeut_mascot.png',
            width: type == _OnboardingVisual.ready ? 300 : 275,
            fit: BoxFit.contain,
            cacheWidth: decodePixels(context, 300),
          ),
        ],
      ),
    );
  }
}

class _OnboardingFamilyPhoto extends StatelessWidget {
  const _OnboardingFamilyPhoto({required this.borderRadius});

  final double borderRadius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(borderRadius),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: Image.asset(
        'assets/images/onboarding_family_photo.png',
        fit: BoxFit.cover,
      ),
    ),
  );
}

class _EditTool extends StatelessWidget {
  const _EditTool(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Icon(icon, color: AppColors.sageDark),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(fontSize: 11)),
    ],
  );
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 52,
    child: IconButton.filled(
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surfaceWarm,
        foregroundColor: AppColors.ink,
        disabledBackgroundColor: AppColors.line,
      ),
      icon: Icon(icon),
    ),
  );
}
