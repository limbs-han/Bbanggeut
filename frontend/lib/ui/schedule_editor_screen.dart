import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app/app_theme.dart';
import '../core/api_client.dart';
import 'content_state.dart';
import 'schedule_emoji.dart';
import 'widgets.dart';

class ScheduleEditorScreen extends StatefulWidget {
  const ScheduleEditorScreen({
    super.key,
    this.initialDate,
    this.schedule,
    this.state,
  });

  final DateTime? initialDate;
  final CalendarSchedule? schedule;
  final ContentState? state;

  bool get isEditing => schedule != null;

  @override
  State<ScheduleEditorScreen> createState() => _ScheduleEditorScreenState();
}

class _ScheduleEditorScreenState extends State<ScheduleEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _memo;
  late final TextEditingController _date;
  late bool _yearly;
  late String _emoji;
  bool _saving = false;

  ContentState get _state => widget.state ?? ContentState.instance;

  @override
  void initState() {
    super.initState();
    final schedule = widget.schedule;
    _title = TextEditingController(text: schedule?.title ?? '');
    _memo = TextEditingController(text: schedule?.memo ?? '');
    _date = TextEditingController(
      text: DateFormat(
        'yyyy-MM-dd',
      ).format(schedule?.date ?? widget.initialDate ?? DateTime.now()),
    );
    _yearly = schedule?.yearly ?? false;
    _emoji = schedule?.emoji ?? calendarScheduleEmojis.first;
  }

  @override
  void dispose() {
    _title.dispose();
    _memo.dispose();
    _date.dispose();
    super.dispose();
  }

  DateTime? _parseDate(String value) {
    try {
      final parsed = DateFormat('yyyy-MM-dd').parseStrict(value);
      return parsed.year >= 1900 && parsed.year <= 2100 ? parsed : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate:
          _parseDate(_date.text) ?? widget.initialDate ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    _date.text = DateFormat('yyyy-MM-dd').format(picked);
    _formKey.currentState?.validate();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final schedule = CalendarSchedule(
      // 새 일정의 id는 서버가 발급한다. 서버 미연결 폴백에서만 임시 id를 쓴다.
      id:
          widget.schedule?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      title: _title.text.trim(),
      memo: _memo.text.trim(),
      date: _parseDate(_date.text)!,
      yearly: _yearly,
      emoji: _emoji,
    );
    try {
      final saved = await _state.saveSchedule(
        schedule,
        isNew: !widget.isEditing,
      );
      if (mounted) Navigator.pop(context, saved);
    } on ApiFailure catch (failure) {
      if (mounted) {
        setState(() => _saving = false);
        showAppSnack(context, '$failure', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFFFFAF4),
    body: AppBackdrop(
      child: SafeArea(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              _EditorHeader(
                editing: widget.isEditing,
                saving: _saving,
                onSave: _save,
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 30),
                  children: [
                    _FieldLabel('일정 이름'),
                    const SizedBox(height: 8),
                    TextFormField(
                      key: const Key('schedule-title-field'),
                      controller: _title,
                      autofocus: !widget.isEditing,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        hintText: '일정 이름을 입력하세요',
                        suffixIcon: Padding(
                          padding: const EdgeInsets.all(10),
                          child: ScheduleEmojiIcon(
                            key: const Key('schedule-selected-emoji'),
                            emoji: _emoji,
                            size: 34,
                          ),
                        ),
                      ),
                      validator: (value) => value?.trim().isEmpty == true
                          ? '일정 이름을 입력해 주세요'
                          : null,
                    ),
                    const SizedBox(height: 22),
                    _FieldLabel('날짜'),
                    const SizedBox(height: 8),
                    TextFormField(
                      key: const Key('schedule-date-field'),
                      controller: _date,
                      keyboardType: TextInputType.datetime,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                        LengthLimitingTextInputFormatter(10),
                      ],
                      decoration: InputDecoration(
                        hintText: 'YYYY-MM-DD',
                        suffixIcon: IconButton(
                          tooltip: '달력에서 선택',
                          onPressed: _pickDate,
                          icon: const Icon(
                            Icons.calendar_month_outlined,
                            color: Color(0xFF735542),
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return '날짜를 입력해 주세요';
                        }
                        return _parseDate(value.trim()) == null
                            ? 'YYYY-MM-DD 형식의 날짜를 입력해 주세요'
                            : null;
                      },
                    ),
                    const SizedBox(height: 22),
                    _FieldLabel('내용'),
                    const SizedBox(height: 8),
                    TextFormField(
                      key: const Key('schedule-memo-field'),
                      controller: _memo,
                      minLines: 5,
                      maxLines: 7,
                      maxLength: 500,
                      decoration: const InputDecoration(
                        hintText: '일정 내용을 입력하세요',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const _FieldLabel('이모지 선택'),
                    const SizedBox(height: 3),
                    const Text(
                      '선택한 이모지가 달력에 표시돼요',
                      style: TextStyle(color: Color(0xFF8F7C6D), fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    _EmojiPicker(
                      selected: _emoji,
                      onSelected: (emoji) => setState(() => _emoji = emoji),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      child: Row(
                        children: [
                          const Expanded(child: _FieldLabel('매년 반복')),
                          Switch(
                            key: const Key('schedule-yearly-switch'),
                            value: _yearly,
                            activeTrackColor: AppColors.coral,
                            onChanged: (value) =>
                                setState(() => _yearly = value),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('schedule-submit-button'),
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.coral,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(60),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      child: _saving
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(widget.isEditing ? '일정 저장' : '일정 추가'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.editing,
    required this.saving,
    required this.onSave,
  });

  final bool editing;
  final bool saving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
    child: SizedBox(
      height: 62,
      child: Row(
        children: [
          RoundIconButton(
            icon: Icons.chevron_left_rounded,
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              editing ? '🌱 일정 수정' : '🌱 새 일정 추가',
              style: const TextStyle(
                color: Color(0xFF5C4131),
                fontSize: 27,
                fontWeight: FontWeight.w900,
                letterSpacing: -1,
              ),
            ),
          ),
          TextButton(
            onPressed: saving ? null : onSave,
            child: Text(
              '저장',
              style: TextStyle(
                color: saving ? AppColors.muted : AppColors.coral,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Text(
    '$label  🌱',
    style: const TextStyle(
      color: Color(0xFF5D4535),
      fontSize: 16,
      fontWeight: FontWeight.w900,
    ),
  );
}

class _EmojiPicker extends StatelessWidget {
  const _EmojiPicker({required this.selected, required this.onSelected});

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final emoji in calendarScheduleEmojis)
        Semantics(
          selected: emoji == selected,
          button: true,
          label: '$emoji 이모지',
          child: InkWell(
            key: ValueKey('schedule-emoji-$emoji'),
            onTap: () => onSelected(emoji),
            borderRadius: BorderRadius.circular(18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 62,
              height: 62,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFFFFDF9),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: emoji == selected
                      ? AppColors.coral
                      : const Color(0xFFF0D9C6),
                  width: emoji == selected ? 2 : 1,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14705A43),
                    blurRadius: 8,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: ScheduleEmojiIcon(emoji: emoji, size: 48),
            ),
          ),
        ),
    ],
  );
}
