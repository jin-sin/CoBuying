import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../auth/auth_providers.dart';
import '../cart/cart_providers.dart';
import '../reviews/review.dart';
import '../reviews/reviews_providers.dart';
import '../reviews/widgets/product_reviews_section.dart';
import '../seller/seller_providers.dart';
import '../wishlist/wishlist_providers.dart';
import 'product.dart';
import 'products_providers.dart';

/// 판매자 이름 줄. 그 셀러가 전용 판매 링크(/s/{slug})를 만들어 뒀으면
/// 스토어프론트로 넘긴다 — 한 상품을 보러 온 손님이 그 셀러의 다른 공구까지
/// 보게 하는 게 링크의 절반이다. 링크가 없으면 이름만 보여준다.
class _ShopLine extends ConsumerWidget {
  const _ShopLine({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sellerId = product.sellerId;
    final shop = sellerId == null
        ? null
        : ref.watch(shopBySellerIdProvider(sellerId)).value;
    const style = TextStyle(fontSize: 12, color: Color(0xFF9B948C));

    if (shop == null) return Text(product.shopName, style: style);
    return InkWell(
      onTap: () => context.push('/s/${shop.slug}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('${shop.shopName} ›', style: style),
      ),
    );
  }
}

/// 상품 상세 — 시안 C: 풀블리드 이미지 + 흰 시트 + 숫자 스탯 타일.
/// 상세 이미지에는 스크림을 깔지 않는다 (글자가 사진 위에 없으므로).
class ProductDetailPage extends ConsumerStatefulWidget {
  const ProductDetailPage({super.key, required this.productId});

  final String productId;

  @override
  ConsumerState<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends ConsumerState<ProductDetailPage> {
  int _quantity = 1;
  int _imagePage = 0;

  /// 선택한 옵션 {그룹명: 선택지명}
  final Map<String, String> _selected = {};

  Future<void> _addToCart(Product product) async {
    if (ref.read(currentUserProvider) == null) {
      context.push('/login');
      return;
    }
    final missing = product.options
        .where((g) => !_selected.containsKey(g.name))
        .map((g) => g.name)
        .toList();
    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('옵션을 선택해 주세요: ${missing.join(', ')}')));
      return;
    }
    try {
      await ref.read(cartProvider.notifier).add(product.id, _quantity,
          selectedOptions: Map.of(_selected));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('장바구니에 담았습니다.'),
          action: SnackBarAction(
            label: '장바구니 보기',
            onPressed: () => context.push('/cart'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('담기에 실패했습니다: $e')));
    }
  }

  Future<void> _toggleWish(bool wished) async {
    if (ref.read(currentUserProvider) == null) {
      context.push('/login');
      return;
    }
    try {
      await ref
          .read(wishlistRepositoryProvider)
          .setWished(widget.productId, wished);
      ref.invalidate(myWishlistIdsProvider);
      if (wished && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('찜했습니다. 타임세일이 시작되면 알림을 보내드려요.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('처리에 실패했습니다: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final productAsync = ref.watch(productProvider(widget.productId));
    final wished = (ref.watch(myWishlistIdsProvider).value ?? const {})
        .contains(widget.productId);

    return Scaffold(
      body: productAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('상품을 불러오지 못했습니다.\n$e')),
        data: (product) {
          if (product == null) {
            return const Center(child: Text('존재하지 않는 상품입니다.'));
          }
          return _buildDetail(product, wished);
        },
      ),
    );
  }

  Widget _buildDetail(Product product, bool wished) {
    final onSale = product.isOnSale;
    final stats =
        ref.watch(allReviewStatsProvider).value?[product.id];

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ImageHeader(
                      product: product,
                      wished: wished,
                      page: _imagePage,
                      onPageChanged: (i) => setState(() => _imagePage = i),
                      onBack: () => context.canPop()
                          ? context.pop()
                          : context.go('/'),
                      onWishToggle: () => _toggleWish(!wished),
                    ),
                    // 이미지에 살짝 겹치는 흰 시트
                    Transform.translate(
                      offset: const Offset(0, -20),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.vertical(
                              top: Radius.circular(22)),
                        ),
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (product.shopName.isNotEmpty)
                              _ShopLine(product: product),
                            const SizedBox(height: 2),
                            Text(product.title,
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            _PriceRow(product: product),
                            const SizedBox(height: 14),
                            _StatTiles(product: product, stats: stats),
                            if (product.options.isNotEmpty) ...[
                              const SizedBox(height: 18),
                              for (final group in product.options)
                                _OptionChips(
                                  group: group,
                                  selected: _selected[group.name],
                                  enabled: onSale,
                                  onSelected: (v) => setState(
                                      () => _selected[group.name] = v),
                                ),
                            ],
                            const Divider(height: 36),
                            Text(product.description,
                                style: const TextStyle(
                                    fontSize: 15, height: 1.6)),
                            const Divider(height: 36),
                            ProductReviewsSection(productId: product.id),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _BottomBar(
          product: product,
          quantity: _quantity,
          unitPrice: product.effectivePrice + product.optionExtra(_selected),
          onSale: onSale,
          onQuantityChanged: (q) => setState(() => _quantity = q),
          onAddToCart: () => _addToCart(product),
        ),
      ],
    );
  }
}

