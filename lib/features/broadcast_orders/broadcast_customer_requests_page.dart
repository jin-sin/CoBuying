import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';
import 'broadcast_repository.dart';

class BroadcastCustomerRequestsPage extends StatefulWidget {
  const BroadcastCustomerRequestsPage({
    super.key,
    required this.client,
    required this.sellerId,
  });
  final SupabaseClient client;
  final String sellerId;
  @override
  State<BroadcastCustomerRequestsPage> createState() =>
      _BroadcastCustomerRequestsPageState();
}

class _BroadcastCustomerRequestsPageState
    extends State<BroadcastCustomerRequestsPage> {
  final customerId = TextEditingController();
  List<BroadcastRow> requests = [], devices = [], access = [];
  Map<String, dynamic>? pendingReview;
  bool busy = false, journalReady = false;
  String? message;
  String get _pendingName =>
      'broadcast_review_pending_${widget.sellerId}_${widget.client.auth.currentUser?.id}';
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    customerId.dispose();
    super.dispose();
  }

  Future<dynamic> _rpc(String name, Map<String, dynamic> params) =>
      widget.client.rpc(name, params: params);
  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingName);
      if (raw != null) {
        pendingReview = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
      journalReady = true;
      await _load();
    } catch (e) {
      if (mounted) setState(() => message = '요청 재시도 기록을 열지 못했습니다: $e');
    }
  }

  Future<void> _load() async {
    try {
      final list =
          (await _rpc('broadcast_customer_request_page', {
                'p_seller_id': widget.sellerId,
                'p_status': 'pending',
                'p_limit': 100,
              }))
              as List;
      final overview = Map<String, dynamic>.from(
        (await _rpc('broadcast_access_overview', {
              'p_seller_id': widget.sellerId,
            }))
            as Map,
      );
      if (!mounted) return;
      setState(() {
        requests = list
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        access = (overview['requests'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        devices = (overview['devices'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        message = null;
      });
    } catch (e) {
      if (mounted) setState(() => message = '목록을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _link() async {
    if (customerId.text.trim().isEmpty) return;
    setState(() => busy = true);
    try {
      final result = Map<String, dynamic>.from(
        (await _rpc('broadcast_customer_link', {
              'p_seller_id': widget.sellerId,
              'p_customer_id': customerId.text.trim(),
            }))
            as Map,
      );
      final link = Uri.base
          .replace(
            path: '/broadcast/${result['locator']}',
            query: null,
            fragment: null,
          )
          .toString();
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) setState(() => message = '고객 링크를 복사했습니다. 기존 위챗 대화로 전달해주세요.');
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _approve(BroadcastRow row) async {
    setState(() => busy = true);
    try {
      final result = Map<String, dynamic>.from(
        (await _rpc('broadcast_access_approve', {
              'p_seller_id': widget.sellerId,
              'p_request_id': row['id'],
            }))
            as Map,
      );
      final link = Uri.base
          .replace(
            path: '/broadcast/${result['locator']}',
            queryParameters: {
              'request': result['request_id'] as String,
              'token': result['activation_token'] as String,
            },
            fragment: null,
          )
          .toString();
      await Clipboard.setData(ClipboardData(text: link));
      await _load();
      if (mounted) {
        setState(
          () => message =
              '승인 링크를 복사했습니다. 기존 위챗 연락으로 본인을 확인한 고객에게만 전달해주세요. 30분 후 만료됩니다.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _review(BroadcastRow row) async {
    if (!journalReady || pendingReview != null) return;
    final billed = row['invoice_id'] != null && row['kind'] == 'change';
    final color = TextEditingController(
      text: row['current_color'] as String? ?? '',
    );
    final size = TextEditingController(
      text: row['current_size'] as String? ?? '',
    );
    final quantity = TextEditingController(
      text: '${row['current_quantity'] ?? 1}',
    );
    final price = TextEditingController(
      text: '${row['current_unit_price_krw'] ?? 0}',
    );
    final reason = TextEditingController();
    bool cancelled = false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('${row['nickname']} · ${row['product_title'] ?? '상품'}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('고객 원문: ${row['raw_text']}'),
                TextField(
                  controller: color,
                  decoration: const InputDecoration(labelText: '확정 색상'),
                ),
                TextField(
                  controller: size,
                  decoration: const InputDecoration(labelText: '확정 사이즈'),
                ),
                TextField(
                  controller: quantity,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '확정 수량'),
                ),
                if (billed)
                  TextField(
                    controller: price,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '확정 단가 (원)'),
                  ),
                if (billed)
                  CheckboxListTile(
                    title: const Text('이 상품을 청구에서 제외'),
                    value: cancelled,
                    onChanged: (value) =>
                        update(() => cancelled = value ?? false),
                  ),
                TextField(
                  controller: reason,
                  decoration: const InputDecoration(
                    labelText: '처리 사유 (반려·청구 정정 때 필수)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, {
                'action': 'decline',
                'resolution': reason.text.trim(),
              }),
              child: const Text('반려'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'action': 'accept',
                'color': color.text.trim(),
                'size': size.text.trim(),
                'quantity': int.tryParse(quantity.text),
                'unit_price_krw': int.tryParse(price.text),
                'cancelled': cancelled,
                'resolution': reason.text.trim(),
                'expected_version': row['current_version'],
              }),
              child: const Text('확정'),
            ),
          ],
        ),
      ),
    );
    color.dispose();
    size.dispose();
    quantity.dispose();
    price.dispose();
    reason.dispose();
    if (result == null) return;
    if (result['action'] == 'decline' &&
        (result['resolution'] as String).isEmpty) {
      setState(() => message = '반려 사유를 입력해주세요.');
      return;
    }
    if (result['action'] == 'accept' &&
        result['cancelled'] != true &&
        (result['quantity'] == null ||
            (billed && result['unit_price_krw'] == null))) {
      setState(() => message = '수량과 단가를 확인해주세요.');
      return;
    }
    if (billed && (result['resolution'] as String).isEmpty) {
      setState(() => message = '청구 정정 사유를 입력해주세요.');
      return;
    }
    final action = result.remove('action') as String;
    final next = <String, dynamic>{
      'request_id': row['id'],
      'action': action,
      'invoice_id': billed && action == 'accept' ? row['invoice_id'] : null,
      'data': result,
      'key': BroadcastCommand('review', {}).key,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_pendingName, jsonEncode(next))) {
        throw StateError('요청 기록 저장 실패');
      }
      pendingReview = next;
      await _sendReview();
    } catch (e) {
      if (mounted) setState(() => message = '처리 명령을 시작하지 못했습니다: $e');
    }
  }

  Future<void> _sendReview() async {
    final action = pendingReview;
    if (action == null) return;
    setState(() => busy = true);
    try {
      if (action['invoice_id'] != null) {
        final data = Map<String, dynamic>.from(action['data'] as Map);
        await _rpc('broadcast_invoice_revise_request', {
          'p_seller_id': widget.sellerId,
          'p_invoice_id': action['invoice_id'],
          'p_request_id': action['request_id'],
          'p_change': data,
          'p_reason': data['resolution'],
          'p_key': action['key'],
        });
      } else {
        await _rpc('broadcast_customer_request_review', {
          'p_seller_id': widget.sellerId,
          'p_request_id': action['request_id'],
          'p_action': action['action'],
          'p_data': action['data'],
          'p_key': action['key'],
        });
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_pendingName)) {
        throw StateError('확정된 요청 기록을 지우지 못했습니다.');
      }
      pendingReview = null;
      await _load();
    } on PostgrestException catch (e) {
      final prefs = await SharedPreferences.getInstance();
      if (await prefs.remove(_pendingName)) {
        pendingReview = null;
      }
      if (mounted) {
        setState(() => message = '요청을 처리하지 못했습니다. 내용을 다시 확인해주세요: ${e.message}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => message = '처리 결과를 확인하지 못했습니다. 같은 키로 재확인해주세요: $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('${ServiceBrand.shortName} · 고객 요청'),
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
        if (pendingReview != null)
          Card(
            child: ListTile(
              title: const Text('결과 미확인 고객 요청 처리'),
              subtitle: const Text('같은 내용과 키로 결과를 재확인합니다.'),
              trailing: FilledButton(
                onPressed: busy ? null : _sendReview,
                child: const Text('재확인'),
              ),
            ),
          ),
        Text('고객 링크', style: Theme.of(context).textTheme.titleMedium),
        TextField(
          controller: customerId,
          decoration: const InputDecoration(labelText: '내부 고객 ID'),
        ),
        FilledButton(
          onPressed: busy ? null : _link,
          child: const Text('고정 링크 복사'),
        ),
        const Divider(),
        Text('새 기기 접근 요청', style: Theme.of(context).textTheme.titleMedium),
        ...access.map(
          (r) => ListTile(
            title: Text('${r['nickname']} · ${r['status']}'),
            subtitle: Text('요청: ${r['created_at']}'),
            trailing: FilledButton(
              onPressed: busy ? null : () => _approve(r),
              child: const Text('위챗 확인 후 승인'),
            ),
          ),
        ),
        Text('활성 기기', style: Theme.of(context).textTheme.titleMedium),
        ...devices.map(
          (d) => ListTile(
            title: Text('${d['nickname']}'),
            subtitle: Text('만료: ${d['expires_at']}'),
            trailing: TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        await _rpc('broadcast_access_revoke', {
                          'p_seller_id': widget.sellerId,
                          'p_device_id': d['id'],
                        });
                        await _load();
                      } catch (e) {
                        if (mounted) setState(() => message = '$e');
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
              child: const Text('접근 회수'),
            ),
          ),
        ),
        const Divider(),
        Text('추가·수정 요청', style: Theme.of(context).textTheme.titleMedium),
        ...requests.map(
          (r) => ListTile(
            title: Text('${r['nickname']} · ${r['raw_text']}'),
            subtitle: Text(
              '${r['kind'] == 'addition' ? '추가' : '수정'} · ${r['product_title'] ?? ''}',
            ),
            trailing: FilledButton(
              onPressed: busy || pendingReview != null || !journalReady
                  ? null
                  : () => _review(r),
              child: const Text('검토'),
            ),
          ),
        ),
        if (message != null) Text(message!),
      ],
    ),
  );
}
