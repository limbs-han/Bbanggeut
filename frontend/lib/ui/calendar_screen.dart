import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'content_calendar_screen.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key, required this.controller, this.onBack});

  final AppController controller;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) =>
      ContentCalendarScreen(controller: controller, onBack: onBack);
}
