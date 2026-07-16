import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../core/formatters.dart';
import 'order.dart';
import 'orders_providers.dart';

class OrderDetailPage extends ConsumerWidget {
  const OrderDetailPage({
    super.key,
    required this.orderId,
    this.justPlaced = false,
  });

  final String orderId;

  /// 주문 직후 진입 시 완료 안내 배너 표시
  final bool justPlaced;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderAsync = ref.watch(orderProvider(orderId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('주문 상세'),
        // 주문 완료 직후처럼 스택이 비어 있으면 홈으로 나갈 수단을 준다.
        leading: context.canPop()
            ? null
            : IconButton(
                icon: const Icon(Icons.home_outlined),
                tooltip: '홈으로',
                onPressed: () => context.go('/'),
              ),
      ),
      body: orderAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('주문을 불러오지 못했습니다.\n$e')),
        data: (order) {
          if (order == null) {
            return const Center(child: Text('존재하지 않는 주문입니다.'));
          }
          return _OrderDetail(order: order, justPlaced: justPlaced);
        },
      ),
    );
  }
}

class _OrderDetail extends StatelessWidget {
  const _OrderDetail({required this.order, required this.justPlaced});

  final Order order;
  final bool justPlaced;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (justPlaced)
              Card(
                color: theme.colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          order.paymentMethod == 'bank_transfer'
                              ? '주문이 접수되었습니다.\n아래 계좌로 입금해 주시면 확인 후 처리됩니다.\n${Env.bankAccountInfo}'
                              : '주문이 접수되었습니다.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            _Section(
              title: '주문 정보',
              children: [
                _row('주문번호', order.orderNumber),
                _row('주문일시', formatDateTime(order.createdAt)),
                _row('상태', order.statusLabel),
                _row('결제수단', order.paymentMethodLabel),
                if (order.paymentMethod == 'bank_transfer') ...[
                  _row('입금자명', order.depositorName ?? '-'),
                  if (order.status == 'pending_payment')
                    _row('입금계좌', Env.bankAccountInfo),
                ],
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: '주문 상품',
              children: [
                for (final item in order.items)
                  _row('${item.productTitle} × ${item.quantity}',
                      formatWon(item.lineTotal)),
                const Divider(),
                _row('총 결제금액', formatWon(order.totalAmount), bold: true),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: '배송 정보',
              children: [
                _row('받는 사람', order.receiverName),
                _row('연락처', order.receiverPhone),
                _row('주소',
                    '${order.postcode.isNotEmpty ? '(${order.postcode}) ' : ''}${order.address1} ${order.address2}'),
                if (order.memo.isNotEmpty) _row('배송 메모', order.memo),
              ],
            ),
            if (justPlaced) ...[
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.go('/'),
                child: const Text('쇼핑 계속하기'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => context.go('/orders'),
                child: const Text('주문 내역 보기'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    final style = TextStyle(fontWeight: bold ? FontWeight.bold : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 16),
          Flexible(child: Text(value, style: style, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}
