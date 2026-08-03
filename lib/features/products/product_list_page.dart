import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/brand.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../auth/auth_providers.dart';
import '../cart/cart_providers.dart';
import '../notifications/push/push_providers.dart';
import '../reviews/review.dart';
import '../reviews/reviews_providers.dart';
import '../seller/seller_providers.dart';
import '../wishlist/wishlist_providers.dart';
import 'categories.dart';
import 'product.dart';
import 'products_providers.dart';
import 'widgets/countdown_badge.dart';
import 'widgets/product_card.dart';

/// 목록 정렬 기준
enum _Sort {
  endingSoon('마감임박순'),
  newest('신상품순'),
  priceLow('낮은가격순'),
  priceHigh('높은가격순');

  const _Sort(this.label);
  final String label;
}

/// 카테고리 아이콘 (시안 C — 텍스트 탭 대신 아이콘 칩)
const _categoryIcons = <String, IconData>{
  '식품': Icons.lunch_dining_outlined,
  '패션·잡화': Icons.checkroom,
  '뷰티': Icons.auto_awesome_outlined,
  '리빙·주방': Icons.chair_outlined,
  '디지털·가전': Icons.devices_outlined,
  '키즈': Icons.toys_outlined,
  '반려동물': Icons.pets_outlined,
  '기타': Icons.more_horiz,
};

class ProductListPage extends ConsumerStatefulWidget {
  const ProductListPage({super.key});

  @override
  ConsumerState<ProductListPage> createState() => _ProductListPageState();
}

class _ProductListPageState extends ConsumerState<ProductListPage> {
  final _search = TextEditingController();
  String _query = '';
  String? _category; // null = 전체
  _Sort _sort = _Sort.endingSoon;
  bool _searchOpen = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _toggleWish(Product product, bool wished) async {
    if (ref.read(currentUserProvider) == null) {
      context.push('/login');
      return;
    }
    try {
      await ref
          .read(wishlistRepositoryProvider)
          .setWished(product.id, wished);
      ref.invalidate(myWishlistIdsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('처리에 실패했습니다: $e')));
      }
    }
  }

  List<Product> _apply(List<Product> items) {
    final q = _query.trim().toLowerCase();
    final list = items.where((p) {
      if (_category != null && p.category != _category) return false;
      if (q.isEmpty) return true;
      return p.title.toLowerCase().contains(q) ||
          p.description.toLowerCase().contains(q) ||
          p.shopName.toLowerCase().contains(q);
    }).toList();
    switch (_sort) {
      case _Sort.endingSoon:
        list.sort((a, b) => a.endsAt.compareTo(b.endsAt));
      case _Sort.newest:
        list.sort((a, b) => (b.createdAt ?? b.startsAt)
            .compareTo(a.createdAt ?? a.startsAt));
      case _Sort.priceLow:
        list.sort((a, b) => a.price.compareTo(b.price));
      case _Sort.priceHigh:
        list.sort((a, b) => b.price.compareTo(a.price));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(activeProductsProvider);
    final user = ref.watch(currentUserProvider);
    final cartCount = ref.watch(cartItemCountProvider);
    // 평점 배지용 집계 (로딩/실패 시 배지만 생략)
    final reviewStats =
        ref.watch(allReviewStatsProvider).value ?? const <String, ReviewStats>{};
    final wishedIds = ref.watch(myWishlistIdsProvider).value ?? const <String>{};

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandMark(size: 24),
            SizedBox(width: 8),
            BrandWordmark(),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '검색',
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searchOpen = !_searchOpen;
              if (!_searchOpen) {
                _search.clear();
                _query = '';
              }
            }),
          ),
          Badge(
            isLabelVisible: cartCount > 0,
            label: Text('$cartCount'),
            offset: const Offset(-6, 6),
            child: IconButton(
              tooltip: '장바구니',
              icon: const Icon(Icons.shopping_cart_outlined),
              onPressed: () => context.push('/cart'),
            ),
          ),
          if (user == null)
            TextButton(
              onPressed: () => context.push('/login'),
              child: const Text('로그인'),
            )
          else
            const _ProfileMenu(),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: '상품·판매자 검색',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<_Sort>(
                    value: _sort,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final s in _Sort.values)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                    onChanged: (s) =>
                        setState(() => _sort = s ?? _Sort.endingSoon),
                  ),
                ],
              ),
            ),
          SizedBox(
            height: 76,
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  _CategoryChip(
                    label: '전체',
                    icon: Icons.grid_view_rounded,
                    selected: _category == null,
                    onTap: () => setState(() => _category = null),
                  ),
                  for (final c in productCategories) ...[
                    const SizedBox(width: 14),
                    _CategoryChip(
                      label: c,
                      icon: _categoryIcons[c] ?? Icons.category_outlined,
                      selected: _category == c,
                      onTap: () => setState(
                          () => _category = _category == c ? null : c),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () {
                ref.invalidate(allReviewStatsProvider);
                return ref.refresh(activeProductsProvider.future);
              },
              child: products.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => _ErrorView(
                  message: '상품을 불러오지 못했습니다.\n$e',
                  onRetry: () => ref.invalidate(activeProductsProvider),
                ),
                data: (items) {
                  if (items.isEmpty) return const _EmptyView();
                  final filtered = _apply(items);
                  if (filtered.isEmpty) {
                    return ListView(children: const [
                      SizedBox(height: 120),
                      Icon(Icons.search_off, size: 48, color: Colors.grey),
                      SizedBox(height: 12),
                      Center(child: Text('조건에 맞는 상품이 없습니다.')),
                    ]);
                  }
                  // 검색·카테고리 필터가 없을 때만 타임세일 히어로 노출
                  final saleItems = _query.trim().isEmpty && _category == null
                      ? filtered.where((p) => p.isOnTimeSale).toList()
                      : const <Product>[];
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: CustomScrollView(
                        slivers: [
                          if (saleItems.isNotEmpty)
                            SliverPadding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              sliver: SliverToBoxAdapter(
                                child: _SaleHero(
                                  products: saleItems,
                                  wishedIds: wishedIds,
                                ),
                              ),
                            ),
                          SliverPadding(
                            padding: const EdgeInsets.all(16),
                            sliver: SliverGrid(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 250,
                                mainAxisSpacing: 14,
                                crossAxisSpacing: 14,
                                childAspectRatio: 0.78,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, i) => ProductCard(
                                  product: filtered[i],
                                  stats: reviewStats[filtered[i].id],
                                  wished: wishedIds.contains(filtered[i].id),
                                  onWishToggle: (wished) =>
                                      _toggleWish(filtered[i], wished),
                                ),
                                childCount: filtered.length,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 카테고리 아이콘 칩 (시안 C)
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const orangeInk = Color(0xFFC24A1D);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFFFEDE4) : const Color(0xFFF6F2ED),
              borderRadius: BorderRadius.circular(16),
              border: selected
                  ? Border.all(color: brandOrange, width: 1.5)
                  : null,
            ),
            child: Icon(icon,
                size: 21,
                color: selected ? orangeInk : const Color(0xFF6E675F)),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? orangeInk : const Color(0xFF6E675F),
            ),
          ),
        ],
      ),
    );
  }
}

