import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/service_brand.dart';
import 'broadcast_customer_api.dart';
import 'broadcast_payment_card.dart';

class BroadcastCustomerPage extends StatefulWidget {
  const BroadcastCustomerPage({
    super.key,
    required this.locator,
    this.activationRequest,
    this.activationToken,
  });
  final String locator;
  final String? activationRequest, activationToken;
  @override
  State<BroadcastCustomerPage> createState() => _BroadcastCustomerPageState();
}

class _BroadcastCustomerPageState extends State<BroadcastCustomerPage> {
  late final BroadcastCustomerApi api;
  final raw = TextEditingController();
  final recipient = TextEditingController(), phone = TextEditingController();
  final region = TextEditingController(), detail = TextEditingController();
  Map<String, dynamic>? view;
  Map<String, dynamic>? billing;
  List<Map<String, dynamic>> requests = [];
  List<Map<String, dynamic>> shipments = [];
  List<Map<String, dynamic>> payments = [];
  List<Map<String, dynamic>> depositReturns = [];
  List<Map<String, dynamic>> receiptsNeedingInfo = [];
  String? selectedProduct,
      selectedLine,
      error,
      pendingKey,
      pendingKind,
      pendingTarget;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    api = BroadcastCustomerApi(widget.locator);
    _load();
  }

  @override
  void dispose() {
    raw.dispose();
    for (final c in [recipient, phone, region, detail]) {
      c.dispose();
    }
    api.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final next = await api.view();
      final pending = await api.requests();
      final nextBilling = await api.billing();
      final nextShipments = await api.shipments();
      final nextPayments = await api.payments();
      final nextDepositReturns = await api.depositReturns();
      final nextNeedsInfo = await api.receiptsNeedingInfo();
      if (!mounted) return;
      setState(() {
        view = next;
        requests = pending;
        billing = nextBilling;
        shipments = nextShipments;
        payments = nextPayments;
        depositReturns = nextDepositReturns;
        receiptsNeedingInfo = nextNeedsInfo;
        final address =
            (nextBilling['destination'] as Map?)?['address'] as Map?;
        if (address != null) {
          recipient.text = address['recipient'] as String? ?? '';
          phone.text = address['phone'] as String? ?? '';
          region.text = address['region'] as String? ?? '';
          detail.text = address['detail'] as String? ?? '';
        }
        error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        view = null;
        error = '이 기기의 접근 확인이 필요합니다.';
      });
    }
  }

  Future<void> _access() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.requestAccess();
      if (!mounted) return;
      setState(() {
        error = '판매자에게 위챗으로 기기 승인을 요청해주세요. 승인받은 링크를 이 기기에서 열어주세요.';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _activate() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.activate(widget.activationRequest!, widget.activationToken!);
      if (!mounted) return;
      context.go('/broadcast/${widget.locator}');
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _newKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  String _cny(dynamic fen) =>
      '¥${((num.tryParse('$fen') ?? 0) / 100).toStringAsFixed(2)}';

  Future<void> _submit(String kind, String? target) async {
    if (target == null || raw.text.trim().isEmpty || busy) return;
    if (pendingKey != null &&
        (pendingKind != kind || pendingTarget != target)) {
      setState(() => error = '이전 요청 결과를 먼저 다시 확인해주세요.');
      return;
    }
    pendingKey ??= _newKey();
    pendingKind = kind;
    pendingTarget = target;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.submit(
        kind: kind,
        targetId: target,
        rawText: raw.text.trim(),
        requestKey: pendingKey!,
      );
      pendingKey = null;
      pendingKind = null;
      pendingTarget = null;
      raw.clear();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('요청을 접수했습니다. 판매자 확인 후 반영됩니다.')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = '접수 결과를 확인하지 못했습니다. 같은 내용으로 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveAddress() async {
    final destination = billing?['destination'] as Map?;
    if (destination == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.saveAddress({
        'country': destination['country'],
        'recipient': recipient.text.trim(),
        'phone': phone.text.trim(),
        'region': region.text.trim(),
        'detail': detail.text.trim(),
      }, destination['version'] as int);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _acceptInvoice(String id) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await api.acceptInvoice(id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = (view?['products'] as List? ?? []).cast<Map>();
    final orders = (view?['orders'] as List? ?? []).cast<Map>();
    return Scaffold(
      appBar: AppBar(title: const Text('${ServiceBrand.shortName} · 내 방송 주문')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (view == null) ...[
            const Text('고객 전용 링크는 이 기기에서 판매자 확인을 받은 뒤 사용할 수 있습니다.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : _access,
              child: const Text('이 기기 접근 요청'),
            ),
            if (widget.activationRequest != null &&
                widget.activationToken != null)
              OutlinedButton(
                onPressed: busy ? null : _activate,
                child: const Text('판매자 승인 활성화'),
              ),
          ] else ...[
            Text(
              '${view!['customer']['nickname']}님의 주문',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Text('오늘 소개한 상품', style: Theme.of(context).textTheme.titleMedium),
            ...products.map(
              (p) => ListTile(
                title: Text(
                  '${p['number']}번 · ${p['title']} · ${p['price_krw']}원',
                ),
                subtitle: p['in_outfit'] == true ? const Text('현재 코디') : null,
                selected: selectedProduct == p['id'],
                onTap: busy || pendingKey != null
                    ? null
                    : () => setState(() {
                        selectedProduct = p['id'] as String;
                        selectedLine = null;
                      }),
              ),
            ),
            Text('내 주문', style: Theme.of(context).textTheme.titleMedium),
            ...orders.map(
              (o) => ListTile(
                title: Text(
                  '${o['product_number']}번 · ${o['product_title']} · ${o['color']} ${o['size']} ${o['quantity']}개',
                ),
                subtitle: o['cancelled'] == true ? const Text('취소') : null,
                selected: selectedLine == o['id'],
                onTap: busy || pendingKey != null
                    ? null
                    : () => setState(() {
                        selectedLine = o['id'] as String;
                        selectedProduct = null;
                      }),
              ),
            ),
            TextField(
              controller: raw,
              maxLength: 500,
              maxLines: 2,
              enabled: !busy && pendingKey == null,
              decoration: InputDecoration(
                labelText: selectedLine != null
                    ? '수정 요청 (예: L로 바꿔주세요)'
                    : '추가 주문 (예: 검정 M 하나)',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => _submit(
                      selectedLine == null ? 'addition' : 'change',
                      selectedLine ?? selectedProduct,
                    ),
              child: Text(selectedLine == null ? '추가 주문 요청' : '수정 요청'),
            ),
            const SizedBox(height: 16),
            Text(
              '판매자 확인 대기/처리 결과',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ...requests.map(
              (r) => ListTile(
                title: Text(r['raw_text'] as String),
                subtitle: Text('${r['status']} ${r['resolution'] ?? ''}'),
              ),
            ),
            const SizedBox(height: 16),
            Text('정산서', style: Theme.of(context).textTheme.titleMedium),
            ...((billing?['invoices'] as List? ?? []).cast<Map>().where(
              (invoice) => invoice['status'] == 'issued',
            )).map(
              (i) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('정산서 ${i['version']}판 · ${i['status']}'),
                      if ((i['snapshot'] as Map?)?['revision_reason'] != null)
                        Text('정정 사유: ${i['snapshot']['revision_reason']}'),
                      ...((i['lines'] as List? ?? []).cast<Map>()).map(
                        (l) => Text(
                          '${l['product_number']}번 ${l['product_title']} ${l['color']} ${l['size']} ${l['quantity']}개 × ${l['unit_price_krw']}원',
                        ),
                      ),
                      Text(
                        '상품 ${i['subtotal_krw']}원 · 배송 ${i['snapshot']['country'] == 'KR' ? '${i['shipping_krw']}원' : _cny(i['shipping_cny_fen'])} · 선입금 차감 ${i['deposit_krw']}원',
                      ),
                      Text(
                        '남은 금액 ${i['total_krw']}원 / ${_cny(i['total_cny_fen'])} (택일)',
                      ),
                      if (i['accepted_at'] == null && i['status'] == 'issued')
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () => _acceptInvoice(i['id'] as String),
                          child: const Text('주소 확인 후 최종 주문 확인'),
                        ),
                      if (i['accepted_at'] != null &&
                          i['status'] == 'issued' &&
                          (num.tryParse('${i['total_krw']}') ?? 0) > 0)
                        ...receiptsNeedingInfo
                            .where((r) => r['invoice_id'] == i['id'])
                            .map(
                              (r) => BroadcastPaymentCard(
                                key: ValueKey('supplement-${r['receipt_id']}'),
                                invoice: i,
                                api: api,
                                newKey: _newKey,
                                onSubmitted: _load,
                                supplementReceipt: r,
                              ),
                            ),
                      if (i['accepted_at'] != null &&
                          i['status'] == 'issued' &&
                          (num.tryParse('${i['total_krw']}') ?? 0) > 0 &&
                          !receiptsNeedingInfo.any(
                            (r) => r['invoice_id'] == i['id'],
                          ))
                        BroadcastPaymentCard(
                          key: ValueKey('payment-${i['id']}'),
                          invoice: i,
                          api: api,
                          newKey: _newKey,
                          onSubmitted: _load,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            ...payments.map(
              (p) => Text(
                '입금 확인 ${p['confirmed_minor']} / 청구 ${p['due_minor']} ${p['currency'] ?? 'KRW'} · 확인 대기 ${p['pending_count']}건',
              ),
            ),
            if (depositReturns.isNotEmpty) ...[
              Text('선입금 반환 내역', style: Theme.of(context).textTheme.titleMedium),
              ...depositReturns.map(
                (r) => Text(
                  '${r['amount_krw']}원 반환 · ${r['reason']} · ${r['returned_at']}',
                ),
              ),
            ],
            if ((billing?['invoices'] as List? ?? []).isNotEmpty) ...[
              Text('배송주소', style: Theme.of(context).textTheme.titleMedium),
              Text('배송국가: ${billing?['destination']?['country'] ?? '미설정'}'),
              TextField(
                controller: recipient,
                decoration: const InputDecoration(labelText: '받는 분'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: '연락처'),
              ),
              TextField(
                controller: region,
                decoration: const InputDecoration(labelText: '지역'),
              ),
              TextField(
                controller: detail,
                decoration: const InputDecoration(labelText: '상세주소'),
              ),
              OutlinedButton(
                onPressed: busy ? null : _saveAddress,
                child: const Text('주소 저장'),
              ),
              const Text('입금 후 상품 변경·취소는 불가합니다. 제품명, 색상, 사이즈, 수량을 확인해주세요.'),
            ],
            const SizedBox(height: 16),
            Text('출고 및 송장', style: Theme.of(context).textTheme.titleMedium),
            ...shipments.map(
              (shipment) => Card(
                child: ListTile(
                  title: Text(
                    '${shipment['carrier']} · ${shipment['tracking_number']}',
                  ),
                  subtitle: Text(
                    (shipment['lines'] as List)
                        .map(
                          (line) =>
                              '${line['product_title']} ${line['color']} ${line['size']} ${line['quantity']}개',
                        )
                        .join(' · '),
                  ),
                ),
              ),
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }
}
