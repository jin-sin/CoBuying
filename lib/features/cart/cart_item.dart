import '../products/product.dart';

class CartItem {
  const CartItem({
    required this.id,
    required this.productId,
    required this.quantity,
    required this.product,
  });

  final String id;
  final String productId;
  final int quantity;

  /// 조인으로 함께 조회한 상품 정보 (삭제된 상품이면 null)
  final Product? product;

  int get lineTotal => (product?.price ?? 0) * quantity;

  bool get isOrderable => product?.isOnSale ?? false;

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
        id: json['id'] as String,
        productId: json['product_id'] as String,
        quantity: json['quantity'] as int,
        product: json['products'] == null
            ? null
            : Product.fromJson(json['products'] as Map<String, dynamic>),
      );
}
