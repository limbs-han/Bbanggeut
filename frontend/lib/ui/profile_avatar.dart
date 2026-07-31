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

  static Future<ProfileAvatarSelection> load() async {
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
    if (selection != null) return _image(selection!);
    return FutureBuilder<ProfileAvatarSelection>(
      future: ProfileAvatarStore.load(),
      builder: (context, snapshot) => _image(
        snapshot.data ??
            const ProfileAvatarSelection.asset(
              'assets/images/profile_avatar_hello.png',
            ),
      ),
    );
  }

  Widget _image(ProfileAvatarSelection selected) => Container(
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
              errorBuilder: (_, _, _) => _fallback(),
            )
          : Image.asset(
              selected.value,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
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
