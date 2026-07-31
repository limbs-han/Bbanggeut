import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app/app_theme.dart';
import 'widgets.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key, this.compact = false});

  final bool compact;

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  static const _storage = FlutterSecureStorage();
  static const _anniversaryKey = 'wj_pref_anniversary_alerts';
  static const _weeklyKey = 'wj_pref_weekly_report';
  static const _memoryKey = 'wj_pref_new_memory_alerts';

  bool anniversaryAlerts = true;
  bool weeklyReport = true;
  bool newMemoryAlerts = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait([
        _storage.read(key: _anniversaryKey),
        _storage.read(key: _weeklyKey),
        _storage.read(key: _memoryKey),
      ]);
      if (!mounted) return;
      setState(() {
        anniversaryAlerts = values[0] != 'false';
        weeklyReport = values[1] != 'false';
        newMemoryAlerts = values[2] == 'true';
      });
    } catch (_) {
      // 보안 저장소를 사용할 수 없는 환경에서는 현재 실행의 상태를 유지한다.
    }
  }

  Future<void> _save(String key, bool value) async {
    try {
      await _storage.write(key: key, value: '$value');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final switches = _switches();
    if (widget.compact) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFFBF4), Color(0xFFFFF6E8)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.notifications_none_rounded,
              size: 52,
              color: AppColors.sageDark,
            ),
            const SizedBox(height: 6),
            const Text(
              '알림 설정',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w900,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              '원하는 알림만 골라서 받아보세요',
              style: TextStyle(color: AppColors.inkSoft, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .72),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.line),
              ),
              child: switches,
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.sageDark,
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text(
                '닫기',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: AppBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 68,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    RoundIconButton(
                      icon: Icons.chevron_left_rounded,
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '알림 설정',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    const Text('🌱', style: TextStyle(fontSize: 24)),
                    const SizedBox(width: 20),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
                  children: [
                    const SoftCard(
                      color: AppColors.pink,
                      borderColor: AppColors.pink,
                      child: Row(
                        children: [
                          Text('🔔', style: TextStyle(fontSize: 30)),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '필요한 알림만 부드럽고 편안하게 전해드릴게요.',
                              style: TextStyle(
                                color: AppColors.inkSoft,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SoftCard(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: switches,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _switches() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _SwitchRow(
        icon: Icons.event_available_rounded,
        iconColor: AppColors.coral,
        title: '기념일 알림',
        subtitle: '등록한 기념일을 알려드려요',
        value: anniversaryAlerts,
        onChanged: (value) {
          setState(() => anniversaryAlerts = value);
          _save(_anniversaryKey, value);
        },
      ),
      const Divider(height: 1, indent: 18, endIndent: 18),
      _SwitchRow(
        icon: Icons.summarize_outlined,
        iconColor: AppColors.sageDark,
        title: '주간 리포트 알림',
        subtitle: '이번 주 웃음 기록을 요약해요',
        value: weeklyReport,
        onChanged: (value) {
          setState(() => weeklyReport = value);
          _save(_weeklyKey, value);
        },
      ),
      const Divider(height: 1, indent: 18, endIndent: 18),
      _SwitchRow(
        icon: Icons.video_library_outlined,
        iconColor: AppColors.coralDark,
        title: '새로운 추억 알림',
        subtitle: '새 영상 저장 시 알려드려요',
        value: newMemoryAlerts,
        onChanged: (value) {
          setState(() => newMemoryAlerts = value);
          _save(_memoryKey, value);
        },
      ),
    ],
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    minVerticalPadding: 9,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    leading: Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceWarm,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: iconColor, size: 24),
    ),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 10, color: AppColors.inkSoft),
    ),
    trailing: Switch(
      value: value,
      activeTrackColor: AppColors.sage,
      onChanged: onChanged,
    ),
    onTap: () => onChanged(!value),
  );
}
