import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:postal_ko/postal_ko.dart';

import '../../core/env.dart';
import '../../core/formatters.dart';
import '../cart/cart_providers.dart';
import 'orders_providers.dart';

class CheckoutPage extends ConsumerStatefulWidget {
  const CheckoutPage({super.key});

  @override
  ConsumerState<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends ConsumerState<CheckoutPage> {
  final _formKey = GlobalKey<FormState>();
  final _receiverName = TextEditingController();
  final _receiverPhone = TextEditingController();
  final _postcode = TextEditingController();
  final _address1 = TextEditingController();
  final _address2 = TextEditingController();
  final _memo = TextEditingController();
  final _depositorName = TextEditingController();

  String _paymentMethod = 'bank_transfer';
  bool _submitting = false;

  @override
  void dispose() {
    for (final c in [
      _receiverName, _receiverPhone, _postcode,
      _address1, _address2, _memo, _depositorName,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// 카카오 우편번호 서비스로 주소 검색 (postal_ko)
  Future<void> _searchAddress() async {
    final result = await Navigator.of(context).push<Kpostal>(
      MaterialPageRoute(builder: (_) => KpostalView()),
    );
    if (result == null) return;
    setState(() {
      _postcode.text = result.postCode;
      _address1.text =
          result.roadAddress.isNotEmpty ? result.roadAddress : result.address;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final items = (ref.read(cartProvider).value ?? [])
        .where((i) => i.isOrderable)
        .map((i) => (productId: i.productId, quantity: i.quantity))
        .toList();
    if (items.isEmpty) return;

    setState(() => _submitting = true);
    try {
      final orderId = await ref.read(ordersRepositoryProvider).createOrder(
            paymentMethod: _paymentMethod,
            receiverName: _receiverName.text.trim(),
            receiverPhone: _receiverPhone.text.trim(),
            postcode: _postcode.text.trim(),
            address1: _address1.text.trim(),
            address2: _address2.text.trim(),
            memo: _memo.text.trim(),
            depositorName: _paymentMethod == 'bank_transfer'
                ? _depositorName.text.trim()
                : null,
            items: items,
          );

      // TODO(PG): 카드결제 선택 시 여기서 토스페이먼츠 등 PG 결제창 호출 후
      // 결제 승인 콜백에서 주문 상태를 'paid'로 변경하는 흐름으로 확장.

      ref.invalidate(cartProvider);
      ref.invalidate(myOrdersProvider);
      if (!mounted) return;
      context.go('/orders/$orderId?placed=1');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('주문에 실패했습니다: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider).value ?? [];
    final orderable = cart.where((i) => i.isOrderable).toList();
    final total = ref.watch(cartTotalProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('주문/결제')),
      body: orderable.isEmpty
          ? const Center(child: Text('주문할 상품이 없습니다.'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text('주문 상품', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Card(
                        child: Column(
                          children: [
                            for (final item in orderable)
                              ListTile(
                                dense: true,
                                title: Text(item.product?.title ?? ''),
                                trailing: Text(
                                    '${item.quantity}개 · ${formatWon(item.lineTotal)}'),
                              ),
                            const Divider(height: 1),
                            ListTile(
                              title: const Text('합계',
                                  style: TextStyle(fontWeight: FontWeight.bold)),
                              trailing: Text(formatWon(total),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 16)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text('배송 정보', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _receiverName,
                        decoration: const InputDecoration(labelText: '받는 사람 *'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '받는 사람을 입력하세요' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _receiverPhone,
                        decoration: const InputDecoration(
                            labelText: '연락처 *', hintText: '숫자만 입력'),
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '연락처를 입력하세요' : null,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _postcode,
                              readOnly: true,
                              decoration: const InputDecoration(
                                  labelText: '우편번호', hintText: '주소 검색을 눌러주세요'),
                              onTap: _searchAddress,
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 52,
                            child: OutlinedButton.icon(
                              onPressed: _searchAddress,
                              icon: const Icon(Icons.search),
                              label: const Text('주소 검색'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _address1,
                        readOnly: true,
                        decoration: const InputDecoration(labelText: '주소 *'),
                        onTap: _searchAddress,
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '주소를 검색해 주세요' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _address2,
                        decoration: const InputDecoration(labelText: '상세 주소'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _memo,
                        decoration:
                            const InputDecoration(labelText: '배송 메모 (선택)'),
                      ),
                      const SizedBox(height: 24),
                      Text('결제 수단', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      RadioGroup<String>(
                        groupValue: _paymentMethod,
                        onChanged: (v) =>
                            setState(() => _paymentMethod = v ?? 'bank_transfer'),
                        child: Column(
                          children: [
                            const RadioListTile<String>(
                              value: 'bank_transfer',
                              title: Text('무통장입금'),
                            ),
                            if (_paymentMethod == 'bank_transfer')
                              Padding(
                                padding: const EdgeInsets.only(left: 16, bottom: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('입금 계좌: ${Env.bankAccountInfo}',
                                        style: const TextStyle(color: Colors.grey)),
                                    const SizedBox(height: 8),
                                    TextFormField(
                                      controller: _depositorName,
                                      decoration: const InputDecoration(
                                          labelText: '입금자명 *'),
                                      validator: (v) =>
                                          _paymentMethod == 'bank_transfer' &&
                                                  (v == null || v.trim().isEmpty)
                                              ? '입금자명을 입력하세요'
                                              : null,
                                    ),
                                  ],
                                ),
                              ),
                            const RadioListTile<String>(
                              value: 'card',
                              title: Text('카드결제 (PG 연동 준비중)'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : Text('${formatWon(total)} 결제하기'),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
