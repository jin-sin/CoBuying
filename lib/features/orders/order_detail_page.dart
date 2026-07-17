import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/env.dart';
import '../../core/formatters.dart';
import 'order.dart';
import 'orders_providers.dart';
import 'toss_payment.dart';

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

class _OrderDetail extends ConsumerWidget {
  const _OrderDetail({required this.order, required this.justPlaced});

  final Order order;
  final bool justPlaced;

  Future<void> _cancelOrder(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('주문 취소'),
        content: const Text('이 주문을 취소할까요?\n취소한 주문은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('아니요')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('주문 취소')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(ordersRepositoryProvider).cancelMyOrder(order.id);
      ref.invalidate(orderProvider(order.id));
      ref.invalidate(myOrdersProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('주문이 취소되었습니다.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('취소에 실패했습니다: $e')));
      }
    }
  }

  /// 결제창을 닫고 나온 카드 주문의 재결제. 성공 시 페이지가
  /// /payment/success로 리다이렉트되므로 이후 코드는 취소 시에만 실행된다.
  Future<void> _retryCardPayment(BuildContext context) async {
    final firstTitle =
        order.items.isNotEmpty ? order.items.first.productTitle : '상품';
    try {
      await requestCardPayment(
        orderNumber: order.orderNumber,
        orderName: order.items.length > 1
            ? '$firstTitle 외 ${order.items.length - 1}건'
            : firstTitle,
        amount: order.totalAmount,
        customerName: order.receiverName,
      );
    } on PaymentCancelled {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('결제를 취소했어요.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('결제에 실패했습니다: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                              ? '주문이 접수되었습니다.\n24시간 내에 아래 계좌로 입금해 주세요. 미입금 시 주문이 자동 취소됩니다.\n${Env.bankAccountInfo}'
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
                  _row(
                      '${item.productTitle} × ${item.quantity}'
                      // 결제 완료 이후에는 상품별 배송 상태 표시 (셀러별로 다를 수 있음)
                      '${order.status == 'pending_payment' || order.status == 'cancelled' ? '' : ' · ${item.statusLabel}'}',
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
            if (order.status == 'pending_payment' &&
                order.paymentMethod == 'card' &&
                cardPaymentSupported) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.credit_card),
                onPressed: () => _retryCardPayment(context),
                label: const Text('카드 결제하기'),
              ),
              const SizedBox(height: 4),
              Text(
                '1시간 내 결제하지 않으면 주문이 자동 취소됩니다.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (order.status == 'pending_payment') ...[
              SizedBox(height: justPlaced ? 8 : 24),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error),
                onPressed: () => _cancelOrder(context, ref),
                child: const Text('주문 취소'),
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
