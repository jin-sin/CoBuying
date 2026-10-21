import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';
import 'broadcast_repository.dart';

class BroadcastReceiptsPage extends StatefulWidget {
  const BroadcastReceiptsPage({
    super.key,
    required this.client,
    required this.sellerId,
  });
  final SupabaseClient client;
  final String sellerId;
  @override
  State<BroadcastReceiptsPage> createState() => _BroadcastReceiptsPageState();
}

class _BroadcastReceiptsPageState extends State<BroadcastReceiptsPage> {
  List<Map<String, dynamic>> receipts = [];
  final keys = <String, String>{};
  final infoReasons = <String, String>{};
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows =
          (await widget.client.rpc(
                'broadcast_receipt_page',
                params: {
                  'p_seller_id': widget.sellerId,
                  'p_status': 'pending_review',
                },
              ))
              as List;
      if (mounted) {
        setState(() {
          receipts = rows
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '입금 증빙을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _inspect(Map<String, dynamic> receipt) async {
    Uint8List bytes;
    try {
      bytes = await widget.client.storage
          .from('broadcast-evidence')
          .download(receipt['object_key'] as String);
    } catch (e) {
      if (mounted) setState(() => error = '비공개 증빙을 열지 못했습니다: $e');
      return;
    }
    if (!mounted) return;
    final amount = TextEditingController(text: '${receipt['claimed_minor']}');
    final receiver = TextEditingController();
    final transaction = TextEditingController();
    final confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${receipt['nickname']} · 입금 증빙'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 380),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text('이미지를 열 수 없습니다.'),
                  ),
                ),
                Text(
                  '신고 금액: ${receipt['claimed_minor']} ${receipt['currency']}',
                ),
                const Text('캡처와 별개로 실제 수취내역을 확인한 뒤 금액·계정·거래번호를 입력하세요.'),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '실제 수취 금액 (KRW 원 / CNY 전)',
                  ),
                ),
                TextField(
                  controller: receiver,
                  decoration: const InputDecoration(labelText: '실제 수취 계정'),
                ),
                TextField(
                  controller: transaction,
                  decoration: const InputDecoration(labelText: '거래번호'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'receipt_id': receipt['id'],
              'confirmed_minor': int.tryParse(amount.text),
              'receiver': receiver.text.trim(),
              'transaction_ref': transaction.text.trim(),
            }),
            child: const Text('실제 수취 확인'),
          ),
        ],
      ),
    );
    amount.dispose();
    receiver.dispose();
    transaction.dispose();
    if (confirmed == null) return;
    if (confirmed['confirmed_minor'] == null ||
        confirmed['receiver'] == '' ||
        confirmed['transaction_ref'] == '') {
      setState(() => error = '실제 수취 금액·계정·거래번호를 입력해주세요.');
      return;
    }
    final id = receipt['id'] as String;
    keys[id] ??= BroadcastCommand('receipt.confirm', {}).key;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'broadcast_payment_command',
        params: {
          'p_seller_id': widget.sellerId,
          'p_command': 'receipt.confirm',
          'p_data': confirmed,
          'p_key': keys[id],
        },
      );
      keys.remove(id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '확인 결과를 알 수 없습니다. 같은 키로 재확인해주세요: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _requestInfo(Map<String, dynamic> receipt) async {
    final id = receipt['id'] as String;
    final reason = TextEditingController(text: infoReasons[id]);
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('증빙 보완 요청'),
        content: TextField(
          controller: reason,
          maxLength: 500,
          decoration: const InputDecoration(labelText: '고객에게 보일 사유'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, reason.text.trim()),
            child: const Text('보완 요청'),
          ),
        ],
      ),
    );
    reason.dispose();
    if (entered == null) return;
    if (entered.isEmpty) {
      setState(() => error = '보완 사유를 입력해주세요.');
      return;
    }
    if (infoReasons[id] != entered) keys.remove('info-$id');
    infoReasons[id] = entered;
    final key = keys.putIfAbsent('info-$id', () => BroadcastCommand('receipt.info', {}).key);
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'broadcast_receipt_request_info',
        params: {
          'p_seller_id': widget.sellerId,
          'p_receipt_id': id,
          'p_reason': entered,
          'p_key': key,
        },
      );
      keys.remove('info-$id');
      infoReasons.remove(id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '보완 요청 결과를 확인하지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('${ServiceBrand.shortName} · 입금 확인'),
      actions: [
        IconButton(
          onPressed: busy ? null : _load,
          icon: const Icon(Icons.refresh),
          tooltip: '새로고침',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '확인 대기 ${receipts.length}건',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        ...receipts.map(
          (r) => Card(
            child: ListTile(
              title: Text(
                '${r['nickname']} · ${r['claimed_minor']} ${r['currency']}',
              ),
              subtitle: Text('신고 송금자: ${r['payer_name']} · ${r['created_at']}'),
              trailing: Wrap(
                spacing: 4,
                children: [
                  OutlinedButton(
                    onPressed: busy ? null : () => _requestInfo(r),
                    child: const Text('보완 요청'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : () => _inspect(r),
                    child: const Text('증빙·수취 대조'),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ],
    ),
  );
}
