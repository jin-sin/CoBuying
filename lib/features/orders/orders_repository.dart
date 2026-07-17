import 'package:supabase_flutter/supabase_flutter.dart';

import 'order.dart';

class OrdersRepository {
  OrdersRepository(this._client);

  final SupabaseClient _client;

  /// 주문 생성. 서버의 create_order RPC가 재고/기한 검증과
  /// 재고 차감, 장바구니 정리를 트랜잭션으로 처리한다.
  Future<String> createOrder({
    required String paymentMethod,
    required String receiverName,
    required String receiverPhone,
    required String postcode,
    required String address1,
    required String address2,
    required String memo,
    String? depositorName,
    required List<({String productId, int quantity})> items,
  }) async {
    final orderId = await _client.rpc('create_order', params: {
      'p_payment_method': paymentMethod,
      'p_receiver_name': receiverName,
      'p_receiver_phone': receiverPhone,
      'p_postcode': postcode,
      'p_address1': address1,
      'p_address2': address2,
      'p_memo': memo,
      'p_depositor_name': depositorName,
      'p_items': [
        for (final i in items)
          {'product_id': i.productId, 'quantity': i.quantity},
      ],
    });
    return orderId as String;
  }

  Future<List<Order>> fetchMyOrders() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];
    final rows = await _client
        .from('orders')
        .select('*, order_items(*)')
        .eq('user_id', user.id)
        .order('created_at', ascending: false);
    return rows.map(Order.fromJson).toList();
  }

  Future<Order?> fetchOrder(String id) async {
    final row = await _client
        .from('orders')
        .select('*, order_items(*)')
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : Order.fromJson(row);
  }

  /// 구매자 본인 주문 취소. 서버 RPC가 상태 검증(입금 대기만 가능)과
  /// 재고 복원(트리거)을 처리한다.
  Future<void> cancelMyOrder(String orderId) async {
    await _client.rpc('cancel_my_order', params: {'p_order_id': orderId});
  }

  /// 관리자용: 전체 주문
  Future<List<Order>> fetchAllOrders() async {
    final rows = await _client
        .from('orders')
        .select('*, order_items(*)')
        .order('created_at', ascending: false);
    return rows.map(Order.fromJson).toList();
  }

  /// 셀러용: 자기 주문 아이템의 배송 상태 변경.
  /// 서버 RPC가 소유 검증과 주문 전체 상태 재계산을 처리한다.
  Future<void> updateItemStatus(String itemId, String status) async {
    await _client.rpc('update_item_status', params: {
      'p_item_id': itemId,
      'p_status': status,
    });
  }

  /// 관리자용: 주문 상태 변경 (입금 확인 등)
  Future<void> updateStatus(String orderId, String status) async {
    await _client
        .from('orders')
        .update({'status': status, 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', orderId);
  }
}
