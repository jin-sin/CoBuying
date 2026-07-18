import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../products/product.dart';
import 'wishlist_providers.dart';

/// 찜한 상품 목록. 판매 종료된 상품도 남겨서 재판매 때 알림을 받게 한다.
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

    return Scaffold(
      appBar: AppBar(title: const Text('찜한 상품')),
      body: productsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('불러오기 실패\n$e')),
        data: (products) {
          if (products.isEmpty) {
            return const Center(
              child: Text('찜한 상품이 없습니다.\n상품의 ♡를 눌러 찜하면 타임세일 알림을 받아요.',
                  textAlign: TextAlign.center),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(myWishlistProductsProvider.future),
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: products.length,
              itemBuilder: (context, i) {
                final p = products[i];
                final theme = Theme.of(context);
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: p.imageUrls.isEmpty
                            ? Container(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                child: const Icon(Icons.image_outlined),
                              )
                            : CachedNetworkImage(
                                imageUrl: p.imageUrls.first,
                                fit: BoxFit.cover),
                      ),
                    ),
                    title: Text(p.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      p.isOnTimeSale
                          ? '⚡ 타임세일 ${formatWon(p.effectivePrice)}'
                          : p.isOnSale
                              ? formatWon(p.price)
                              : '판매 종료',
                      style: TextStyle(
                        color: p.isOnTimeSale
                            ? Colors.red
                            : p.isOnSale
                                ? null
                                : Colors.grey,
                        fontWeight: p.isOnTimeSale ? FontWeight.bold : null,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.favorite, color: Colors.red),
                      tooltip: '찜 해제',
                      onPressed: () => _remove(context, ref, p),
                    ),
                    onTap: () => context.push('/product/${p.id}'),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
