import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';
import 'broadcast_purchase_export.dart';
import 'broadcast_repository.dart';

class BroadcastPurchasesPage extends StatefulWidget {
  const BroadcastPurchasesPage({
    super.key,
    required this.client,
    required this.sellerId,
  });
  final SupabaseClient client;
  final String sellerId;

  @override
  State<BroadcastPurchasesPage> createState() => _BroadcastPurchasesPageState();
}

class _BroadcastPurchasesPageState extends State<BroadcastPurchasesPage> {
  List<Map<String, dynamic>> preview = [];
  List<Map<String, dynamic>> orders = [];
  String? nextBefore, nextId, pendingKey, error;
  bool busy = false, journalReady = false;
  String get _pendingName =>
      'broadcast_purchase_pending_${widget.sellerId}_${widget.client.auth.currentUser?.id}';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        pendingKey = prefs.getString(_pendingName);
        journalReady = true;
      });
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '기기 요청 기록을 읽지 못했습니다. 새 발주를 확정하지 마세요: $e');
      }
    }
  }

  List<Map<String, dynamic>> _maps(dynamic value) =>
      (value as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> _load({bool more = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final results = await Future.wait([
        widget.client.rpc(
          'broadcast_purchase_preview',
          params: {'p_seller_id': widget.sellerId},
        ),
        widget.client.rpc(
          'broadcast_purchase_page',
          params: {
            'p_seller_id': widget.sellerId,
            'p_limit': 50,
            if (more) 'p_before': nextBefore,
            if (more) 'p_before_id': nextId,
          },
        ),
      ]);
      final page = Map<String, dynamic>.from(results[1] as Map);
      if (!mounted) return;
      setState(() {
        preview = _maps(results[0]);
        orders = more
            ? [...orders, ..._maps(page['items'])]
            : _maps(page['items']);
        nextBefore = page['next_before'] as String?;
        nextId = page['next_before_id'] as String?;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '발주 데이터를 불러오지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _commit() async {
    if (preview.isEmpty && pendingKey == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('거래처 발주 확정'),
        content: Text(
          pendingKey == null
              ? '입금 확인·최종 확인된 미발주 수량을 거래처별로 발주합니다. 현재 ${preview.length}개 품목입니다.'
              : '이전 발주 결과가 확인되지 않았습니다. 같은 요청 키로 결과를 재확인합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('돌아가기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('발주 확정'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = pendingKey ?? BroadcastCommand('purchase.commit', {}).key;
      if (pendingKey == null) {
        final saved = await prefs.setString(_pendingName, key);
        if (!saved) throw StateError('발주 재시도 키를 기기에 저장하지 못했습니다.');
        pendingKey = key;
      }
      await widget.client.rpc(
        'broadcast_purchase_commit',
        params: {'p_seller_id': widget.sellerId, 'p_key': key},
      );
      final removed = await prefs.remove(_pendingName);
      if (!removed) throw StateError('발주 결과는 확정됐으나 기기 요청 기록을 지우지 못했습니다.');
      pendingKey = null;
      if (mounted) setState(() => busy = false);
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '발주 결과를 확인하지 못했습니다. 같은 키로 재확인해주세요: $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _export(
    Map<String, dynamic> order,
    BroadcastPurchaseExportKind kind,
  ) async {
    setState(() => busy = true);
    try {
      final tables = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_purchase_tables',
              params: {
                'p_seller_id': widget.sellerId,
                'p_purchase_order_id': order['id'],
              },
            )
            as Map,
      );
      final rows = _maps(
        tables[kind == BroadcastPurchaseExportKind.supplier
            ? 'supplier'
            : 'customers'],
      );
      final bytes = buildBroadcastPurchaseXlsx(rows, kind);
      final suffix = kind == BroadcastPurchaseExportKind.supplier
          ? '거래처발주'
          : '고객관리';
      await FileSaver.instance.saveFile(
        name: '오렌담_${suffix}_${order['id']}',
        bytes: bytes,
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = '파일을 만들거나 저장하지 못했습니다. 다시 시도해주세요: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('${ServiceBrand.shortName} · 발주'),
      actions: [
        IconButton(
          onPressed: busy ? null : () => _load(),
          icon: const Icon(Icons.refresh),
          tooltip: '새로고침',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '발주 가능 품목 ${preview.length}건',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text('입금과 고객 최종 확인이 끝난 주문만 발주 후보에 포함됩니다.'),
        ...preview.map(
          (r) => ListTile(
            title: Text('${r['supplier']} · ${r['color']} / ${r['size']}'),
            subtitle: Text('${r['product_title']}'),
            trailing: Text('${r['quantity']}개'),
          ),
        ),
        if (pendingKey != null) const Text('이전 발주 결과를 확인해야 합니다.'),
        FilledButton(
          onPressed:
              busy || !journalReady || (preview.isEmpty && pendingKey == null)
              ? null
              : _commit,
          child: Text(pendingKey == null ? '발주 확정' : '이전 발주 결과 재확인'),
        ),
        const Divider(height: 32),
        Text('발주 내역', style: Theme.of(context).textTheme.titleMedium),
        ...orders.map(
          (order) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${order['supplier']} · ${order['quantity']}개'),
                  Text('${order['ordered_at']}'),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => _export(
                                order,
                                BroadcastPurchaseExportKind.supplier,
                              ),
                        child: const Text('거래처 발주표 XLSX'),
                      ),
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => _export(
                                order,
                                BroadcastPurchaseExportKind.customers,
                              ),
                        child: const Text('내부 고객관리표 XLSX'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (nextId != null)
          TextButton(
            onPressed: busy ? null : () => _load(more: true),
            child: const Text('더 보기'),
          ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ],
    ),
  );
}
