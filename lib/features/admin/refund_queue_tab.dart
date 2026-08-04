import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_providers.dart';

/// 환불 대기 한 건 (`refund_requests`).
class RefundRequest {
  const RefundRequest({
    required this.id,
    required this.orderId,
    required this.amount,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.orderNumber = '',
    this.receiverName = '',
    this.depositorName = '',
  });

  final String id;
  final String orderId;
  final int amount;
  final String reason;
  final String status; // pending | done
  final DateTime createdAt;
  final String orderNumber;
  final String receiverName;
  final String depositorName;

  bool get isPending => status == 'pending';

  factory RefundRequest.fromJson(Map<String, dynamic> json) {
    final order = json['orders'] as Map<String, dynamic>?;
    return RefundRequest(
      id: json['id'] as String,
      orderId: json['order_id'] as String,
      amount: (json['amount'] as num).toInt(),
      reason: json['reason'] as String? ?? '',
      status: json['status'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      orderNumber: order?['order_number'] as String? ?? '',
      receiverName: order?['receiver_name'] as String? ?? '',
      depositorName: order?['depositor_name'] as String? ?? '',
    );
  }
}

final refundRequestsProvider =
    FutureProvider.autoDispose<List<RefundRequest>>((ref) async {
  final rows = await ref
      .watch(supabaseClientProvider)
      .from('refund_requests')
      .select('*, orders(order_number, receiver_name, depositor_name)')
      .order('status')
      .order('created_at', ascending: false);
  return rows.map(RefundRequest.fromJson).toList();
});

/// 관리자 환불 대기 목록.
///
/// 공동구매가 목표 수량에 못 미쳐 취소되면 여기에 쌓인다. 지금 운영은
/// 무통장입금만 켜져 있어 자동 환불이 불가능하므로, 관리자가 계좌로 이체한 뒤
/// 완료 처리하는 흐름이다. 이 화면이 없으면 환불이 그냥 누락된다.
class AdminRefundsTab extends ConsumerWidget {
  const AdminRefundsTab({super.key});

  Future<void> _complete(
      BuildContext context, WidgetRef ref, RefundRequest r) async {
    final memo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('환불 완료 처리'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${r.orderNumber} · ${formatWon(r.amount)}'),
            const SizedBox(height: 4),
            Text(
              '계좌 이체를 마친 뒤에 눌러 주세요. 되돌릴 수 없습니다.',
              style: const TextStyle(fontSize: 12, color: mutedText),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: memo,
              decoration: const InputDecoration(
                  labelText: '메모 (선택)', hintText: '이체 계좌·일시 등'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('완료 처리')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(supabaseClientProvider).rpc('complete_refund',
          params: {'p_id': r.id, 'p_memo': memo.text.trim()});
      ref.invalidate(refundRequestsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('처리에 실패했습니다: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refunds = ref.watch(refundRequestsProvider);

    return refunds.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.receipt_long_outlined,
            message: '환불할 건이 없습니다.',
          );
        }
        final pending = items.where((r) => r.isPending).toList();
        return RefreshIndicator(
          onRefresh: () => ref.refresh(refundRequestsProvider.future),
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    pending.isEmpty
                        ? '대기 중인 환불이 없습니다.'
                        : '이체할 건 ${pending.length}건 · '
                            '${formatWon(pending.fold(0, (a, r) => a + r.amount))}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                );
              }
              final r = items[index - 1];
              return SoftCard(
                margin: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(r.orderNumber,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                        ),
                        StatusPill(
                          label: r.isPending ? '이체 대기' : '완료',
                          status: r.isPending ? 'pending_payment' : 'delivered',
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(r.reason,
                        style: const TextStyle(
                            fontSize: 12.5, color: mutedText)),
                    const SizedBox(height: 8),
                    Text(formatWon(r.amount),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      '주문자 ${r.receiverName}'
                      '${r.depositorName.isEmpty ? '' : ' · 입금자 ${r.depositorName}'}'
                      ' · ${formatDateTime(r.createdAt)}',
                      style:
                          const TextStyle(fontSize: 12, color: mutedText),
                    ),
                    if (r.isPending) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          onPressed: () => _complete(context, ref, r),
                          child: const Text('환불 완료 처리'),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
