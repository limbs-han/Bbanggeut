/// 알림 종류가 어느 화면을 가리키는가 — 화면을 만들지 않고 **결정만** 한다.
///
/// **왜 순수 함수로 떼어 놨나**: 이 결정이 두 벌 있었고(알림함과 푸시 처리),
/// 한쪽에만 종류를 더하다가 갈라졌다. `AI 분석이 끝났어요`를 알림함에서 누르면
/// 영상 상세가 열리는데 푸시로 누르면 알림함만 열렸다 — 목적지가 코드 두 곳에
/// 흩어져 있으면 그 어긋남을 테스트로 잡을 수가 없다. 결정을 여기 한 함수로
/// 모아 두면 종류가 늘 때 표 하나만 고치면 되고, 빠뜨리면 테스트가 잡는다.
library;

enum NotificationDestination {
  /// 원본 영상 상세. 새 추억 도착과 AI 분석 완료가 여기로 온다 — 상세에서
  /// 편집하기를 누르면 이미 분석돼 있어 AI 컷이 바로 열린다.
  videoDetail,

  /// 4컷 만화 화면. 대사 준비와 그림 완성 모두 여기다 — 만화 화면이 저장된
  /// 구성을 읽어 대사 편집으로 이어 준다.
  comic,

  /// 편집본 화면. 편집본에 달린 댓글은 원본 상세로 보내면 어디 달렸는지
  /// 찾을 수 없다.
  editedVideo,

  /// 캘린더(기념일).
  calendar,

  /// 웃음 리포트(주간 리포트).
  laughReport,

  /// 받은 초대함.
  invitations,

  /// 가족 화면. 내가 보낸 초대를 누군가 수락했다는 소식이 여기로 온다 —
  /// 예전에는 갈 곳이 없어 기본 경로로 떨어졌고, 그 기본 경로가 **기기 등록
  /// 화면**이라 "가족이 됐어요"를 누르면 카메라를 등록하라는 화면이 열렸다.
  family,

  /// 갈 곳을 특정할 수 없다 — 부르는 쪽이 알림함이나 기기 목록으로 보낸다.
  fallback,
}

/// [type]과 대상 리소스 유무로 목적지를 정한다.
///
/// [hasResource]가 false면 영상·만화·편집본으로 갈 수 없다. 그런 알림은
/// 리소스 id 없이는 열 화면이 없으므로 [NotificationDestination.fallback]이다 —
/// 예전 알림이나 서버가 새로 만든 종류가 id 없이 와도 앱이 빈 화면을 열지
/// 않아야 한다.
NotificationDestination notificationDestinationFor(
  String type, {
  required bool hasResource,
}) => switch (type) {
  'EDIT_COMMENT_ADDED' when hasResource => NotificationDestination.editedVideo,
  'COMIC_SCRIPT_READY' || 'COMIC_READY' when hasResource =>
    NotificationDestination.comic,
  'LAUGHTER_VIDEO_READY' || 'EDIT_ANALYSIS_READY' when hasResource =>
    NotificationDestination.videoDetail,
  'ANNIVERSARY' => NotificationDestination.calendar,
  'WEEKLY_REPORT' => NotificationDestination.laughReport,
  'INVITATION_RECEIVED' => NotificationDestination.invitations,
  'INVITATION_ACCEPTED' => NotificationDestination.family,
  _ => NotificationDestination.fallback,
};