/// 풀블리드 이미지 캐러셀 + 플로팅 뒤로가기/하트 + 페이지 도트
class _ImageHeader extends StatelessWidget {
  const _ImageHeader({
    required this.product,
    required this.wished,
    required this.page,
    required this.onPageChanged,
    required this.onBack,
    required this.onWishToggle,
  });

  final Product product;
  final bool wished;
  final int page;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onBack;
  final VoidCallback onWishToggle;

  @override
  Widget build(BuildContext context) {
    final images = product.imageUrls;
    return AspectRatio(
      aspectRatio: 1.05,
      child: Stack(
        fit: StackFit.expand,
        children: [
          images.isEmpty
              ? Container(
                  color: const Color(0xFFF6F2ED),
                  child: const Icon(Icons.image_outlined,
                      size: 72, color: Color(0xFFB9B1A8)),
                )
              : PageView(
                  onPageChanged: onPageChanged,
                  children: [
                    for (final url in images)
                      CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                  ],
                ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _FloatingIcon(icon: Icons.arrow_back, onTap: onBack),
                    _FloatingIcon(
                      icon: wished
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: wished ? Colors.red : null,
                      onTap: onWishToggle,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (images.length > 1)
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < images.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 2.5),
                      width: i == page ? 14 : 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: i == page
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FloatingIcon extends StatelessWidget {
  const _FloatingIcon({required this.icon, required this.onTap, this.color});

  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: color ?? const Color(0xFF1F1A15)),
        ),
      ),
    );
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final pct = product.isOnTimeSale
        ? product.saleDiscountRate
        : product.discountRate;
    final strike = product.isOnTimeSale
        ? product.price
        : product.originalPrice;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (pct != null) ...[
          Text('$pct%',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFFFF3B30))),
          const SizedBox(width: 7),
        ],
        Text(formatWon(product.effectivePrice),
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.w800)),
        if (strike != null) ...[
          const SizedBox(width: 7),
          Text(formatWon(strike),
              style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFFB9B1A8),
                  decoration: TextDecoration.lineThrough)),
        ],
      ],
    );
  }
}

