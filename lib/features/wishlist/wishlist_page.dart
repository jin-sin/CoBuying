import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets.dart';
import '../products/product.dart';
import '../products/widgets/product_card.dart';
import '../reviews/reviews_providers.dart';
import 'wishlist_providers.dart';

/// 찜한 상품 목록 — 홈과 같은 온이미지 카드 그리드 (시안 C).
/// 판매 종료된 상품도 남겨서 재판매 때 알림을 받게 한다 (바랜 처리).
class WishlistPage extends ConsumerWidget {
  const WishlistPage({super.key});

  Future<void> _remove(
      BuildContext context, WidgetRef ref, Product product) async {
    try {
      await ref.read(wishlistRepositoryProvider).setWished(product.id, false);
      ref.invalidate(myWishlistProductsProvider);
      ref.invalidate(myWishlistIdsProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('삭제에 실패했습니다: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productsAsync = ref.watch(myWishlistProductsProvider);
    final reviewStats = ref.watch(allReviewStatsProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('찜한 상품')),
      body: productsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
        data: (products) {
          if (products.isEmpty) {
            return const EmptyState(
              icon: Icons.favorite_border,
              message: '찜한 상품이 없습니다.\n상품의 ♡를 눌러 찜하면 타임세일 알림을 받아요.',
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(myWishlistProductsProvider.future),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 250,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: products.length,
                  itemBuilder: (context, i) => ProductCard(
                    product: products[i],
                    stats: reviewStats?[products[i].id],
                    wished: true,
                    onWishToggle: (_) =>
                        _remove(context, ref, products[i]),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
