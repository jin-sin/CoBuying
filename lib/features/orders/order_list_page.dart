import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
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
              ? ListView(
                  children: const [
                    SizedBox(height: 160),
                    Icon(Icons.receipt_long_outlined,
                        size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Center(child: Text('주문 내역이 없습니다.')),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final order = items[i];
                    final summary = order.items.isEmpty
                        ? ''
                        : order.items.length == 1
                            ? order.items.first.productTitle
                            : '${order.items.first.productTitle} 외 ${order.items.length - 1}건';
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        title: Text(summary),
                        subtitle: Text(
                            '${order.orderNumber} · ${formatDateTime(order.createdAt)}'),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(formatWon(order.totalAmount),
                                style:
                                    const TextStyle(fontWeight: FontWeight.bold)),
                            Text(order.statusLabel,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.primary)),
                          ],
                        ),
                        onTap: () => context.push('/orders/${order.id}'),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
