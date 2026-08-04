import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../maintenance/maintenance.dart';
import '../maintenance/maintenance_providers.dart';
import '../orders/order.dart';
import '../orders/orders_providers.dart';
import '../products/products_providers.dart';
import '../seller/seller_profile.dart';
import '../seller/seller_providers.dart';
import 'refund_queue_tab.dart';

/// 관리자 홈: 셀러 관리 / 상품 관리 / 주문 관리 / 정산 / 환불 탭
class AdminHomePage extends ConsumerWidget {
  const AdminHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('관리자'),
          actions: [
            IconButton(
              tooltip: '점검 시간 설정',
              icon: const Icon(Icons.bedtime_outlined),
              onPressed: () => showDialog(
                context: context,
                builder: (_) => const _MaintenanceSettingsDialog(),
              ),
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: '셀러 관리'),
            Tab(text: '상품 관리'),
            Tab(text: '주문 관리'),
            Tab(text: '정산'),
            Tab(text: '환불'),
          ]),
        ),
        body: const TabBarView(children: [
          _AdminSellersTab(),
          _AdminProductsTab(),
          _AdminOrdersTab(),
          _AdminSettlementTab(),
          AdminRefundsTab(),
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
    ref.invalidate(mySellerProfileProvider); // 본인이 셀러 겸직 시 즉시 반영
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
                          subtitle: Text(
                              '연락처: ${s.contactPhone}\n'
                              '사업자등록번호: ${s.businessNumber.isEmpty ? '(미입력)' : s.businessNumberFormatted}'
                              '${s.onlineSalesNumber.isEmpty ? '' : '\n통신판매업: ${s.onlineSalesNumber}'}'),
                          isThreeLine: true,
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
                                    ref.invalidate(
                                        mySellerProfileProvider);
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
                                    ref.invalidate(
                                        mySellerProfileProvider);
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
                                    ref.invalidate(
                                        mySellerProfileProvider);
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

  Future<void> _updateStatus(BuildContext context, WidgetRef ref,
      String orderId, String status) async {
    try {
      await ref.read(ordersRepositoryProvider).updateStatus(orderId, status);
      ref.invalidate(allOrdersProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('변경에 실패했습니다: $e')));
      }
    }
  }

  Future<void> _cancelOrder(
      BuildContext context, WidgetRef ref, Order order) async {
    final isCardPaid =
        order.paymentMethod == 'card' && order.status != 'pending_payment';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('주문 취소'),
        content: Text(isCardPaid
            ? '이 주문을 취소할까요?\n카드 결제 금액은 토스페이먼츠로 자동 환불되고, 상품 재고는 복원됩니다.'
            : '이 주문을 취소할까요?\n상품 재고는 자동으로 복원됩니다.'),
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
    if (!context.mounted) return;
    try {
      await ref.read(ordersRepositoryProvider).adminCancelOrder(order.id);
      ref.invalidate(allOrdersProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                isCardPaid ? '주문을 취소하고 결제를 환불했습니다.' : '주문을 취소했습니다.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('취소에 실패했습니다: $e')));
      }
    }
  }

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
                      subtitle: item.optionsLabel.isEmpty
                          ? null
                          : Text(item.optionsLabel),
                      trailing: Text(
                          '${item.quantity}개 · ${formatWon(item.lineTotal)}'
                          '${o.status == 'pending_payment' || o.status == 'cancelled' ? '' : ' · ${item.statusLabel}'}'),
                    ),
                  ListTile(
                    dense: true,
                    title: Text('${o.receiverName} · ${o.receiverPhone}'),
                    subtitle: Text('${o.address1} ${o.address2}'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (o.status != 'pending_payment' &&
                            o.status != 'cancelled')
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                                '배송 단계(준비중→배송중→배송 완료)는 셀러가 셀러센터에서 변경합니다.',
                                style: TextStyle(
                                    color: Colors.grey, fontSize: 12)),
                          ),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (o.status == 'pending_payment')
                              FilledButton(
                                onPressed: () => _updateStatus(
                                    context, ref, o.id, 'paid'),
                                child: const Text('입금 확인'),
                              ),
                            if (const {
                              'pending_payment', 'paid', 'preparing',
                            }.contains(o.status))
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        Theme.of(context).colorScheme.error),
                                onPressed: () =>
                                    _cancelOrder(context, ref, o),
                                child: const Text('주문 취소'),
                              ),
                          ],
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

