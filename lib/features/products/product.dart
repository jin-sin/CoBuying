/// 옵션 그룹의 선택지 (예: "L", 추가금 1000원)
class OptionChoice {
  const OptionChoice({required this.name, this.extra = 0});

  final String name;
  final int extra; // 추가금 (원)

  factory OptionChoice.fromJson(Map<String, dynamic> json) => OptionChoice(
        name: json['name'] as String? ?? '',
        extra: (json['extra'] as num? ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {'name': name, 'extra': extra};
}

/// 상품 옵션 그룹 (예: "사이즈" — S/M/L 중 하나 선택)
class ProductOption {
  const ProductOption({required this.name, required this.choices});

  final String name;
  final List<OptionChoice> choices;

  factory ProductOption.fromJson(Map<String, dynamic> json) => ProductOption(
        name: json['name'] as String? ?? '',
        choices: (json['choices'] as List<dynamic>? ?? [])
            .map((e) => OptionChoice.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() =>
      {'name': name, 'choices': [for (final c in choices) c.toJson()]};
}

class Product {
  const Product({
    required this.id,
    this.sellerId,
    this.shopName = '',
    required this.title,
    required this.description,
    required this.price,
    this.originalPrice,
    required this.stock,
    required this.imageUrls,
    required this.startsAt,
    required this.endsAt,
    required this.status,
    this.options = const [],
  });

  final String id;
  final String? sellerId;
  final String shopName; // 등록 시점 상호명 스냅샷 (DB 트리거가 채움)
  final String title;
  final String description;
  final int price;
  final int? originalPrice;
  final int stock;
  final List<String> imageUrls;
  final DateTime startsAt;
  final DateTime endsAt;
  final String status; // active | closed | hidden
  final List<ProductOption> options;

  /// 선택된 옵션({그룹명: 선택지명})의 추가금 합계.
  /// 선택지가 옵션 정의에서 사라졌으면 0으로 취급한다.
  int optionExtra(Map<String, String> selected) {
    var extra = 0;
    for (final group in options) {
      final choiceName = selected[group.name];
      for (final c in group.choices) {
        if (c.name == choiceName) {
          extra += c.extra;
          break;
        }
      }
    }
    return extra;
  }

  bool get isExpired => DateTime.now().isAfter(endsAt);
  bool get isOnSale => status == 'active' && !isExpired && stock > 0;

  int? get discountRate {
    final original = originalPrice;
    if (original == null || original <= price) return null;
    return ((original - price) / original * 100).round();
  }

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        id: json['id'] as String,
        sellerId: json['seller_id'] as String?,
        shopName: json['shop_name'] as String? ?? '',
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        price: json['price'] as int,
        originalPrice: json['original_price'] as int?,
        stock: json['stock'] as int,
        imageUrls: (json['image_urls'] as List<dynamic>? ?? []).cast<String>(),
        startsAt: DateTime.parse(json['starts_at'] as String),
        endsAt: DateTime.parse(json['ends_at'] as String),
        status: json['status'] as String,
        options: (json['options'] as List<dynamic>? ?? [])
            .map((e) => ProductOption.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toInsertJson() => {
        'title': title,
        'description': description,
        'price': price,
        'original_price': originalPrice,
        'stock': stock,
        'image_urls': imageUrls,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'ends_at': endsAt.toUtc().toIso8601String(),
        'status': status,
        'options': [for (final o in options) o.toJson()],
      };
}
