import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../auth/auth_providers.dart';
import '../cart/cart_providers.dart';
import '../notifications/notifications_providers.dart';
import '../reviews/review.dart';
import '../reviews/reviews_providers.dart';
import '../seller/seller_providers.dart';
import 'categories.dart';
import 'product.dart';
import 'products_providers.dart';
import 'widgets/countdown_badge.dart';

/// 목록 정렬 기준
enum _Sort {
  endingSoon('마감임박순'),
  newest('신상품순'),
  priceLow('낮은가격순'),
  priceHigh('높은가격순');

  const _Sort(this.label);
  final String label;
}

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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('공동구매'),
        actions: [
          if (user != null) const _NotificationBell(),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: '상품·판매자 검색',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
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
            height: 48,
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              // Material Chip은 가로 무제한 레이아웃에서 최소 intrinsic 폭
              // (한글은 글자 단위 줄바꿈 가능 → 1글자)으로 접혀 라벨이 잘리므로
              // 커스텀 알약 버튼을 쓴다.
              child: Row(
                children: [
                  _CategoryPill(
                    label: '전체',
                    selected: _category == null,
                    onTap: () => setState(() => _category = null),
                  ),
                  for (final c in productCategories) ...[
                    const SizedBox(width: 8),
                    _CategoryPill(
                      label: c,
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
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final columns =
                          (constraints.maxWidth / 320).floor().clamp(1, 4);
                      return GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, i) => _ProductCard(
                          product: filtered[i],
                          stats: reviewStats[filtered[i].id],
                        ),
                      );
                    },
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

/// 알림 종 아이콘 + 안읽음 배지 (Realtime 스트림으로 실시간 갱신)
class _NotificationBell extends ConsumerWidget {
  const _NotificationBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationCountProvider);
    return Badge(
      isLabelVisible: unread > 0,
      label: Text('$unread'),
      offset: const Offset(-6, 6),
      child: IconButton(
        tooltip: '알림',
        icon: const Icon(Icons.notifications_outlined),
        onPressed: () => context.push('/notifications'),
      ),
    );
  }
}

/// 카테고리 선택 알약 버튼 (가로 스크롤용 Chip 대체)
class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
            color: selected ? Colors.transparent : scheme.outlineVariant),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            softWrap: false,
            style: TextStyle(
              color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
              fontWeight: selected ? FontWeight.bold : null,
            ),
          ),
        ),
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
          case 'orders':
            context.push('/orders');
          case 'seller':
            context.push('/seller');
          case 'admin':
            context.push('/admin');
          case 'logout':
            ref.read(authRepositoryProvider).signOut();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'orders',
          child: ListTile(
            leading: Icon(Icons.receipt_long_outlined),
            title: Text('주문 내역'),
          ),
        ),
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

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, this.stats});

  final Product product;
  final ReviewStats? stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/product/${product.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: product.imageUrls.isEmpty
                  ? Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.image_outlined, size: 48),
                    )
                  : CachedNetworkImage(
                      imageUrl: product.imageUrls.first,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(product.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (product.discountRate != null) ...[
                        Text('${product.discountRate}%',
                            style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.red, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                      ],
                      Text(formatWon(product.price),
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      CountdownBadge(endsAt: product.endsAt, compact: true),
                      const Spacer(),
                      if (stats != null && stats!.reviewCount > 0) ...[
                        const Icon(Icons.star, size: 14, color: Colors.amber),
                        const SizedBox(width: 2),
                        Text(
                          '${stats!.avgLabel} (${stats!.reviewCount})',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.grey[600]),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SizedBox(height: 160),
        Icon(Icons.storefront_outlined, size: 64, color: Colors.grey),
        SizedBox(height: 16),
        Center(child: Text('현재 진행 중인 공동구매가 없습니다.')),
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