/// 마감/평점/재고 숫자 타일 3개 — 문장 대신 숫자로 요약 (시안 C)
class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.product, this.stats});

  final Product product;
  final ReviewStats? stats;

  @override
  Widget build(BuildContext context) {
    final saleEnd =
        product.isOnTimeSale ? product.saleEndsAt : null;
    return Row(
      children: [
        _StatTile(
          hot: true,
          label: saleEnd != null ? '세일 마감' : '판매 마감',
          child: _CountdownText(endsAt: saleEnd ?? product.endsAt),
        ),
        const SizedBox(width: 8),
        _StatTile(
          label: stats != null && stats!.reviewCount > 0
              ? '리뷰 ${stats!.reviewCount}'
              : '리뷰',
          child: stats != null && stats!.reviewCount > 0
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.star_rounded,
                        size: 15, color: Color(0xFFFFC94D)),
                    const SizedBox(width: 2),
                    Text(stats!.avgLabel, style: _StatTile.valueStyle),
                  ],
                )
              : const Text('아직 없음', style: _StatTile.valueStyle),
        ),
        const SizedBox(width: 8),
        _StatTile(
          label: '남은 수량',
          child: Text(
            product.stock > 0 ? '${product.stock}' : '품절',
            style: _StatTile.valueStyle.copyWith(
                color: product.stock > 0 ? null : const Color(0xFFFF3B30)),
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.child,
    this.hot = false,
  });

  static const valueStyle = TextStyle(
    fontSize: 14.5,
    fontWeight: FontWeight.w800,
    color: Color(0xFF1F1A15),
    fontFeatures: [FontFeature.tabularFigures()],
  );

  final String label;
  final Widget child;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F5F1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            DefaultTextStyle.merge(
              style: hot
                  ? valueStyle.copyWith(color: const Color(0xFFE5490F))
                  : valueStyle,
              child: child,
            ),
            const SizedBox(height: 1),
            Text(label,
                style: const TextStyle(
                    fontSize: 10.5, color: Color(0xFF857C72))),
          ],
        ),
      ),
    );
  }
}

/// 스탯 타일용 라이브 카운트다운 (초 단위 갱신)
class _CountdownText extends StatefulWidget {
  const _CountdownText({required this.endsAt});

  final DateTime endsAt;

  @override
  State<_CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<_CountdownText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.endsAt.difference(DateTime.now());
    return Text(remaining.isNegative ? '마감' : formatRemaining(remaining));
  }
}

/// 옵션 선택 — 드롭다운 대신 칩 (시안 C)
class _OptionChips extends StatelessWidget {
  const _OptionChips({
    required this.group,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final ProductOption group;
  final String? selected;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(group.name,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6E675F))),
          const SizedBox(height: 7),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in group.choices)
                _OptionChip(
                  label: c.extra > 0
                      ? '${c.name} +${formatWon(c.extra)}'
                      : c.name,
                  selected: selected == c.name,
                  onTap: enabled ? () => onSelected(c.name) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFFFF3EC) : Colors.white,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? brandOrange : const Color(0xFFE9E3DB),
          width: 1.5,
        ),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: onTap == null
                  ? const Color(0xFFB9B1A8)
                  : selected
                      ? const Color(0xFFC24A1D)
                      : const Color(0xFF6E675F),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.product,
    required this.quantity,
    required this.unitPrice,
    required this.onSale,
    required this.onQuantityChanged,
    required this.onAddToCart,
  });

  final Product product;
  final int quantity;
  final int unitPrice; // 옵션 추가금 포함 단가
  final bool onSale;
  final ValueChanged<int> onQuantityChanged;
  final VoidCallback onAddToCart;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFF0EBE4))),
        ),
        child: Row(
          children: [
            IconButton.outlined(
              onPressed: quantity > 1
                  ? () => onQuantityChanged(quantity - 1)
                  : null,
              icon: const Icon(Icons.remove),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('$quantity',
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            IconButton.outlined(
              onPressed: quantity < product.stock
                  ? () => onQuantityChanged(quantity + 1)
                  : null,
              icon: const Icon(Icons.add),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton(
                onPressed: onSale ? onAddToCart : null,
                child: Text(onSale
                    ? '${formatWon(unitPrice * quantity)} 담기'
                    : product.isExpired
                        ? '판매가 마감되었습니다'
                        : '품절'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
