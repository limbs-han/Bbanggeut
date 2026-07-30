import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'widgets.dart';

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController displayName;
  String? errorText;

  @override
  void initState() {
    super.initState();
    displayName = TextEditingController(
      text: widget.controller.user?.displayName ?? '',
    );
  }

  @override
  void dispose() {
    displayName.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (widget.controller.busy) return;
    final value = displayName.text.trim();
    if (value.isEmpty) {
      setState(() => errorText = '가족에게 보일 이름을 입력해 주세요.');
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
      showAppSnack(context, '프로필을 수정했어요.');
      Navigator.pop(context, true);
    } else {
      setState(
        () => errorText = widget.controller.errorMessage ?? '프로필을 수정하지 못했어요.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('프로필 수정')),
    body: AppBackdrop(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        children: [
          const CircleAvatar(
            radius: 38,
            backgroundColor: AppColors.sageSoft,
            child: Icon(
              Icons.person_outline_rounded,
              size: 36,
              color: AppColors.sageDark,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            key: const Key('profile-display-name'),
            controller: displayName,
            maxLength: 80,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: '이름',
              hintText: '가족에게 보일 이름',
              errorText: errorText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.controller.user?.email ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: widget.controller.busy ? null : _save,
            child: widget.controller.busy
                ? const SizedBox.square(
                    dimension: 21,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Text('수정 완료'),
          ),
        ],
      ),
    ),
  );
}
