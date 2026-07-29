import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'content_state.dart';
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
  bool _saving = false;

  ContentState get _state => widget.state ?? ContentState.instance;

  @override
  void initState() {
    super.initState();
    final schedule = widget.schedule;
    _title = TextEditingController(text: schedule?.title ?? '');
    _memo = TextEditingController(text: schedule?.memo ?? '');
    _date = TextEditingController(
      text: schedule != null
          ? DateFormat('yyyy-MM-dd').format(schedule.date)
          : widget.initialDate == null
          ? ''
          : DateFormat('yyyy-MM-dd').format(widget.initialDate!),
    );
    _yearly = schedule?.yearly ?? false;
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
    final parsed = _parseDate(_date.text);
    final picked = await showDatePicker(
      context: context,
      initialDate: parsed ?? widget.initialDate ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      _date.text = DateFormat('yyyy-MM-dd').format(picked);
      _formKey.currentState?.validate();
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final parsed = _parseDate(_date.text)!;
    final schedule = CalendarSchedule(
      id:
          widget.schedule?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      title: _title.text.trim(),
      memo: _memo.text.trim(),
      date: parsed,
      yearly: _yearly,
    );
    // TODO(content-api): 일정 생성/수정 API 성공 후 저장소를 갱신합니다.
    _state.saveSchedule(schedule);
    if (mounted) Navigator.pop(context, schedule);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: SafeArea(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              SizedBox(
                height: 72,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    RoundIconButton(
                      icon: Icons.chevron_left_rounded,
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.isEditing ? '일정 수정' : '새 일정 추가',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '저장 중' : '저장'),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                  children: [
                    const Text(
                      '일정 이름',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _title,
                      autofocus: !widget.isEditing,
                      decoration: const InputDecoration(
                        hintText: '일정 이름을 입력하세요',
                      ),
                      validator: (value) => value?.trim().isEmpty == true
                          ? '일정 이름을 입력해 주세요.'
                          : null,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '날짜',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
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
                          icon: const Icon(Icons.calendar_month_outlined),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return '날짜를 입력해 주세요.';
                        }
                        if (_parseDate(value.trim()) == null) {
                          return 'YYYY-MM-DD 형식의 올바른 날짜를 입력해 주세요.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '내용',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _memo,
                      minLines: 4,
                      maxLines: 7,
                      maxLength: 500,
                      decoration: const InputDecoration(
                        hintText: '일정 내용을 입력하세요',
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('매년 반복'),
                      value: _yearly,
                      onChanged: (value) => setState(() => _yearly = value),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(widget.isEditing ? '변경 내용 저장' : '일정 추가'),
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
