import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'broadcast_customer_api.dart';

class BroadcastPaymentCard extends StatefulWidget {
  const BroadcastPaymentCard({
    super.key,
    required this.invoice,
    required this.api,
    required this.newKey,
    required this.onSubmitted,
    this.supplementReceipt,
  });
  final Map invoice;
  final BroadcastCustomerApi api;
  final String Function() newKey;
  final VoidCallback onSubmitted;
  final Map? supplementReceipt;
  @override
  State<BroadcastPaymentCard> createState() => _BroadcastPaymentCardState();
}

class _BroadcastPaymentCardState extends State<BroadcastPaymentCard> {
  final payer = TextEditingController();
  final amount = TextEditingController();
  String currency = 'KRW';
  Uint8List? bytes;
  String? contentType, uploadKey, evidenceId, error;
  bool busy = false;
  List<Map> get receivers =>
      (((widget.invoice['snapshot'] as Map?)?['receiver_snapshots'] as List?) ??
              [])
          .cast<Map>();
  bool hasReceiver(String code) => receivers.any((r) => r['currency'] == code);
  @override
  void initState() {
    super.initState();
    currency = hasReceiver('KRW')
        ? 'KRW'
        : hasReceiver('CNY')
        ? 'CNY'
        : 'KRW';
    amount.text = currency == 'KRW'
        ? '${widget.invoice['total_krw']}'
        : '${widget.invoice['total_cny_fen']}';
  }

  @override
  void dispose() {
    payer.dispose();
    amount.dispose();
    super.dispose();
  }

  String? _sniff(Uint8List data) {
    if (data.length >= 8 &&
        data[0] == 137 &&
        data[1] == 80 &&
        data[2] == 78 &&
        data[3] == 71) {
      return 'image/png';
    }
    if (data.length >= 3 &&
        data[0] == 255 &&
        data[1] == 216 &&
        data[2] == 255) {
      return 'image/jpeg';
    }
    if (data.length >= 12 &&
        String.fromCharCodes(data.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(data.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
    return null;
  }

  Future<void> _pick() async {
    try {
      final image = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (image == null) return;
      final data = await image.readAsBytes();
      final type = _sniff(data);
      if (!mounted) return;
      if (data.isEmpty || data.length > 5242880 || type == null) {
        setState(() => error = '5MB 이하 JPG, PNG, WebP 캡처를 선택해주세요.');
        return;
      }
      setState(() {
        bytes = data;
        contentType = type;
        uploadKey = widget.newKey();
        evidenceId = null;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '파일을 열지 못했습니다: $e');
    }
  }

  Future<void> _submit() async {
    final minor = int.tryParse(amount.text.trim());
    if ((widget.supplementReceipt == null && !hasReceiver(currency)) ||
        bytes == null ||
        contentType == null ||
        uploadKey == null ||
        minor == null ||
        minor <= 0) {
      setState(() => error = '입금액과 캡처를 확인해주세요.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      evidenceId ??=
          (await widget.api.uploadEvidence(
                widget.invoice['id'] as String,
                uploadKey!,
                bytes!,
                contentType!,
              ))['evidence_id']
              as String;
      if (widget.supplementReceipt case final receipt?) {
        await widget.api.supplementReceipt(
          receipt['receipt_id'] as String,
          evidenceId!,
        );
      } else {
        await widget.api.submitReceipt(
          evidenceId!,
          currency,
          minor,
          payer.text.trim(),
        );
      }
      if (!mounted) return;
      setState(() {
        bytes = null;
        contentType = null;
        uploadKey = null;
        evidenceId = null;
      });
      widget.onSubmitted();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('입금 캡처를 제출했습니다. 실제 수취 확인 후 반영됩니다.')),
      );
    } catch (_) {
      if (mounted) {
        setState(() => error = '제출 결과를 확인하지 못했습니다. 같은 증빙으로 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.supplementReceipt == null ? '송금 후 캡처 제출' : '기존 입금 증빙 보완'),
          if (widget.supplementReceipt != null)
            Text('보완 요청: ${widget.supplementReceipt!['reason']}'),
          const Text('캡처 제출만으로 입금완료가 되지 않습니다.'),
          if (receivers.isEmpty)
            const Text('송금 안내가 아직 등록되지 않았습니다. 판매자에게 확인해주세요.'),
          ...receivers.map(
            (r) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r['method'] == 'bank'
                      ? '한국 계좌'
                      : r['method'] == 'wechat'
                      ? '위챗페이'
                      : '알리페이'} · ${r['holder']} · ${r['instructions']}',
                ),
                if (r['private_qr_object_id'] != null)
                  Image.network(
                    widget.api.receiverQrUrl(
                      widget.invoice['id'] as String,
                      r['method'] as String,
                    ),
                    width: 220,
                    height: 220,
                  errorBuilder: (_, _, _) =>
                        const Text('QR을 불러오지 못했습니다. 판매자에게 문의해주세요.'),
                  ),
              ],
            ),
          ),
          if (widget.supplementReceipt == null)
            DropdownButton<String>(
              value: currency,
              items: [
                DropdownMenuItem(
                  value: 'KRW',
                  enabled: hasReceiver('KRW'),
                  child: const Text('원화 KRW'),
                ),
                DropdownMenuItem(
                  value: 'CNY',
                  enabled: hasReceiver('CNY'),
                  child: const Text('위안 CNY'),
                ),
              ],
              onChanged: busy || evidenceId != null
                  ? null
                  : (v) => setState(() {
                      currency = v!;
                      amount.text = currency == 'KRW'
                          ? '${widget.invoice['total_krw']}'
                          : '${widget.invoice['total_cny_fen']}';
                    }),
            ),
          if (widget.supplementReceipt == null)
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              enabled: !busy && evidenceId == null,
              decoration: InputDecoration(
                labelText: currency == 'KRW' ? '송금액 (원)' : '송금액 (전; 100전=1위안)',
              ),
            ),
          if (widget.supplementReceipt == null)
            TextField(
              controller: payer,
              enabled: !busy && evidenceId == null,
              decoration: const InputDecoration(labelText: '송금자 이름 (대리송금 가능)'),
            ),
          OutlinedButton(
            onPressed: busy || evidenceId != null ? null : _pick,
            child: Text(
              bytes == null ? '입금 캡처 선택' : '캡처 선택됨 · ${bytes!.length}바이트',
            ),
          ),
          FilledButton(
            onPressed:
                busy ||
                    (widget.supplementReceipt == null && !hasReceiver(currency))
                ? null
                : _submit,
            child: Text(
              widget.supplementReceipt == null ? '입금 캡처 제출' : '보완 캡처 제출',
            ),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
  );
}
