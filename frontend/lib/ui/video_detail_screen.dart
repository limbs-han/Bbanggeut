import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/models.dart';
import 'content_video_detail_screen.dart';

class VideoDetailScreen extends StatelessWidget {
  const VideoDetailScreen({
    super.key,
    required this.controller,
    required this.video,
  });

  final AppController controller;
  final VideoMemory video;

  @override
  Widget build(BuildContext context) =>
      ContentVideoDetailScreen(controller: controller, video: video);
}
