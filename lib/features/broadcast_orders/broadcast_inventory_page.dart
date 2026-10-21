import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';
import 'broadcast_repository.dart';

class BroadcastInventoryPage extends StatefulWidget {
  const BroadcastInventoryPage({
    super.key,
    required this.client,
    required this.sellerId,
  });
  final SupabaseClient client;
  final String sellerId;
  @override
  State<BroadcastInventoryPage> createState() => _BroadcastInventoryPageState();
}

class _BroadcastInventoryPageState extends State<BroadcastInventoryPage> {
  List<Map<String, dynamic>> orders = [], items = [];
  final statuses = <String, Map<String, dynamic>>{};
  final defects = <String, List<Map<String, dynamic>>>{};
  String? selectedOrder, error;
  Map<String, dynamic>? pending;
  bool busy = false, journalReady = false;
  String get _pendingName =>
      'broadcast_inventory_pending_${widget.sellerId}_${widget.client.auth.currentUser?.id}';

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
        pending = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
      journalReady = true;
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '기기 요청 기록을 읽지 못했습니다. 새 입고를 접수하지 마세요: $e');
      }
    }
  }

  Future<void> _load() async {
    setState(() => busy = true);
    try {
      final page = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_purchase_page',
              params: {'p_seller_id': widget.sellerId, 'p_limit': 100},
            )
            as Map,
      );
      if (!mounted) return;
      setState(() {
        orders = (page['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        error = null;
      });
      if (selectedOrder != null) await _open(selectedOrder!);
    } catch (e) {
      if (mounted) setState(() => error = '발주 내역을 불러오지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _open(String id) async {
    setState(() => busy = true);
    try {
      final tables = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_purchase_tables',
              params: {
                'p_seller_id': widget.sellerId,
                'p_purchase_order_id': id,
              },
            )
            as Map,
      );
      final nextItems = (tables['supplier'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final details = await Future.wait(
        nextItems.map(
          (item) => widget.client.rpc(
            'broadcast_inventory_status',
            params: {
              'p_seller_id': widget.sellerId,
              'p_purchase_item_id': item['item_id'],
            },
          ),
        ),
      );
      final exchanges = await Future.wait(
        nextItems.map(
          (item) => widget.client.rpc(
            'broadcast_defect_page',
            params: {
              'p_seller_id': widget.sellerId,
              'p_purchase_item_id': item['item_id'],
            },
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        selectedOrder = id;
        items = nextItems;
        statuses.clear();
        defects.clear();
        for (var i = 0; i < nextItems.length; i++) {
          statuses[nextItems[i]['item_id'] as String] =
              Map<String, dynamic>.from(details[i] as Map);
          defects[nextItems[i]['item_id'] as String] = (exchanges[i] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '입고 현황을 불러오지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _record(Map<String, dynamic> item) async {
    if (pending != null) {
      await _sendPending();
      return;
    }
    final good = TextEditingController(text: '0');
    final defect = TextEditingController(text: '0');
    final values = await showDialog<List<int>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${item['product_title']} 입고'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: good,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '정상 수량'),
            ),
            TextField(
              controller: defect,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '불량 수량'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [
              int.tryParse(good.text) ?? -1,
              int.tryParse(defect.text) ?? -1,
            ]),
            child: const Text('입고 기록'),
          ),
        ],
      ),
    );
    good.dispose();
    defect.dispose();
    if (values == null) return;
    final remaining =
        (statuses[item['item_id']]?['unreceived'] as num?)?.toInt() ?? 0;
    if (values[0] < 0 ||
        values[1] < 0 ||
        values[0] + values[1] < 1 ||
        values[0] + values[1] > remaining) {
      setState(() => error = '정상·불량 합계는 1개 이상이며 남은 미송 수량 이하여야 합니다.');
      return;
    }
    final next = {
      'command': 'arrival.record',
      'data': {
        'purchase_item_id': item['item_id'],
        'good_quantity': values[0],
        'defect_quantity': values[1],
      },
      'key': BroadcastCommand('arrival.record', {}).key,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_pendingName, jsonEncode(next))) {
        throw StateError('재시도 요청을 기기에 저장하지 못했습니다.');
      }
      pending = next;
      await _sendPending();
    } catch (e) {
      if (mounted) setState(() => error = '입고를 시작하지 못했습니다: $e');
    }
  }

  Future<void> _sendPending() async {
    final action = pending;
    if (action == null) return;
    setState(() => busy = true);
    try {
      await widget.client.rpc(
        'broadcast_inventory_command',
        params: {
          'p_seller_id': widget.sellerId,
          'p_command': action['command'],
          'p_data': action['data'],
          'p_key': action['key'],
        },
      );
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_pendingName)) {
        throw StateError('확정 후 요청 기록을 지우지 못했습니다.');
      }
      pending = null;
      if (selectedOrder != null) await _open(selectedOrder!);
    } catch (e) {
      if (mounted) {
        setState(() => error = '입고 결과를 확인하지 못했습니다. 같은 요청으로 다시 확인해주세요: $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _allocate(Map<String, dynamic> item) async {
    if (pending != null) {
      await _sendPending();
      return;
    }
    final next = {
      'command': 'allocation.commit',
      'data': {'purchase_item_id': item['item_id']},
      'key': BroadcastCommand('allocation.commit', {}).key,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_pendingName, jsonEncode(next))) {
        throw StateError('재시도 키 저장 실패');
      }
      pending = next;
      await _sendPending();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _receiveExchange(
    Map<String, dynamic> item,
    Map<String, dynamic> defect,
  ) async {
    if (pending != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('불량 교환품 입고'),
        content: Text(
          '${item['product_title']} 교환품 ${defect['quantity']}개가 실제로 도착했습니까?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('입고 확인'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final next = {
      'command': 'exchange.receive',
      'data': {
        'purchase_item_id': item['item_id'],
        'defect_id': defect['id'],
        'quantity': defect['quantity'],
      },
      'key': BroadcastCommand('exchange.receive', {}).key,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_pendingName, jsonEncode(next))) {
        throw StateError('재시도 키 저장 실패');
      }
      pending = next;
      await _sendPending();
    } catch (e) {
      if (mounted) setState(() => error = '교환 입고를 시작하지 못했습니다: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('${ServiceBrand.shortName} · 입고'),
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
              title: const Text('결과 미확인 입고 요청'),
              subtitle: Text('${pending!['command']} · 같은 키로 재확인'),
              trailing: FilledButton(
                onPressed: busy ? null : _sendPending,
                child: const Text('재확인'),
              ),
            ),
          ),
        Text('거래처 발주', style: Theme.of(context).textTheme.titleMedium),
        ...orders.map(
          (o) => ListTile(
            title: Text('${o['supplier']} · ${o['quantity']}개'),
            subtitle: Text('${o['ordered_at']}'),
            selected: selectedOrder == o['id'],
            onTap: busy ? null : () => _open(o['id'] as String),
          ),
        ),
        const Divider(),
        ...items.map((item) {
          final s = statuses[item['item_id']] ?? {};
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${item['product_title']} · ${item['color']} / ${item['size']}',
                  ),
                  Text(
                    '발주 ${s['ordered'] ?? item['quantity']} · 정상입고 ${s['arrived_good'] ?? 0} · 불량교환 ${s['defect_waiting'] ?? 0} · 미송 ${s['unreceived'] ?? 0}',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy || pending != null || !journalReady
                            ? null
                            : () => _record(item),
                        child: const Text('부분입고 기록'),
                      ),
                      OutlinedButton(
                        onPressed: busy || pending != null || !journalReady
                            ? null
                            : () => _allocate(item),
                        child: const Text('주문순 배정'),
                      ),
                      for (final defect in defects[item['item_id']] ?? [])
                        OutlinedButton(
                          onPressed: busy || pending != null || !journalReady
                              ? null
                              : () => _receiveExchange(item, defect),
                          child: Text('불량교환 ${defect['quantity']}개 입고'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ],
    ),
  );
}
