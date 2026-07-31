import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'profile_avatar.dart';
import 'widgets.dart';

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController displayName;
  ProfileAvatarSelection? avatar;
  String? errorText;
  bool avatarBusy = false;

  @override
  void initState() {
    super.initState();
    displayName = TextEditingController(
      text: widget.controller.user?.displayName ?? '',
    )..addListener(_refresh);
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final selected = await ProfileAvatarStore.load();
    if (mounted) setState(() => avatar = selected);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    displayName
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.controller.busy || avatarBusy) return;
    final value = displayName.text.trim();
    if (value.length < 2) {
      setState(() => errorText = '이름은 2자 이상 입력해 주세요.');
      return;
    }
    if (value.length > 80) {
      setState(() => errorText = '이름은 80자 이하로 입력해 주세요.');
      return;
    }
    setState(() => errorText = null);
    final ok = await widget.controller.updateProfile(value);
    if (!mounted) return;
    if (ok) {
      if (avatar != null) await ProfileAvatarStore.save(avatar!);
      if (!mounted) return;
      showAppSnack(context, '프로필을 수정했어요.');
      Navigator.pop(context, true);
    } else {
      setState(
        () => errorText = widget.controller.errorMessage ?? '프로필을 수정하지 못했어요.',
      );
    }
  }

  Future<void> _chooseAvatarSource() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '프로필 사진 바꾸기',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 18),
              _SourceButton(
                icon: Icons.photo_library_outlined,
                title: '휴대폰 사진에서 선택',
                subtitle: '갤러리에 있는 사진을 프로필로 사용해요.',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickFromGallery();
                },
              ),
              const SizedBox(height: 10),
              _SourceButton(
                icon: Icons.face_retouching_natural_rounded,
                title: '기본 이미지 선택',
                subtitle: '빵긋 캐릭터 중 마음에 드는 이미지를 골라요.',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _chooseDefaultAvatar();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickFromGallery() async {
    setState(() => avatarBusy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (picked == null) return;
      final directory = await getApplicationDocumentsDirectory();
      final extension = picked.path.contains('.')
          ? picked.path.substring(picked.path.lastIndexOf('.'))
          : '.jpg';
      final destination =
          '${directory.path}${Platform.pathSeparator}profile_avatar$extension';
      await File(picked.path).copy(destination);
      if (mounted) {
        setState(() => avatar = ProfileAvatarSelection.file(destination));
      }
    } catch (_) {
      if (mounted) {
        showAppSnack(context, '사진을 불러오지 못했어요.', error: true);
      }
    } finally {
      if (mounted) setState(() => avatarBusy = false);
    }
  }

  Future<void> _chooseDefaultAvatar() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '기본 이미지 선택',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                const Text(
                  '나를 표현하는 빵긋 캐릭터를 골라 보세요.',
                  style: TextStyle(color: AppColors.inkSoft, fontSize: 12),
                ),
                const SizedBox(height: 18),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: profileAvatarAssets.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemBuilder: (context, index) {
                    final asset = profileAvatarAssets[index];
                    final selected =
                        avatar?.isFile == false && avatar?.value == asset;
                    return InkWell(
                      key: Key('profile-avatar-$index'),
                      borderRadius: BorderRadius.circular(22),
                      onTap: () => Navigator.pop(sheetContext, asset),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppColors.sageSoft
                              : AppColors.surfaceWarm,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: selected
                                ? AppColors.sageDark
                                : AppColors.line,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: Image.asset(asset, fit: BoxFit.contain),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => avatar = ProfileAvatarSelection.asset(selected));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
          children: [
            SizedBox(
              height: 82,
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  Positioned(
                    left: 0,
                    top: 4,
                    child: IconButton(
                      key: const Key('profile-edit-back'),
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded, size: 30),
                    ),
                  ),
                  const Column(
                    children: [
                      Text(
                        '프로필 수정',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '프로필 정보를 수정하고 저장해 주세요',
                        style: TextStyle(
                          color: AppColors.inkSoft,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 154,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  const Positioned(
                    left: 0,
                    bottom: 0,
                    width: 92,
                    height: 90,
                    child: Image(
                      image: AssetImage('assets/images/bbanggeut_mascot.png'),
                      fit: BoxFit.contain,
                    ),
                  ),
                  ProfileAvatarView(radius: 66, selection: avatar),
                  Align(
                    alignment: const Alignment(.43, .72),
                    child: Material(
                      color: Colors.white,
                      elevation: 4,
                      shape: const CircleBorder(),
                      child: IconButton(
                        key: const Key('profile-avatar-change'),
                        onPressed: avatarBusy ? null : _chooseAvatarSource,
                        icon: avatarBusy
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.camera_alt_outlined,
                                color: AppColors.ink,
                              ),
                      ),
                    ),
                  ),
                  const Positioned(
                    right: 30,
                    top: 28,
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      color: AppColors.yellowSoft,
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 34),
            SoftCard(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '이름',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('profile-display-name'),
                    controller: displayName,
                    maxLength: 80,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    decoration: InputDecoration(
                      hintText: '이름을 입력해 주세요',
                      errorText: errorText,
                      suffixIcon: displayName.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: displayName.clear,
                              icon: const Icon(Icons.cancel_rounded),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceWarm,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.eco_outlined,
                          color: AppColors.sage,
                          size: 20,
                        ),
                        SizedBox(width: 10),
                        Text(
                          '2~80자의 이름을 입력해 주세요.',
                          style: TextStyle(
                            color: AppColors.inkSoft,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            FilledButton(
              key: const Key('profile-save'),
              onPressed: widget.controller.busy || avatarBusy ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(60),
                backgroundColor: AppColors.coral,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
              child: widget.controller.busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      '수정 완료  ✦',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: AppColors.line),
    ),
    tileColor: AppColors.surfaceWarm,
    leading: CircleAvatar(
      backgroundColor: AppColors.sageSoft,
      child: Icon(icon, color: AppColors.sageDark),
    ),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    trailing: const Icon(Icons.chevron_right_rounded),
  );
}
