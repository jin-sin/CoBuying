class Order {
  const Order({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.paymentMethod,
    required this.totalAmount,
    this.depositorName,
    required this.receiverName,
    required this.receiverPhone,
    required this.postcode,
    required this.address1,
    required this.address2,
    required this.memo,
    required this.createdAt,
    this.items = const [],
  });

  final String id;
  final String orderNumber;
  final String status;
  final String paymentMethod; // card | bank_transfer
  final int totalAmount;
  final String? depositorName;
  final String receiverName;
  final String receiverPhone;
  final String postcode;
  final String address1;
  final String address2;
  final String memo;
  final DateTime createdAt;
  final List<OrderItem> items;

  String get statusLabel => switch (status) {
        'pending_payment' => '입금 대기',
        'paid' => '결제 완료',
        'preparing' => '상품 준비중',
        'shipped' => '배송중',
        'delivered' => '배송 완료',
        'cancelled' => '취소됨',
        _ => status,
      };

  String get paymentMethodLabel =>
      paymentMethod == 'card' ? '카드결제' : '무통장입금';

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as String,
        orderNumber: json['order_number'] as String,
        status: json['status'] as String,
        paymentMethod: json['payment_method'] as String,
        totalAmount: json['total_amount'] as int,
        depositorName: json['depositor_name'] as String?,
        receiverName: json['receiver_name'] as String,
        receiverPhone: json['receiver_phone'] as String,
        postcode: json['postcode'] as String? ?? '',
        address1: json['address1'] as String,
        address2: json['address2'] as String? ?? '',
        memo: json['memo'] as String? ?? '',
        createdAt: DateTime.parse(json['created_at'] as String),
        items: (json['order_items'] as List<dynamic>? ?? [])
            .map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class OrderItem {
  const OrderItem({
    required this.productTitle,
    required this.unitPrice,
    required this.quantity,
    this.productId,
    this.sellerId,
    this.commissionRate = 0,
    this.feeAmount = 0,
  });

  final String? productId;
  final String? sellerId;
  final String productTitle;
  final int unitPrice;
  final int quantity;
  final double commissionRate; // 주문 시점 수수료율 (%)
  final int feeAmount; // 플랫폼 수수료 (원)

  int get lineTotal => unitPrice * quantity;

  /// 셀러 입장에서의 정산 금액
  int get sellerPayout => lineTotal - feeAmount;

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
        productId: json['product_id'] as String?,
        sellerId: json['seller_id'] as String?,
        productTitle: json['product_title'] as String,
        unitPrice: json['unit_price'] as int,
        quantity: json['quantity'] as int,
        commissionRate: (json['commission_rate'] as num? ?? 0).toDouble(),
        feeAmount: (json['fee_amount'] as num? ?? 0).toInt(),
      );
}
