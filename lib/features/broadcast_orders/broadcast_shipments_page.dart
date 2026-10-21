import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';
import 'broadcast_repository.dart';

class BroadcastShipmentsPage extends StatefulWidget {
  const BroadcastShipmentsPage({
    super.key,
    required this.client,
    required this.sellerId,
  });
  final SupabaseClient client;
  final String sellerId;
  @override
  State<BroadcastShipmentsPage> createState() => _BroadcastShipmentsPageState();
}

class _BroadcastShipmentsPageState extends State<BroadcastShipmentsPage> {
  final carrier = TextEditingController(), tracking = TextEditingController();
  final quantities = <String, TextEditingController>{};
  List<Map<String, dynamic>> ready = [], history = [];
  Map<String, dynamic>? historyCursor;
  Map<String, dynamic>? pending;
  String? customerId, error;
  bool busy = false, journalReady = false;
  String get _pendingName =>
      'broadcast_shipment_pending_${widget.sellerId}_${widget.client.auth.currentUser?.id}';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    carrier.dispose();
    tracking.dispose();
    for (final q in quantities.values) {
      q.dispose();
    }
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingName);
      if (raw != null) {
        pending = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
      journalReady = true;
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '기기 요청 기록을 읽지 못했습니다. 새 출고를 접수하지 마세요: $e');
      }
    }
  }

  Future<void> _load() async {
    setState(() => busy = true);
    try {
      final rows =
          (await widget.client.rpc(
                'broadcast_shipment_ready',
                params: {'p_seller_id': widget.sellerId},
              ))
              as List;
      if (!mounted) return;
      for (final q in quantities.values) {
        q.dispose();
      }
      quantities.clear();
      final next = rows
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      for (final row in next) {
        quantities[row['stock_allocation_id'] as String] =
            TextEditingController(text: '${row['available_quantity']}');
      }
      setState(() {
        ready = next;
        if (!ready.any((row) => row['customer_id'] == customerId)) {
          customerId = null;
        }
        error = null;
      });
      await _loadHistory(reset: true);
    } catch (e) {
      if (mounted) setState(() => error = '출고 가능 상품을 불러오지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadHistory({bool reset = false}) async {
    if (reset) historyCursor = null;
    try {
      final page = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_shipment_history',
              params: {
                'p_seller_id': widget.sellerId,
                'p_limit': 30,
                if (historyCursor != null) ...{
                  'p_before_at': historyCursor!['shipped_at'],
                  'p_before_id': historyCursor!['id'],
                },
              },
            )
            as Map,
      );
      if (!mounted) return;
      setState(() {
        final items = (page['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        history = reset ? items : [...history, ...items];
        historyCursor = page['next_cursor'] == null
            ? null
            : Map<String, dynamic>.from(page['next_cursor'] as Map);
      });
    } catch (e) {
      if (mounted) setState(() => error = '과거 출고를 불러오지 못했습니다: $e');
    }
  }

  Future<void> _sendPending() async {
    final action = pending;
    if (action == null) return;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'broadcast_shipment_create',
        params: {
          'p_seller_id': widget.sellerId,
          'p_data': action['data'],
          'p_key': action['key'],
        },
      );
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_pendingName)) {
        throw StateError('출고 확정 뒤 요청 기록을 지우지 못했습니다.');
      }
      pending = null;
      carrier.clear();
      tracking.clear();
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '출고 결과를 확인하지 못했습니다. 같은 키로 재확인해주세요: $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _create() async {
    if (pending != null) {
      await _sendPending();
      return;
    }
    if (customerId == null ||
        carrier.text.trim().isEmpty ||
        tracking.text.trim().isEmpty) {
      setState(() => error = '고객·택배사·송장번호를 확인해주세요.');
      return;
    }
    final lines = <Map<String, dynamic>>[];
    for (final row in ready.where((r) => r['customer_id'] == customerId)) {
      final id = row['stock_allocation_id'] as String;
      final qty = int.tryParse(quantities[id]?.text ?? '') ?? -1;
      final max = (row['available_quantity'] as num).toInt();
      if (qty < 0 || qty > max) {
        setState(() => error = '상품별 출고 수량은 0~$max개 사이여야 합니다.');
        return;
      }
      if (qty > 0) lines.add({'stock_allocation_id': id, 'quantity': qty});
    }
    if (lines.isEmpty) {
      setState(() => error = '출고할 상품을 선택해주세요.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('출고 확정'),
        content: Text(
          '선택한 ${lines.length}개 주문행을 ${carrier.text.trim()} / ${tracking.text.trim()}로 출고합니다. 현재 고객 주소가 스냅샷으로 저장됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('돌아가기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('출고 확정'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final next = {
      'key': BroadcastCommand('shipment.create', {}).key,
      'data': {
        'customer_id': customerId,
        'carrier': carrier.text.trim(),
        'tracking_number': tracking.text.trim(),
        'lines': lines,
      },
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_pendingName, jsonEncode(next))) {
        throw StateError('재시도 키 저장 실패');
      }
      pending = next;
      await _sendPending();
    } catch (e) {
      if (mounted) setState(() => error = '출고를 시작하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final names = <String, String>{};
    for (final row in ready) {
      names[row['customer_id'] as String] = row['nickname'] as String;
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('${ServiceBrand.shortName} · 출고'),
        actions: [
          IconButton(
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (pending != null)
            Card(
              child: ListTile(
                title: const Text('결과 미확인 출고 요청'),
                subtitle: const Text('같은 상품·송장·요청 키로 재확인합니다.'),
                trailing: FilledButton(
                  onPressed: busy ? null : _sendPending,
                  child: const Text('재확인'),
                ),
              ),
            ),
          const Text('정상 입고 후 고객에게 배정된 상품만 표시합니다.'),
          DropdownButtonFormField<String>(
            key: ValueKey(customerId),
            initialValue: customerId,
            decoration: const InputDecoration(labelText: '고객'),
            items: names.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: busy || pending != null
                ? null
                : (v) => setState(() => customerId = v),
          ),
          ...ready.where((row) => row['customer_id'] == customerId).map((row) {
            final id = row['stock_allocation_id'] as String;
            return Card(
              child: ListTile(
                title: Text(
                  '${row['product_title']} · ${row['color']} / ${row['size']}',
                ),
                subtitle: Text('출고 가능 ${row['available_quantity']}개'),
                trailing: SizedBox(
                  width: 72,
                  child: TextField(
                    controller: quantities[id],
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '수량'),
                  ),
                ),
              ),
            );
          }),
          TextField(
            controller: carrier,
            decoration: const InputDecoration(labelText: '택배사'),
          ),
          TextField(
            controller: tracking,
            decoration: const InputDecoration(labelText: '송장번호'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy || pending != null || !journalReady
                ? null
                : _create,
            child: const Text('부분/전량 출고 확정'),
          ),
          const SizedBox(height: 24),
          Text('과거 출고·송장', style: Theme.of(context).textTheme.titleMedium),
          ...history.map((shipment) {
            final address = Map<String, dynamic>.from(
              shipment['address_snapshot'] as Map? ?? {},
            );
            final lines = (shipment['lines'] as List? ?? []).cast<Map>();
            return Card(
              child: ExpansionTile(
                title: Text(
                  '${shipment['nickname']} · ${shipment['carrier']} ${shipment['tracking_number']}',
                ),
                subtitle: Text('${shipment['shipped_at']}'),
                children: [
                  ListTile(
                    title: const Text('출고 당시 주소'),
                    subtitle: Text(
                      '${address['recipient'] ?? ''} · ${address['region'] ?? ''} ${address['detail'] ?? ''}',
                    ),
                  ),
                  ...lines.map(
                    (line) => ListTile(
                      title: Text(
                        '${line['product_title']} · ${line['color']} / ${line['size']}',
                      ),
                      trailing: Text('${line['quantity']}개'),
                    ),
                  ),
                ],
              ),
            );
          }),
          if (historyCursor != null)
            TextButton(
              onPressed: busy ? null : () => _loadHistory(),
              child: const Text('과거 출고 더 보기'),
            ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    );
  }
}
