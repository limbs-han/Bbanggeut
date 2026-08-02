import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'all_memories_screen.dart';

class VideosScreen extends StatelessWidget {
  const VideosScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) =>
      AllMemoriesScreen(controller: controller);
}
