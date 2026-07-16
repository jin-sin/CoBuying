import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../orders/orders_providers.dart';
import '../products/products_providers.dart';
import '../seller/seller_providers.dart';

/// 관리자 홈: 셀러 관리 / 상품 관리 / 주문 관리 탭
class AdminHomePage extends ConsumerWidget {
  const AdminHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('관리자'),
          bottom: const TabBar(tabs: [
            Tab(text: '셀러 관리'),
            Tab(text: '상품 관리'),
            Tab(text: '주문 관리'),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => context.push('/admin/product/new'),
          icon: const Icon(Icons.add),
          label: const Text('상품 등록'),
        ),
        body: const TabBarView(children: [
          _AdminSellersTab(),
          _AdminProductsTab(),
          _AdminOrdersTab(),
        ]),
      ),
    );
  }
}

class _AdminSellersTab extends ConsumerWidget {
  const _AdminSellersTab();

  Future<void> _editCommission(
      BuildContext context, WidgetRef ref, String userId, double current) async {
    final controller = TextEditingController(text: current.toStringAsFixed(1));
    final rate = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('수수료율 변경 (%)'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: '%'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text)),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (rate == null || rate < 0 || rate > 100) return;
    await ref.read(sellerRepositoryProvider).updateCommissionRate(userId, rate);
    ref.invalidate(allSellersProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sellers = ref.watch(allSellersProvider);

    return sellers.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
      data: (items) => RefreshIndicator(
        onRefresh: () => ref.refresh(allSellersProvider.future),
        child: items.isEmpty
            ? ListView(children: const [
                SizedBox(height: 160),
                Center(child: Text('입점 신청한 셀러가 없습니다.')),
              ])
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final s = items[i];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ExpansionTile(
                      title: Text(s.shopName),
                      subtitle: Text(
                          '${s.statusLabel} · 수수료 ${s.commissionRate.toStringAsFixed(1)}%'),
                      children: [
                        ListTile(
                          dense: true,
                          title: Text(
                              '정산: ${s.bankName} ${s.bankAccount} (${s.accountHolder})'),
                          subtitle: Text('연락처: ${s.contactPhone}'),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            spacing: 8,
                            children: [
                              if (s.status != 'approved')
                                FilledButton(
                                  onPressed: () async {
                                    await ref
                                        .read(sellerRepositoryProvider)
                                        .updateSellerStatus(
                                            s.userId, 'approved');
                                    ref.invalidate(allSellersProvider);
                                  },
                                  child: const Text('승인'),
                                ),
                              if (s.status == 'pending')
                                OutlinedButton(
                                  onPressed: () async {
                                    await ref
                                        .read(sellerRepositoryProvider)
                                        .updateSellerStatus(
                                            s.userId, 'rejected');
                                    ref.invalidate(allSellersProvider);
                                  },
                                  child: const Text('반려'),
                                ),
                              if (s.status == 'approved')
                                OutlinedButton(
                                  onPressed: () async {
                                    await ref
                                        .read(sellerRepositoryProvider)
                                        .updateSellerStatus(
                                            s.userId, 'suspended');
                                    ref.invalidate(allSellersProvider);
                                  },
                                  child: const Text('이용 정지'),
                                ),
                              OutlinedButton(
                                onPressed: () => _editCommission(
                                    context, ref, s.userId, s.commissionRate),
                                child: const Text('수수료율 변경'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _AdminProductsTab extends ConsumerWidget {
  const _AdminProductsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(allProductsProvider);

    return products.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
      data: (items) => RefreshIndicator(
        onRefresh: () => ref.refresh(allProductsProvider.future),
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final p = items[i];
            final statusLabel = switch (p.status) {
              'active' => p.isExpired ? '기한 만료' : '판매중',
              'closed' => '마감',
              'hidden' => '숨김',
              _ => p.status,
            };
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(p.title),
                subtitle: Text(
                    '${p.shopName.isNotEmpty ? '${p.shopName} · ' : ''}${formatWon(p.price)} · 재고 ${p.stock} · ~${formatDateTime(p.endsAt)} · $statusLabel'),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) async {
                    final repo = ref.read(productsRepositoryProvider);
                    switch (action) {
                      case 'edit':
                        context.push('/admin/product/${p.id}');
                      case 'close':
                        await repo.updateStatus(p.id, 'closed');
                        ref.invalidate(allProductsProvider);
                      case 'reopen':
                        await repo.updateStatus(p.id, 'active');
                        ref.invalidate(allProductsProvider);
                      case 'hide':
                        await repo.updateStatus(p.id, 'hidden');
                        ref.invalidate(allProductsProvider);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('수정')),
                    if (p.status == 'active')
                      const PopupMenuItem(value: 'close', child: Text('판매 마감'))
                    else
                      const PopupMenuItem(value: 'reopen', child: Text('판매 재개')),
                    const PopupMenuItem(value: 'hide', child: Text('숨김')),
                  ],
                ),
                onTap: () => context.push('/admin/product/${p.id}'),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AdminOrdersTab extends ConsumerWidget {
  const _AdminOrdersTab();

  static const _statusFlow = [
    'pending_payment', 'paid', 'preparing', 'shipped', 'delivered', 'cancelled',
  ];
  static const _statusLabels = {
    'pending_payment': '입금 대기',
    'paid': '결제 완료',
    'preparing': '상품 준비중',
    'shipped': '배송중',
    'delivered': '배송 완료',
    'cancelled': '취소됨',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(allOrdersProvider);

    return orders.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
      data: (items) => RefreshIndicator(
        onRefresh: () => ref.refresh(allOrdersProvider.future),
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final o = items[i];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                title: Text('${o.orderNumber} · ${formatWon(o.totalAmount)}'),
                subtitle: Text(
                    '${formatDateTime(o.createdAt)} · ${o.paymentMethodLabel}'
                    '${o.depositorName != null ? ' (입금자: ${o.depositorName})' : ''}'),
                trailing: Text(o.statusLabel,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600)),
                children: [
                  for (final item in o.items)
                    ListTile(
                      dense: true,
                      title: Text(item.productTitle),
                      trailing:
                          Text('${item.quantity}개 · ${formatWon(item.lineTotal)}'),
                    ),
                  ListTile(
                    dense: true,
                    title: Text('${o.receiverName} · ${o.receiverPhone}'),
                    subtitle: Text('${o.address1} ${o.address2}'),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Text('상태 변경: '),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: o.status,
                          items: [
                            for (final s in _statusFlow)
                              DropdownMenuItem(
                                  value: s, child: Text(_statusLabels[s]!)),
                          ],
                          onChanged: (s) async {
                            if (s == null || s == o.status) return;
                            await ref
                                .read(ordersRepositoryProvider)
                                .updateStatus(o.id, s);
                            ref.invalidate(allOrdersProvider);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
