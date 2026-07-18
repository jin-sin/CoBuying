import 'package:flutter/material.dart';

import '../orders/couriers.dart';

/// 운송장 입력 다이얼로그.
/// 반환: null = 취소, ('', '') = 입력 없이 진행(건너뛰기), 그 외 = (택배사, 운송장 번호).
Future<(String, String)?> showTrackingDialog(
  BuildContext context, {
  String? initialCourier,
  String? initialNumber,
}) {
  return showDialog<(String, String)?>(
    context: context,
    builder: (context) => _TrackingDialog(
      initialCourier: initialCourier,
      initialNumber: initialNumber,
    ),
  );
}

class _TrackingDialog extends StatefulWidget {
  const _TrackingDialog({this.initialCourier, this.initialNumber});

  final String? initialCourier;
  final String? initialNumber;

  @override
  State<_TrackingDialog> createState() => _TrackingDialogState();
}

class _TrackingDialogState extends State<_TrackingDialog> {
  late String _courier = widget.initialCourier?.isNotEmpty == true
      ? widget.initialCourier!
      : courierNames.first;
  late final _number = TextEditingController(text: widget.initialNumber ?? '');

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _save() {
    final number = _number.text.trim();
    if (number.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('운송장 번호를 입력해 주세요.')));
      return;
    }
    Navigator.pop(context, (_courier, number));
  }

  @override
  Widget build(BuildContext context) {
    // 목록에 없는 값(과거 입력 등)이 오면 드롭다운이 깨지지 않게 '기타'로 취급
    final courierValue =
        courierNames.contains(_courier) ? _courier : courierNames.last;
    return AlertDialog(
      title: const Text('운송장 입력'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: courierValue,
              decoration: const InputDecoration(
                labelText: '택배사',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in courierNames)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) => setState(() => _courier = v ?? _courier),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _number,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: '운송장 번호',
                hintText: '숫자만 입력 (- 없이)',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, ('', '')),
          child: const Text('입력 없이 진행'),
        ),
        FilledButton(onPressed: _save, child: const Text('저장')),
      ],
    );
  }
}
