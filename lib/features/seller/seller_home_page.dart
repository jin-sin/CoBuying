import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../products/products_providers.dart';
import 'seller_apply_page.dart';
import 'seller_profile.dart';
import 'seller_providers.dart';

/// 셀러센터.
/// - 셀러 미신청: 입점 신청 폼
/// - 승인 대기/반려: 상태 안내 + 정보 수정
/// - 승인됨: 내 상품 / 판매 내역 / 정산·계좌 탭
class SellerHomePage extends ConsumerWidget {
  const SellerHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(mySellerProfileProvider);

    return profileAsync.when(
      loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('셀러센터')),
        body: Center(child: Text('불러오기 실패\n$e')),
      ),
      data: (profile) {
        if (profile == null) {
          return const SellerApplyPage();
        }
        if (!profile.isApproved) {
          return _PendingView(profile: profile);
        }
        return _SellerDashboard(profile: profile);
      },
    );
  }
}

class _PendingView extends ConsumerWidget {
  const _PendingView({required this.profile});

  final SellerProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('셀러센터')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  profile.status == 'pending'
                      ? Icons.hourglass_top
                      : Icons.block,
                  size: 64,
                  color: Colors.grey,
                ),
                const SizedBox(height: 16),
                Text('입점 신청 상태: ${profile.statusLabel}',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  profile.status == 'pending'
                      ? '관리자 승인 후 상품을 등록할 수 있습니다.'
                      : '자세한 내용은 운영자에게 문의해 주세요.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => SellerApplyPage(existing: profile)),
                  ),
                  child: const Text('신청 정보 수정'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SellerDashboard extends ConsumerWidget {
  const _SellerDashboard({required this.profile});

  final SellerProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('셀러센터 · ${profile.shopName}'),
          bottom: const TabBar(tabs: [
            Tab(text: '내 상품'),
            Tab(text: '판매 내역'),
            Tab(text: '정산·계좌'),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => context.push('/seller/product/new'),
          icon: const Icon(Icons.add),
          label: const Text('상품 등록'),
        ),
        body: TabBarView(children: [
          const _MyProductsTab(),
          const _MySalesTab(),
          _SettlementTab(profile: profile),
        ]),
      ),
    );
  }
}

class _MyProductsTab extends ConsumerWidget {
  const _MyProductsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(myProductsProvider);

    return products.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
      data: (items) => RefreshIndicator(
        onRefresh: () => ref.refresh(myProductsProvider.future),
        child: items.isEmpty
            ? ListView(children: const [
                SizedBox(height: 160),
                Center(child: Text('등록한 상품이 없습니다.\n오른쪽 아래 버튼으로 등록해 보세요.',
                    textAlign: TextAlign.center)),
              ])
            : ListView.builder(
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
                          '${formatWon(p.price)} · 재고 ${p.stock} · ~${formatDateTime(p.endsAt)} · $statusLabel'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/seller/product/${p.id}'),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _MySalesTab extends ConsumerWidget {
  const _MySalesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(mySalesProvider);

    return sales.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
      data: (items) => RefreshIndicator(
        onRefresh: () => ref.refresh(mySalesProvider.future),
        child: items.isEmpty
            ? ListView(children: const [
                SizedBox(height: 160),
                Center(child: Text('아직 판매 내역이 없습니다.')),
              ])
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final (item, order) = items[i];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text('${item.productTitle} × ${item.quantity}'),
                      subtitle: Text(
                          '${order.orderNumber} · ${formatDateTime(order.createdAt)}\n'
                          '${order.receiverName} · ${order.address1} ${order.address2}'),
                      isThreeLine: true,
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(formatWon(item.sellerPayout),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          Text(order.statusLabel,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary)),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _SettlementTab extends ConsumerWidget {
  const _SettlementTab({required this.profile});

  final SellerProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settlement = ref.watch(mySettlementProvider);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        settlement.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('정산 정보를 불러오지 못했습니다.\n$e'),
          data: (s) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('정산 요약 (결제 완료 주문 기준)',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  _row(context, '주문 수', '${s.orderCount}건'),
                  _row(context, '총 판매액', formatWon(s.grossSales)),
                  _row(context,
                      '플랫폼 수수료 (${profile.commissionRate.toStringAsFixed(1)}%)',
                      '-${formatWon(s.totalFees)}'),
                  const Divider(),
                  _row(context, '지급 예정액', formatWon(s.netPayout), bold: true),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('정산 계좌', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                _row(context, '은행', profile.bankName),
                _row(context, '계좌번호', profile.bankAccount),
                _row(context, '예금주', profile.accountHolder),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => SellerApplyPage(existing: profile)),
                  ),
                  child: const Text('상호·계좌 정보 수정'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {bool bold = false}) {
    final style = TextStyle(fontWeight: bold ? FontWeight.bold : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label, style: style), Text(value, style: style)],
      ),
    );
  }
}