/// 정산 탭: 셀러별 지급액과 정산 계좌를 한눈에.
/// 결제 완료 이후 상태(paid~delivered) 주문 기준 누적 집계이며,
/// 지급 이력 차감은 아직 없다 (v1: 지급 후 기간별로 수동 관리).
class _AdminSettlementTab extends ConsumerWidget {
  const _AdminSettlementTab();

  /// 이체 완료 후 지급 기록 등록 (금액 기본값은 미지급 잔액 전액)
  Future<void> _recordPayout(BuildContext context, WidgetRef ref,
      SellerProfile seller, int balance) async {
    final amountCtrl = TextEditingController(text: '$balance');
    final memoCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${seller.shopName} 지급 기록'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${seller.bankName} ${seller.bankAccount} (${seller.accountHolder})'
                '\n계좌로 이체를 마친 뒤 기록하세요.'),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                  labelText: '지급 금액 (원)', helperText: '기본값: 미지급 잔액 전액'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: memoCtrl,
              decoration: const InputDecoration(labelText: '메모 (선택)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('지급 기록 저장')),
        ],
      ),
    );
    if (confirmed != true) return;
    final amount = int.tryParse(amountCtrl.text.trim()) ?? 0;
    if (amount <= 0 || amount > balance) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('금액은 1원 이상, 미지급 잔액 이하여야 합니다.')));
      }
      return;
    }
    await ref.read(sellerRepositoryProvider).recordPayout(
        sellerId: seller.userId, amount: amount, memo: memoCtrl.text.trim());
    ref.invalidate(allSettlementsProvider);
  }

  Future<void> _showPayoutHistory(
      BuildContext context, WidgetRef ref, SellerProfile seller) async {
    final payouts =
        await ref.read(sellerRepositoryProvider).fetchPayouts(seller.userId);
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${seller.shopName} 지급 내역'),
        content: SizedBox(
          width: 400,
          child: payouts.isEmpty
              ? const Text('지급 내역이 없습니다.')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in payouts)
                      ListTile(
                        dense: true,
                        title: Text(formatWon(p.amount)),
                        subtitle: Text(formatDateTime(p.paidAt) +
                            (p.memo.isEmpty ? '' : ' · ${p.memo}')),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sellers = ref.watch(allSellersProvider);
    final settlements = ref.watch(allSettlementsProvider);

    if (sellers.isLoading || settlements.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (sellers.hasError || settlements.hasError) {
      return Center(
          child: Text('불러오기 실패\n${sellers.error ?? settlements.error}'));
    }

    final sellerList = (sellers.value ?? [])
        .where((s) => s.status == 'approved' || s.status == 'suspended')
        .toList();
    final byId = settlements.value ?? {};
    final totalFees =
        byId.values.fold(0, (sum, s) => sum + s.totalFees);
    final totalBalance =
        byId.values.fold(0, (sum, s) => sum + s.balance);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(allSellersProvider);
        ref.invalidate(allSettlementsProvider);
        await ref.read(allSettlementsProvider.future);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text('플랫폼 수수료 수익'),
                      Text(formatWon(totalFees),
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Column(
                    children: [
                      const Text('미지급 잔액 합계'),
                      Text(formatWon(totalBalance),
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('결제 완료 이후 상태의 주문 기준입니다. '
                '셀러 계좌로 이체한 뒤 [지급 기록]을 남기면 잔액에서 차감됩니다.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
          if (sellerList.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 120),
              child: Center(child: Text('승인된 셀러가 없습니다.')),
            )
          else
            for (final s in sellerList)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(s.shopName,
                              style: Theme.of(context).textTheme.titleMedium),
                          Text(
                            '미지급 ${formatWon(byId[s.userId]?.balance ?? 0)}',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: (byId[s.userId]?.balance ?? 0) > 0
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '주문 ${byId[s.userId]?.orderCount ?? 0}건 · '
                        '판매액 ${formatWon(byId[s.userId]?.grossSales ?? 0)} · '
                        '수수료(${s.commissionRate.toStringAsFixed(1)}%) '
                        '${formatWon(byId[s.userId]?.totalFees ?? 0)} · '
                        '지급 완료 ${formatWon(byId[s.userId]?.totalPaid ?? 0)}',
                        style: TextStyle(color: Colors.grey[700], fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        '입금 계좌: ${s.bankName} ${s.bankAccount} (${s.accountHolder})',
                        style: const TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          FilledButton.tonalIcon(
                            icon: const Icon(Icons.payments_outlined, size: 18),
                            label: const Text('지급 기록'),
                            onPressed: (byId[s.userId]?.balance ?? 0) <= 0
                                ? null
                                : () => _recordPayout(
                                    context, ref, s, byId[s.userId]!.balance),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () =>
                                _showPayoutHistory(context, ref, s),
                            child: const Text('지급 내역'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// 점검 시간(break time) 설정 다이얼로그.
/// NAS 전원 스케줄과 같은 시간대로 맞춰두면 서버가 꺼진 동안
/// 앱이 안내 화면을 띄운다 (앱은 마지막 설정을 캐시해 판단).
class _MaintenanceSettingsDialog extends ConsumerStatefulWidget {
  const _MaintenanceSettingsDialog();

  @override
  ConsumerState<_MaintenanceSettingsDialog> createState() =>
      _MaintenanceSettingsDialogState();
}

class _MaintenanceSettingsDialogState
    extends ConsumerState<_MaintenanceSettingsDialog> {
  bool _enabled = true;
  TimeOfDay _start = const TimeOfDay(hour: 2, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 8, minute: 0);
  late final TextEditingController _message;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _message = TextEditingController();
    ref.read(maintenanceConfigProvider.future).then((config) {
      if (!mounted) return;
      setState(() {
        _enabled = config.enabled;
        _start = _parse(config.start) ?? _start;
        _end = _parse(config.end) ?? _end;
        _message.text = config.message;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  TimeOfDay? _parse(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _start : _end,
    );
    if (picked == null) return;
    setState(() => isStart ? _start = picked : _end = picked);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(maintenanceRepositoryProvider).save(MaintenanceConfig(
            enabled: _enabled,
            start: _fmt(_start),
            end: _fmt(_end),
            message: _message.text.trim(),
          ));
      ref.invalidate(maintenanceConfigProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('저장에 실패했습니다: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('점검 시간 설정'),
      content: !_loaded
          ? const SizedBox(
              height: 80, child: Center(child: CircularProgressIndicator()))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('점검 안내 사용'),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                Row(
                  children: [
                    const Text('시작'),
                    const Spacer(),
                    TextButton(
                        onPressed: () => _pick(true),
                        child: Text(_fmt(_start))),
                  ],
                ),
                Row(
                  children: [
                    const Text('종료'),
                    const Spacer(),
                    TextButton(
                        onPressed: () => _pick(false),
                        child: Text(_fmt(_end))),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _message,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '안내 문구',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'NAS 전원 스케줄과 같은 시간대로 맞춰 주세요.\n'
                  '앱은 마지막 설정을 저장해 두고 서버가 꺼진 동안에도 안내를 띄웁니다.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(
          onPressed: _saving || !_loaded ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('저장'),
        ),
      ],
    );
  }
}
