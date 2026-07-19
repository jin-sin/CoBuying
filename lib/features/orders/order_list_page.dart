import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'orders_providers.dart';

class OrderListPage extends ConsumerWidget {
  const OrderListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(myOrdersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('주문 내역'),
        // 주문 완료 화면에서 넘어오는 등 스택이 비어 있으면 홈으로 나갈 수단을 준다.
        leading: context.canPop()
            ? null
            : IconButton(
                icon: const Icon(Icons.home_outlined),
                tooltip: '홈으로',
                onPressed: () => context.go('/'),
              ),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(myOrdersProvider.future),
        child: orders.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('주문 내역을 불러오지 못했습니다.\n$e')),
          data: (items) => items.isEmpty
              ? const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  message: '주문 내역이 없습니다.',
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final order = items[i];
                        final summary = order.items.isEmpty
                            ? ''
                            : order.items.length == 1
                                ? order.items.first.productTitle
                                : '${order.items.first.productTitle} 외 ${order.items.length - 1}건';
                        return SoftCard(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          onTap: () => context.push('/orders/${order.id}'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  StatusPill(
                                      label: order.statusLabel,
                                      status: order.status),
                                  const Spacer(),
                                  Text(formatDateTime(order.createdAt),
                                      style: const TextStyle(
                                          fontSize: 11.5, color: mutedText)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(summary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Text(order.orderNumber,
                                      style: const TextStyle(
                                          fontSize: 11.5, color: mutedText)),
                                  const Spacer(),
                                  Text(formatWon(order.totalAmount),
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800)),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
