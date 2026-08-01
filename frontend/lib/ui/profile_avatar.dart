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

  static Future<ProfileAvatarSelection>? _loaded;

  /// 한 번 읽은 값을 들고 있는다.
  ///
  /// **왜**: [ProfileAvatarView]가 이걸 `build` 안의 FutureBuilder로 읽는다.
  /// 그래서 화면이 다시 그려질 때마다 보안 저장소를 두 번 읽고 파일 존재까지
  /// 확인했다. 안드로이드 보안 저장소는 읽을 때마다 키스토어를 거치는데, 아바타는
  /// 홈·설정·가족 화면에 여러 개가 동시에 뜨고 그 화면들은 컨트롤러가 알릴 때마다
  /// 다시 그려진다 — 아무 것도 바뀌지 않았는데 채널 왕복만 쌓였다.
  ///
  /// 값이 바뀌는 길은 [save] 하나뿐이라, 그쪽에서 갈아 끼우면 어긋날 일이 없다.
  static Future<ProfileAvatarSelection> load() => _loaded ??= _read();

  static Future<ProfileAvatarSelection> _read() async {
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
    return const ProfileAvatarSelection.asset(
      'assets/images/profile_avatar_hello.png',
    );
  }

  static Future<void> save(ProfileAvatarSelection selection) async {
    _loaded = Future.value(selection);
    await Future.wait([
      _storage.write(key: _kindKey, value: selection.isFile ? 'file' : 'asset'),
      _storage.write(key: _valueKey, value: selection.value),
    ]);
  }
}

class ProfileAvatarView extends StatelessWidget {
  const ProfileAvatarView({super.key, required this.radius, this.selection});

  final double radius;
  final ProfileAvatarSelection? selection;

  @override
  Widget build(BuildContext context) {
    if (selection != null) return _image(context, selection!);
    return FutureBuilder<ProfileAvatarSelection>(
      future: ProfileAvatarStore.load(),
      builder: (context, snapshot) => _image(
        context,
        snapshot.data ??
            const ProfileAvatarSelection.asset(
              'assets/images/profile_avatar_hello.png',
            ),
      ),
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
