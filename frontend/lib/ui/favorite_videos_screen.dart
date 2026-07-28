import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'memory_video_card.dart';
import 'widgets.dart';

class FavoriteVideosScreen extends StatefulWidget {
  const FavoriteVideosScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<FavoriteVideosScreen> createState() => _FavoriteVideosScreenState();
}

class _FavoriteVideosScreenState extends State<FavoriteVideosScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final videos =
        widget.controller.videos.where((video) => video.favorite).toList()
          ..sort((a, b) {
            final left = a.capturedStartAt ?? a.createdAt ?? DateTime(1970);
            final right = b.capturedStartAt ?? b.createdAt ?? DateTime(1970);
            return right.compareTo(left);
          });
    return Scaffold(
      body: AppBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 72,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    RoundIconButton(
                      icon: Icons.chevron_left_rounded,
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '즐겨찾는 영상',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: videos.isEmpty
                    ? const EmptyState(
                        icon: Icons.favorite_border_rounded,
                        title: '즐겨찾는 영상이 없어요',
                        message: '영상 카드의 하트를 눌러 소중한 추억을 모아보세요.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                        itemCount: videos.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (_, index) => MemoryVideoCard(
                          controller: widget.controller,
                          video: videos[index],
                          onChanged: _refresh,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
