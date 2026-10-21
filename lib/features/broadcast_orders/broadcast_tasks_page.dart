import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';
import 'broadcast_repository.dart';

class BroadcastTasksPage extends StatefulWidget {
  const BroadcastTasksPage({
    super.key,
    required this.client,
    required this.sellerId,
  });
  final SupabaseClient client;
  final String sellerId;
  @override
  State<BroadcastTasksPage> createState() => _BroadcastTasksPageState();
}

class _BroadcastTasksPageState extends State<BroadcastTasksPage> {
  List<Map<String, dynamic>> tasks = [];
  Map<String, dynamic>? pendingCancel;
  bool busy = false, journalReady = false;
  String? error;
  String get _pendingName =>
      'broadcast_task_cancel_pending_${widget.sellerId}_${widget.client.auth.currentUser?.id}';
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingName);
      if (raw != null) {
        pendingCancel = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
      journalReady = true;
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '취소 재시도 기록을 열지 못했습니다. 새 취소를 시작하지 마세요: $e');
      }
    }
  }

  Future<void> _load() async {
    try {
      final rows =
          (await widget.client.rpc(
                'broadcast_tasks',
                params: {'p_seller_id': widget.sellerId},
              ))
              as List;
      if (mounted) {
        setState(() {
          tasks = rows.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '처리할 일을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _cancel(Map<String, dynamic> task) async {
    if (!journalReady || pendingCancel != null) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('미입금 청구 취소'),
        content: const Text('실제 입금이 없음을 확인한 뒤 취소합니다. 자동 취소는 하지 않습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('돌아가기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, '72시간 미입금 확인'),
            child: const Text('확인 후 취소'),
          ),
        ],
      ),
    );
    if (reason == null) return;
    final action = {
      'invoice_id': task['source_id'],
      'reason': reason,
      'key': BroadcastCommand('invoice.cancel', {}).key,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_pendingName, jsonEncode(action))) {
        throw StateError('취소 재시도 키 저장 실패');
      }
      pendingCancel = action;
      await _sendPendingCancel();
    } catch (e) {
      if (mounted) setState(() => error = '취소를 시작하지 못했습니다: $e');
    }
  }

  Future<void> _sendPendingCancel() async {
    final action = pendingCancel;
    if (action == null) return;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'broadcast_invoice_cancel',
        params: {
          'p_seller_id': widget.sellerId,
          'p_invoice_id': action['invoice_id'],
          'p_reason': action['reason'],
          'p_key': action['key'],
        },
      );
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_pendingName)) {
        throw StateError('확정된 취소 기록을 지우지 못했습니다.');
      }
      pendingCancel = null;
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '취소 결과를 확인하지 못했습니다. 같은 키로 재시도합니다: $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _resolveAddress(Map<String, dynamic> task) async {
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'broadcast_task_resolve_address',
        params: {
          'p_seller_id': widget.sellerId,
          'p_event_id': task['source_id'],
        },
      );
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _showMissing(Map<String, dynamic> task) async {
    try {
      final rows =
          (await widget.client.rpc(
                'broadcast_missing_detail',
                params: {
                  'p_seller_id': widget.sellerId,
                  'p_customer_id': task['customer_id'],
                },
              ))
              as List;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${task['nickname']} · 장기 미송'),
          content: SizedBox(
            width: 500,
            child: ListView(
              shrinkWrap: true,
              children: rows.map((raw) {
                final row = Map<String, dynamic>.from(raw as Map);
                return ListTile(
                  title: Text(
                    '${row['product_title']} · ${row['color']} / ${row['size']}',
                  ),
                  subtitle: Text(
                    '${row['supplier']} · 발주 ${row['ordered_at']} · ${row['days']}일',
                  ),
                  trailing: Text('${row['missing_quantity']}개'),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '장기 미송 상세를 불러오지 못했습니다: $e');
    }
  }

  String _title(Map<String, dynamic> task) {
    final name = task['nickname'] ?? '고객';
    return switch (task['type']) {
      'customer_request' =>
        '$name · ${task['kind'] == 'addition' ? '추가 주문' : '수정 요청'}',
      'access_request' => '$name · 새 기기 승인',
      'receipt_review' => '$name · 입금 확인',
      'address_change' => '$name · 주소 변경 확인',
      'unpaid_72h' => '$name · 72시간 미입금 취소 검토',
      'missing_14d' => '$name · 14일 초과 미송 ${task['quantity']}개',
      _ => '$name · 처리할 일',
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('${ServiceBrand.shortName} · 처리할 일'),
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
          '미처리 ${tasks.length}건',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final type in const [
              'customer_request',
              'receipt_review',
              'unpaid_72h',
              'missing_14d',
            ])
              Chip(
                label: Text(
                  '${switch (type) {
                    'customer_request' => '고객 요청',
                    'receipt_review' => '입금 확인',
                    'unpaid_72h' => '취소 검토',
                    _ => '장기 미송',
                  }} ${tasks.where((task) => task['type'] == type).length}',
                ),
              ),
          ],
        ),
        if (pendingCancel != null)
          Card(
            child: ListTile(
              title: const Text('결과 미확인 미입금 취소'),
              subtitle: Text('정산서 ${pendingCancel!['invoice_id']} · 같은 키로 재확인'),
              trailing: FilledButton(
                onPressed: busy ? null : _sendPendingCancel,
                child: const Text('재확인'),
              ),
            ),
          ),
        const Text('목록을 읽어도 항목은 사라지지 않습니다. 실제 업무를 처리해야 완료됩니다.'),
        ...tasks.map(
          (task) => Card(
            child: ListTile(
              title: Text(_title(task)),
              subtitle: Text(
                '${task['created_at'] ?? task['issued_at'] ?? task['oldest_ordered_at'] ?? ''}',
              ),
              trailing: switch (task['type']) {
                'unpaid_72h' => TextButton(
                  onPressed: busy || !journalReady || pendingCancel != null
                      ? null
                      : () => _cancel(task),
                  child: const Text('확인 후 취소'),
                ),
                'address_change' => TextButton(
                  onPressed: busy ? null : () => _resolveAddress(task),
                  child: const Text('확인 완료'),
                ),
                'customer_request' || 'access_request' => TextButton(
                  onPressed: busy
                      ? null
                      : () => context.go('/seller/broadcast/requests'),
                  child: const Text('처리'),
                ),
                'receipt_review' => TextButton(
                  onPressed: busy
                      ? null
                      : () => context.go('/seller/broadcast/receipts'),
                  child: const Text('입금 확인'),
                ),
                'missing_14d' => TextButton(
                  onPressed: busy ? null : () => _showMissing(task),
                  child: const Text('상세'),
                ),
                _ => null,
              },
            ),
          ),
        ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ],
    ),
  );
}
