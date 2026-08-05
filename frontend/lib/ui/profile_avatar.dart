import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app/app_theme.dart';

const profileAvatarAssets = <String>[
  'assets/images/profile_avatar_teddy.png',
  'assets/images/profile_avatar_swim.png',
  'assets/images/profile_avatar_laptop.png',
  'assets/images/profile_avatar_coffee.png',
  'assets/images/profile_avatar_home.png',
  'assets/images/profile_avatar_hello.png',
  'assets/images/profile_avatar_music.png',
  'assets/images/profile_avatar_notebook.png',
  'assets/images/profile_avatar_cookie.png',
];

class ProfileAvatarSelection {
  const ProfileAvatarSelection.asset(this.value) : isFile = false;
  const ProfileAvatarSelection.file(this.value) : isFile = true;

  final String value;
  final bool isFile;
}

class ProfileAvatarStore {
  ProfileAvatarStore._();

  static const _storage = FlutterSecureStorage();
  static const _kindKey = 'wj_profile_avatar_kind';
  static const _valueKey = 'wj_profile_avatar_value';

  static const fallback = ProfileAvatarSelection.asset(
    'assets/images/profile_avatar_hello.png',
  );

  /// 지금 쓰는 아바타. [ProfileAvatarView]가 이 값을 듣는다.
  ///
  /// **왜 Future가 아니라 notifier인가**: 아바타는 홈·설정·가족 화면에 동시에
  /// 뜨고, 그중 몇은 `const ProfileAvatarView(radius: 24)`처럼 const로 박혀
  /// 있다. const 위젯은 부모가 `setState`를 불러도 Flutter가 같은 인스턴스를
  /// 알아보고 서브트리 리빌드를 건너뛴다 — `build` 안에서 저장소를 읽는 구조로는
  /// 새로 고른 그림이 그 자리에 영영 반영되지 않았다. 설정 화면이 프로필 수정에서
  /// 돌아올 때 `setState`를 부르고 있는데도 작은 아바타만 예전 그림으로 남던
  /// 이유다. notifier는 위젯 동일성과 무관하게 듣는 쪽을 다시 그린다.
  static final ValueNotifier<ProfileAvatarSelection> current =
      ValueNotifier<ProfileAvatarSelection>(fallback);

  static Future<ProfileAvatarSelection>? _loaded;

  /// 한 번 읽은 값을 들고 있는다.
  ///
  /// **왜**: 안드로이드 보안 저장소는 읽을 때마다 키스토어를 거친다. 화면이
  /// 다시 그려질 때마다 읽으면 아무 것도 바뀌지 않았는데 채널 왕복만 쌓인다.
  ///
  /// 값이 바뀌는 길은 [save] 하나뿐이라, 그쪽에서 갈아 끼우면 어긋날 일이 없다.
  static Future<ProfileAvatarSelection> load() => _loaded ??= _read();

  static Future<ProfileAvatarSelection> _read() async {
    final selection = await _readStored();
    current.value = selection;
    return selection;
  }

  static Future<ProfileAvatarSelection> _readStored() async {
    try {
      final values = await Future.wait([
        _storage.read(key: _kindKey),
        _storage.read(key: _valueKey),
      ]);
      final value = values[1];
      if (values[0] == 'file' && value != null && await File(value).exists()) {
        return ProfileAvatarSelection.file(value);
      }
      if (value != null && profileAvatarAssets.contains(value)) {
        return ProfileAvatarSelection.asset(value);
      }
    } catch (_) {}
    return fallback;
  }

  static Future<void> save(ProfileAvatarSelection selection) async {
    _loaded = Future.value(selection);
    current.value = selection;
    await Future.wait([
      _storage.write(key: _kindKey, value: selection.isFile ? 'file' : 'asset'),
      _storage.write(key: _valueKey, value: selection.value),
    ]);
  }
}

/// 갤러리에서 고른 사진을 앱 문서 폴더에 저장할 때 쓰는 파일 이름 접두사.
///
/// 사진마다 다른 이름을 붙인다. 같은 이름에 새 사진을 덮어쓰면 Flutter 이미지
/// 캐시가 파일 경로를 키로 잡고 있어 예전 사진을 계속 그린다 — 사진을 두 번
/// 바꾸면 두 번째가 반영되지 않았다.
///
/// 이 접두사는 이름 하나만 쓰던 시절의 `profile_avatar.jpg`에도 걸리므로,
/// 정리할 때 옛 파일까지 함께 지워진다.
const avatarFilePrefix = 'profile_avatar';

class ProfileAvatarView extends StatelessWidget {
  const ProfileAvatarView({super.key, required this.radius, this.selection});

  final double radius;
  final ProfileAvatarSelection? selection;

  @override
  Widget build(BuildContext context) {
    if (selection != null) return _image(context, selection!);
    // 첫 호출에서만 실제로 읽는다. 읽고 나면 notifier가 값을 들고 있으므로
    // 이 위젯이 다시 그려지든 말든 이후 변경은 notifier를 타고 들어온다.
    ProfileAvatarStore.load();
    return ValueListenableBuilder<ProfileAvatarSelection>(
      valueListenable: ProfileAvatarStore.current,
      builder: (context, selected, _) => _image(context, selected),
    );
  }

  /// 몇 픽셀로 풀어 둘지.
  ///
  /// **왜 정해 주는가**: 그림은 원래 크기대로 풀린 채 이미지 캐시에 남는다.
  /// 아바타로 고른 사진은 최대 1600×1600(profile_edit_screen)이라 한 장이 10MB쯤
  /// 잡아먹는데, 실제로 그리는 자리는 지름 몇십 dp다. 화면 밀도까지만 풀어 두면
  /// 눈에 보이는 차이 없이 그 몫이 수십 분의 일로 줄고, 푸는 시간도 같이 줄어든다.
  int _decodeSize(BuildContext context) =>
      (radius * 2 * MediaQuery.devicePixelRatioOf(context)).round();

  Widget _image(BuildContext context, ProfileAvatarSelection selected) =>
      Container(
        width: radius * 2,
        height: radius * 2,
        padding: EdgeInsets.all(radius * .08),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.sageSoft,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F6E7F45),
              blurRadius: 14,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: ClipOval(
          child: selected.isFile
              ? Image.file(
                  File(selected.value),
                  fit: BoxFit.cover,
                  cacheWidth: _decodeSize(context),
                  errorBuilder: (_, _, _) => _fallback(),
                )
              : Image.asset(
                  selected.value,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  cacheWidth: _decodeSize(context),
                  errorBuilder: (_, _, _) => _fallback(),
                ),
        ),
      );

  Widget _fallback() => const ColoredBox(
    color: AppColors.sageSoft,
    child: Icon(
      Icons.person_outline_rounded,
      color: AppColors.sageDark,
      size: 42,
    ),
  );
}
