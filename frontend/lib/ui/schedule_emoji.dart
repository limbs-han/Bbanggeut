import 'package:flutter/material.dart';

const calendarScheduleEmojiAssets = <String, String>{
  '❤️': 'assets/images/calendar_emojis/heart.png',
  '🎂': 'assets/images/calendar_emojis/cake.png',
  '🍚': 'assets/images/calendar_emojis/rice.png',
  '☎️': 'assets/images/calendar_emojis/phone.png',
  '📷': 'assets/images/calendar_emojis/camera.png',
  '⭐': 'assets/images/calendar_emojis/star.png',
  '🎁': 'assets/images/calendar_emojis/gift.png',
  '🌸': 'assets/images/calendar_emojis/flower.png',
  '🎉': 'assets/images/calendar_emojis/party.png',
  '✈️': 'assets/images/calendar_emojis/airplane.png',
  '🏠': 'assets/images/calendar_emojis/house.png',
  '🐾': 'assets/images/calendar_emojis/paw.png',
};

class ScheduleEmojiIcon extends StatelessWidget {
  const ScheduleEmojiIcon({super.key, required this.emoji, this.size = 32});

  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final assetPath = calendarScheduleEmojiAssets[emoji];
    if (assetPath == null) return _FallbackEmoji(emoji: emoji, size: size);

    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    return Image.asset(
      assetPath,
      key: ValueKey('schedule-emoji-image-$emoji'),
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      cacheWidth: (size * pixelRatio).round(),
      excludeFromSemantics: true,
      errorBuilder: (context, error, stackTrace) =>
          _FallbackEmoji(emoji: emoji, size: size),
    );
  }
}

class _FallbackEmoji extends StatelessWidget {
  const _FallbackEmoji({required this.emoji, required this.size});

  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Text(emoji, style: TextStyle(fontSize: size * 0.8, height: 1));
}