/// 타임세일 히어로 — 진행 중 세일 상품을 홈 최상단 대형 카드로.
/// 여러 개면 가로 스와이프.
class _SaleHero extends StatelessWidget {
  const _SaleHero({required this.products, required this.wishedIds});

  final List<Product> products;
  final Set<String> wishedIds;

  @override
  Widget build(BuildContext context) {
    if (products.length == 1) {
      return SizedBox(height: 195, child: _HeroCard(product: products.first));
    }
    return SizedBox(
      height: 195,
      child: PageView.builder(
        controller: PageController(viewportFraction: 0.93),
        itemCount: products.length,
        padEnds: false,
        itemBuilder: (context, i) => Padding(
          padding: EdgeInsets.only(right: i == products.length - 1 ? 0 : 10),
          child: _HeroCard(product: products[i]),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ProductImage(product: product),
          const DecoratedBox(
              decoration: BoxDecoration(gradient: imageScrim)),
          // ⚡ 타임세일 배지
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: brandOrange,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bolt, size: 13, color: Colors.white),
                  Text(
                    '타임세일 ${product.saleDiscountRate}%',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 12,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        product.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.88),
                          fontSize: 11.5,
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            formatWon(product.effectivePrice),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            formatWon(product.price),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 12,
                              decoration: TextDecoration.lineThrough,
                              decorationColor:
                                  Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (product.saleEndsAt != null)
                  CountdownBadge(endsAt: product.saleEndsAt!, onImage: true),
              ],
            ),
          ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => context.push('/product/${product.id}'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 로그인 사용자용 프로필 메뉴.
/// 셀러센터는 입점 신청한 사용자에게만 그 이름으로 보이고,
/// 일반 사용자에게는 "셀러 입점 신청"으로 노출된다. 관리자 메뉴는 admin만.
class _ProfileMenu extends ConsumerWidget {
  const _ProfileMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider);
    final isSeller = ref.watch(mySellerProfileProvider).value != null;

    return PopupMenuButton<String>(
      tooltip: '내 메뉴',
      icon: const Icon(Icons.person_outline),
      onSelected: (value) {
        switch (value) {
          case 'seller':
            context.push('/seller');
          case 'admin':
            context.push('/admin');
          case 'info':
            context.push('/info');
          case 'logout':
            // 토큰 해제는 세션이 살아있을 때만 가능하므로 로그아웃보다 먼저
            ref
                .read(pushServiceProvider)
                .unregister()
                .then((_) => ref.read(authRepositoryProvider).signOut());
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'seller',
          child: ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: Text(isSeller ? '셀러센터' : '셀러 입점 신청'),
          ),
        ),
        if (isAdmin)
          const PopupMenuItem(
            value: 'admin',
            child: ListTile(
              leading: Icon(Icons.admin_panel_settings_outlined),
              title: Text('관리자'),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'info',
          child: ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('약관 및 정책'),
          ),
        ),
        const PopupMenuItem(
          value: 'logout',
          child: ListTile(
            leading: Icon(Icons.logout),
            title: Text('로그아웃'),
          ),
        ),
      ],
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    // 빈 화면을 그냥 두지 않고 입점 안내로 연결한다 — 셀러가 붙어야 상품이 생긴다
    return ListView(
      children: [
        const SizedBox(height: 140),
        const Icon(Icons.storefront_outlined, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        const Center(child: Text('현재 진행 중인 공동구매가 없습니다.')),
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton.icon(
            onPressed: () => context.push('/partner'),
            icon: const Icon(Icons.storefront_outlined, size: 18),
            label: const Text('판매자로 입점하기'),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.error_outline, size: 48, color: Colors.grey),
        const SizedBox(height: 12),
        Center(child: Text(message, textAlign: TextAlign.center)),
        const SizedBox(height: 12),
        Center(child: OutlinedButton(onPressed: onRetry, child: const Text('다시 시도'))),
      ],
    );
  }
}
