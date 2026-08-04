import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/brand.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/auth_providers.dart';
import '../info/legal.dart';
import '../products/group_buy.dart';
import '../products/product.dart';
import '../products/products_providers.dart';
import '../products/widgets/product_card.dart';
import '../reviews/review.dart';
import '../reviews/reviews_providers.dart';
import '../wishlist/wishlist_providers.dart';
import 'seller_profile.dart';
import 'seller_providers.dart';

/// 셀러 전용 판매 링크가 여는 공개 스토어프론트 (`/s/{slug}`).
///
/// **로그인 없이** 열린다. 셀러가 인스타 프로필·카톡 채널에 걸어두고 자기 손님을
/// 데려오는 곳이라, 로그인 벽이 있으면 존재 의미가 없다. 데이터는 계좌·연락처를
/// 뺀 `seller_shops` 뷰에서 읽는다 (schema.sql 28절).
class ShopPage extends ConsumerWidget {
  const ShopPage({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shopAsync = ref.watch(shopBySlugProvider(slug));

    return Scaffold(
      body: shopAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ShopMessage(
          icon: Icons.error_outline,
          message: '스토어를 불러오지 못했습니다.\n$e',
          onRetry: () => ref.invalidate(shopBySlugProvider(slug)),
        ),
        data: (shop) => shop == null
            ? const _ShopMessage(
                icon: Icons.storefront_outlined,
                message: '존재하지 않는 판매자 링크입니다.\n주소를 다시 확인해 주세요.',
              )
            : _ShopView(shop: shop),
      ),
    );
  }
}

class _ShopView extends ConsumerWidget {
  const _ShopView({required this.shop});

  final SellerShop shop;

  Future<void> _toggleWish(
      BuildContext context, WidgetRef ref, Product product, bool wished) async {
    if (ref.read(currentUserProvider) == null) {
      context.push('/login');
      return;
    }
    try {
      await ref.read(wishlistRepositoryProvider).setWished(product.id, wished);
      ref.invalidate(myWishlistIdsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('처리에 실패했습니다: $e')));
      }
    }
  }

  Future<void> _share(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: shopUrl(shop.slug)));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('스토어 링크를 복사했습니다.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productsAsync = ref.watch(shopProductsProvider(shop.sellerId));
    final reviewStats =
        ref.watch(allReviewStatsProvider).value ?? const <String, ReviewStats>{};
    final wishedIds = ref.watch(myWishlistIdsProvider).value ?? const <String>{};
    final groupBuy = ref.watch(groupBuyProgressProvider).value ??
        const <String, GroupBuyProgress>{};

    // 앱바를 두지 않는다. 상호명이 바로 아래 헤더와 겹쳐 두 번 나오고, 링크로 온
    // 손님한테는 화면 맨 위 제일 좋은 자리에 '나가기'를 놓는 꼴이 된다.
    // 뒤로가기는 앱 안에서 들어왔을 때(상품 상세 → 스토어)만 의미가 있다.
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () =>
            ref.refresh(shopProductsProvider(shop.sellerId).future),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _TopActions(
                    canPop: context.canPop(),
                    onBack: () => context.pop(),
                    onShare: () => _share(context),
                  ),
                ),
                SliverToBoxAdapter(
                  child: productsAsync.when(
                    loading: () => _Header(shop: shop),
                    error: (_, _) => _Header(shop: shop),
                    data: (items) => _Header(
                      shop: shop,
                      liveCount: items.where(_isLive).length,
                      pastCount: items.where((p) => !_isLive(p)).length,
                    ),
                  ),
                ),
                ...productsAsync.when(
                  loading: () => const [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 60),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  ],
                  error: (e, _) => [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Center(
                            child: Text('상품을 불러오지 못했습니다.\n$e',
                                textAlign: TextAlign.center)),
                      ),
                    ),
                  ],
                  data: (items) {
                    final live = items.where(_isLive).toList();
                    final past = items.where((p) => !_isLive(p)).toList();
                    return [
                      if (live.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 44),
                            child: Center(
                              child: Text('진행 중인 공동구매가 없습니다.',
                                  style: TextStyle(color: mutedText)),
                            ),
                          ),
                        )
                      else
                        _ProductGrid(
                          products: live,
                          reviewStats: reviewStats,
                          groupBuy: groupBuy,
                          wishedIds: wishedIds,
                          onWishToggle: (p, w) =>
                              _toggleWish(context, ref, p, w),
                        ),
                      if (past.isNotEmpty) ...[
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: Text('지난 공동구매',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 15)),
                          ),
                        ),
                        _ProductGrid(
                          products: past,
                          reviewStats: reviewStats,
                          groupBuy: groupBuy,
                          wishedIds: wishedIds,
                          onWishToggle: (p, w) =>
                              _toggleWish(context, ref, p, w),
                        ),
                      ],
                      const SliverToBoxAdapter(child: _ShopFooter()),
                    ];
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 지금 살 수 있는 상품인지. `Product.isOnSale`은 품절도 제외하지만
  /// 스토어에서는 품절도 진행 중으로 보여준다 (재입고를 기다리는 손님이 있다).
  static bool _isLive(Product p) =>
      p.status == 'active' &&
      !p.isExpired &&
      !p.startsAt.isAfter(DateTime.now());
}

