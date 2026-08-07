/// 알림 종류마다 눈에 보이는 구분을 한곳에 모은다.
///
/// **왜 한곳인가**: 예전에는 같은 매핑이 두 벌 있었다. 알림함
/// (`content_notifications_screen.dart`)은 여섯 종을 알고, 포그라운드 배너
/// (`app.dart`)는 네 종만 알았다. 그래서 같은 알림이 배너에서는 🔔, 알림함에서는
/// 🎨로 보였고, 기념일·주간 리포트는 양쪽 모두 기본값으로 떨어져 초대와 구분이
/// 되지 않았다. 종류가 늘 때 한 벌만 고치면 다른 한 벌이 조용히 뒤처진다.
///
/// 그 앱 내부 배너는 지금 없다 — 앱을 켜 둔 동안에도 휴대폰 알림 표시줄에
/// 뜨도록 바뀌었고, 그 알림의 모양은 OS가 정한다. 그래서 오늘 이 매핑을 읽는
/// 곳은 알림함뿐이지만, 한곳에 모아 두는 이유는 그대로다.
///
/// 구분은 세 겹이다 — 이모지, 배경색, 그리고 **카테고리 라벨**. 이모지만으로는
/// 알림이 쌓였을 때 훑어 읽기 어렵고, 라벨이 있으면 제목을 읽지 않아도 무슨
/// 갈래인지 먼저 들어온다.
library;

import 'package:flutter/material.dart';

import '../app/app_theme.dart';

class NotificationVisual {
  const NotificationVisual({
    required this.emoji,
    required this.background,
    required this.accent,
    required this.category,
  });

  final String emoji;

  /// 이모지 뒤 타일 색.
  final Color background;

  /// 카테고리 라벨 글자색. 배경 위에서 읽히는 진한 쪽을 쓴다.
  final Color accent;

  /// 목록의 칩과 배너 눈썹에 들어가는 짧은 갈래 이름.
  final String category;
}

/// 초대·가족 갈래는 분홍, 추억(영상) 갈래는 세이지, 만드는 것(편집·만화)은
/// 노랑, 주기 소식(기념일·리포트)은 산호로 묶었다. 색 묶음이 갈래를 먼저
/// 말해 주고, 이모지가 그 안에서 갈라 준다.
const _visuals = <String, NotificationVisual>{
  'INVITATION_RECEIVED': NotificationVisual(
    emoji: '💌',
    background: AppColors.pinkSoft,
    accent: AppColors.coralDark,
    category: '초대',
  ),
  'INVITATION_ACCEPTED': NotificationVisual(
    emoji: '🤝',
    background: AppColors.pink,
    accent: AppColors.coralDark,
    category: '가족',
  ),
  // 기기가 스스로 감지해 담은 영상 도착. 웃음 전용이 아니다 — 박수·호출·직접
  // 촬영도 이 타입으로 오고, 무엇이었는지는 제목이 말해 준다.
  'LAUGHTER_VIDEO_READY': NotificationVisual(
    emoji: '📹',
    background: AppColors.sageSoft,
    accent: AppColors.sageDark,
    category: '새 추억',
  ),
  'EDIT_ANALYSIS_READY': NotificationVisual(
    emoji: '✨',
    background: AppColors.greenCard,
    accent: AppColors.sageDark,
    category: 'AI 분석',
  ),
  'EDIT_COMMENT_ADDED': NotificationVisual(
    emoji: '💬',
    background: AppColors.surfaceWarm,
    accent: AppColors.inkSoft,
    category: '댓글',
  ),
  'COMIC_SCRIPT_READY': NotificationVisual(
    emoji: '📝',
    background: AppColors.yellowSoft,
    accent: AppColors.ink,
    category: '만화 대사',
  ),
  'COMIC_READY': NotificationVisual(
    emoji: '🎨',
    background: AppColors.yellow,
    accent: AppColors.ink,
    category: '만화 완성',
  ),
  'ANNIVERSARY': NotificationVisual(
    emoji: '🎂',
    background: AppColors.coralSoft,
    accent: AppColors.coralDark,
    category: '기념일',
  ),
  'WEEKLY_REPORT': NotificationVisual(
    emoji: '📊',
    background: AppColors.cream,
    accent: AppColors.muted,
    category: '주간 리포트',
  ),
};

const _fallback = NotificationVisual(
  emoji: '🔔',
  background: AppColors.surfaceWarm,
  accent: AppColors.muted,
  category: '알림',
);

/// 모르는 타입은 기본값으로 떨어진다 — 서버가 새 종류를 먼저 보내도 앱이
/// 빈칸을 그리지 않아야 한다.
NotificationVisual notificationVisualFor(String type) =>
    _visuals[type] ?? _fallback;

/// 시각이 정의된 알림 종류. 목적지도 함께 있는지 테스트가 대조한다 — 종류가
/// 늘 때 이모지만 더하고 갈 곳을 빠뜨리면 사용자는 눌렀는데 아무 일도 일어나지
/// 않는 것을 본다.
Iterable<String> get knownNotificationTypes => _visuals.keys;
