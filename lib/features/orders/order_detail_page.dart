import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/env.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../core/formatters.dart';
import '../reviews/review_form_dialog.dart';
import '../reviews/reviews_providers.dart';
import 'couriers.dart';
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
    final isCardPaid = order.status == 'paid' && order.paymentMethod == 'card';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('주문 취소'),
        content: Text(isCardPaid
            ? '이 주문을 취소할까요?\n결제 금액은 카드사 절차에 따라 3~5영업일 내 환불됩니다.'
            : '이 주문을 취소할까요?\n취소한 주문은 되돌릴 수 없습니다.'),
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

  /// 결제창을 닫고 나온 카드 주문의 재결제.
  /// 웹: 성공 시 /payment/success로 리다이렉트. 앱: 반환값으로 여기서 승인.
  Future<void> _retryCardPayment(BuildContext context, WidgetRef ref) async {
    final firstTitle =
        order.items.isNotEmpty ? order.items.first.productTitle : '상품';
    try {
      final result = await requestCardPayment(
        context: context,
        orderNumber: order.orderNumber,
        orderName: order.items.length > 1
            ? '$firstTitle 외 ${order.items.length - 1}건'
            : firstTitle,
        amount: order.totalAmount,
        customerName: order.receiverName,
      );
      if (result != null) {
        await ref.read(ordersRepositoryProvider).confirmCardPayment(
              orderNumber: result.orderNumber,
              paymentKey: result.paymentKey,
              amount: result.amount,
            );
        ref.invalidate(orderProvider(order.id));
        ref.invalidate(myOrdersProvider);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('결제가 완료되었습니다.')));
        }
      }
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

  Future<void> _writeReview(
      BuildContext context, WidgetRef ref, OrderItem item) async {
    final saved = await showReviewFormDialog(
      context,
      productId: item.productId,
      orderItemId: item.id,
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('리뷰가 등록되었습니다.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 배송 완료된 아이템의 리뷰 작성 여부 (버튼 표시용)
    final reviewedItemIds =
        ref.watch(myReviewedItemIdsProvider).value ?? const <String>{};

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (justPlaced)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3EC),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        color: Color(0xFFC24A1D)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        order.paymentMethod == 'bank_transfer'
                            ? '주문이 접수되었습니다.\n24시간 내에 아래 계좌로 입금해 주세요. 미입금 시 주문이 자동 취소됩니다.\n${Env.bankAccountInfo}'
                            : '주문이 접수되었습니다.',
                        style: const TextStyle(height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            _Section(
              title: '주문 정보',
              children: [
                _row('주문번호', order.orderNumber),
                _row('주문일시', formatDateTime(order.createdAt)),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Expanded(child: Text('상태')),
                      StatusPill(
                          label: order.statusLabel, status: order.status),
                    ],
                  ),
                ),
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
                for (final item in order.items) ...[
                  _row(
                      '${item.productTitle}'
                      '${item.optionsLabel.isEmpty ? '' : ' (${item.optionsLabel})'}'
                      ' × ${item.quantity}'
                      // 결제 완료 이후에는 상품별 배송 상태 표시 (셀러별로 다를 수 있음)
                      '${order.status == 'pending_payment' || order.status == 'cancelled' ? '' : ' · ${item.statusLabel}'}',
                      formatWon(item.lineTotal)),
                  // 운송장 (셀러가 발송 처리 시 입력)
                  if (order.status != 'pending_payment' &&
                      order.status != 'cancelled' &&
                      item.hasTracking)
                    Row(
                      children: [
                        Icon(Icons.local_shipping_outlined,
                            size: 16, color: Colors.grey[600]),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${item.courier} ${item.trackingNumber}',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: Colors.grey[600]),
                          ),
                        ),
                        TextButton(
                          onPressed: () => launchUrl(
                            courierTrackingUrl(
                                item.courier, item.trackingNumber),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const Text('배송조회'),
                        ),
                      ],
                    ),
                  // 배송 완료된 상품만 리뷰 작성 가능 (아이템당 1건)
                  if (order.status != 'pending_payment' &&
                      order.status != 'cancelled' &&
                      item.status == 'delivered' &&
                      item.id != null &&
                      item.productId != null)
                    Align(
                      alignment: Alignment.centerRight,
                      child: reviewedItemIds.contains(item.id)
                          ? TextButton.icon(
                              onPressed: null,
                              icon: const Icon(Icons.check, size: 16),
                              label: const Text('리뷰 작성 완료'),
                            )
                          : TextButton.icon(
                              onPressed: () =>
                                  _writeReview(context, ref, item),
                              icon:
                                  const Icon(Icons.rate_review_outlined, size: 16),
                              label: const Text('리뷰 작성'),
                            ),
                    ),
                ],
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
                onPressed: () => _retryCardPayment(context, ref),
                label: const Text('카드 결제하기'),
              ),
              const SizedBox(height: 4),
              Text(
                '1시간 내 결제하지 않으면 주문이 자동 취소됩니다.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            // 결제 전, 또는 카드 결제 완료(셀러 배송 준비 시작 전)까지 취소 가능
            if (order.status == 'pending_payment' ||
                (order.status == 'paid' && order.paymentMethod == 'card')) ...[
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
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: mutedText)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