/// 스토어 맨 위 액션 줄. 상호명은 헤더가 이미 크게 보여주므로 제목을 두지 않는다.
/// 뒤로가기는 앱 안에서 넘어왔을 때만 — 링크로 들어온 손님에겐 돌아갈 데가 없고,
/// 그 자리에 '나가기'를 두면 셀러가 데려온 손님을 내보내는 버튼이 된다.
class _TopActions extends StatelessWidget {
  const _TopActions({
    required this.canPop,
    required this.onBack,
    required this.onShare,
  });

  final bool canPop;
  final VoidCallback onBack;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          if (canPop)
            IconButton(
              tooltip: '뒤로',
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
            ),
          const Spacer(),
          IconButton(
            tooltip: '링크 복사',
            icon: const Icon(Icons.ios_share),
            onPressed: onShare,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.shop, this.liveCount, this.pastCount});

  final SellerShop shop;
  final int? liveCount;
  final int? pastCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: softBg, shape: BoxShape.circle),
                child: const Icon(Icons.storefront_outlined,
                    size: 26, color: brandOrange),
              ),
              const SizedBox(width: 14),
              // 주소(/s/{slug})는 적지 않는다. 손님은 그 주소로 들어왔으니 새 정보가
              // 아니고, 셀러는 셀러센터 카드에서 전체 주소를 이미 보고 있다.
              Expanded(
                child: Text(shop.shopName,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          if (shop.intro.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(shop.intro, style: const TextStyle(fontSize: 14, height: 1.5)),
          ],
          if (liveCount != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                _Stat(label: '진행 중', value: '$liveCount'),
                const SizedBox(width: 10),
                _Stat(label: '지난 공구', value: '${pastCount ?? 0}'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: softBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: mutedText)),
          const SizedBox(width: 6),
          Text(value,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _ProductGrid extends StatelessWidget {
  const _ProductGrid({
    required this.products,
    required this.reviewStats,
    required this.groupBuy,
    required this.wishedIds,
    required this.onWishToggle,
  });

  final List<Product> products;
  final Map<String, ReviewStats> reviewStats;
  final Map<String, GroupBuyProgress> groupBuy;
  final Set<String> wishedIds;
  final void Function(Product product, bool wished) onWishToggle;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 250,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 0.78,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => ProductCard(
            product: products[i],
            stats: reviewStats[products[i].id],
            progress: groupBuy[products[i].id],
            wished: wishedIds.contains(products[i].id),
            onWishToggle: (wished) => onWishToggle(products[i], wished),
          ),
          childCount: products.length,
        ),
      ),
    );
  }
}

/// 스토어 링크로 들어온 손님을 마켓 전체로 넘기는 자리.
/// 셀러가 데려온 손님이 다른 공구도 보게 되는 게 이 링크의 두 번째 목적이다.
class _ShopFooter extends StatelessWidget {
  const _ShopFooter();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      child: Column(
        children: [
          const Divider(height: 32),
          const BrandMark(size: 34),
          const SizedBox(height: 10),
          Text(
            '${BusinessInfo.serviceName}에서 진행 중인 공동구매입니다.',
            style: const TextStyle(fontSize: 13, color: mutedText),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => context.go('/'),
            child: const Text('다른 공동구매 둘러보기'),
          ),
        ],
      ),
    );
  }
}

class _ShopMessage extends StatelessWidget {
  const _ShopMessage({required this.icon, required this.message, this.onRetry});

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      message: message,
      actionLabel: onRetry == null ? '홈으로' : '다시 시도',
      onAction: onRetry ?? () => context.go('/'),
    );
  }
}
