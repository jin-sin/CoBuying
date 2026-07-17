import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../orders/order.dart';
import 'seller_providers.dart';

/// 택배 발송용 배송 목록 — 미발송(준비중) 주문을 주문 단위로 묶어
/// 받는사람·연락처·주소를 표로 보여준다. "표 복사"로 탭 구분 텍스트를
/// 복사하면 엑셀·스프레드시트에 그대로 붙여넣을 수 있다.
class ShippingListPage extends ConsumerWidget {
  const ShippingListPage({super.key});

  /// 미발송 항목을 주문 단위로 묶는다. (한 주문 = 운송장 하나)
  List<({Order order, List<OrderItem> items})> _pendingShipments(
      List<(OrderItem, Order)> sales) {
    final byOrder = <String, ({Order order, List<OrderItem> items})>{};
    for (final (item, order) in sales) {
      // 결제 완료 이후 주문에서 아직 발송 전(준비중)인 항목만
      if (const {'pending_payment', 'cancelled'}.contains(order.status)) {
        continue;
      }
      if (item.status != 'preparing') continue;
      byOrder
          .putIfAbsent(order.id, () => (order: order, items: []))
          .items
          .add(item);
    }
    final result = byOrder.values.toList()
      ..sort((a, b) => a.order.createdAt.compareTo(b.order.createdAt));
    return result;
  }

  String _itemsSummary(List<OrderItem> items) => items
      .map((i) =>
          '${i.productTitle}${i.optionsLabel.isEmpty ? '' : '(${i.optionsLabel})'} ×${i.quantity}')
      .join(', ');

  String _address(Order o) =>
      '${o.postcode.isNotEmpty ? '(${o.postcode}) ' : ''}${o.address1} ${o.address2}'
          .trim();

  Future<void> _copyTable(BuildContext context,
      List<({Order order, List<OrderItem> items})> shipments) async {
    final buffer = StringBuffer('받는사람\t연락처\t우편번호\t주소\t상품\t배송메모\t주문번호\n');
    for (final s in shipments) {
      final o = s.order;
      buffer.writeln([
        o.receiverName,
        o.receiverPhone,
        o.postcode,
        '${o.address1} ${o.address2}'.trim(),
        _itemsSummary(s.items),
        o.memo,
        o.orderNumber,
      ].join('\t'));
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('표가 복사되었습니다. 엑셀이나 스프레드시트에 붙여넣으세요.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(mySalesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('배송 목록 (미발송)')),
      body: sales.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
        data: (items) {
          final shipments = _pendingShipments(items);
          if (shipments.isEmpty) {
            return const Center(child: Text('발송할 주문이 없습니다.'));
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Text('${shipments.length}건',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.copy_all_outlined, size: 18),
                      label: const Text('표 복사'),
                      onPressed: () => _copyTable(context, shipments),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingTextStyle: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                      dataTextStyle: const TextStyle(fontSize: 13),
                      columns: const [
                        DataColumn(label: Text('받는사람')),
                        DataColumn(label: Text('연락처')),
                        DataColumn(label: Text('주소')),
                        DataColumn(label: Text('상품')),
                        DataColumn(label: Text('배송메모')),
                        DataColumn(label: Text('주문번호')),
                      ],
                      rows: [
                        for (final s in shipments)
                          DataRow(cells: [
                            DataCell(Text(s.order.receiverName)),
                            DataCell(Text(s.order.receiverPhone)),
                            DataCell(ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 320),
                              child: Text(_address(s.order)),
                            )),
                            DataCell(ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: Text(_itemsSummary(s.items)),
                            )),
                            DataCell(Text(s.order.memo)),
                            DataCell(Text(s.order.orderNumber)),
                          ]),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
