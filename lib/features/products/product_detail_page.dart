import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../auth/auth_providers.dart';
import '../cart/cart_providers.dart';
import 'product.dart';
import 'products_providers.dart';
import 'widgets/countdown_badge.dart';

class ProductDetailPage extends ConsumerStatefulWidget {
  const ProductDetailPage({super.key, required this.productId});

  final String productId;

  @override
  ConsumerState<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends ConsumerState<ProductDetailPage> {
  int _quantity = 1;

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

  @override
  Widget build(BuildContext context) {
    final productAsync = ref.watch(productProvider(widget.productId));

    return Scaffold(
      appBar: AppBar(title: const Text('상품 상세')),
      body: productAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('상품을 불러오지 못했습니다.\n$e')),
        data: (product) {
          if (product == null) {
            return const Center(child: Text('존재하지 않는 상품입니다.'));
          }
          return _buildDetail(product);
        },
      ),
    );
  }

  Widget _buildDetail(Product product) {
    final theme = Theme.of(context);
    final onSale = product.isOnSale;

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
                    AspectRatio(
                      aspectRatio: 1.2,
                      child: product.imageUrls.isEmpty
                          ? Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Icon(Icons.image_outlined, size: 72),
                            )
                          : PageView(
                              children: [
                                for (final url in product.imageUrls)
                                  CachedNetworkImage(
                                      imageUrl: url, fit: BoxFit.cover),
                              ],
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CountdownBadge(endsAt: product.endsAt),
                          const SizedBox(height: 12),
                          if (product.shopName.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(product.shopName,
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(color: Colors.grey[600])),
                            ),
                          Text(product.title,
                              style: theme.textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          if (product.originalPrice != null)
                            Text(
                              formatWon(product.originalPrice!),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                decoration: TextDecoration.lineThrough,
                                color: Colors.grey,
                              ),
                            ),
                          Row(
                            children: [
                              if (product.discountRate != null) ...[
                                Text('${product.discountRate}%',
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                            color: Colors.red,
                                            fontWeight: FontWeight.bold)),
                                const SizedBox(width: 8),
                              ],
                              Text(formatWon(product.price),
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            product.stock > 0
                                ? '남은 수량: ${product.stock}개'
                                : '품절',
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: product.stock > 0
                                    ? Colors.grey[700]
                                    : Colors.red),
                          ),
                          if (product.options.isNotEmpty) ...[
                            const Divider(height: 32),
                            Text('옵션 선택', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 12),
                            for (final group in product.options)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: DropdownButtonFormField<String>(
                                  initialValue: _selected[group.name],
                                  decoration: InputDecoration(
                                    labelText: '${group.name} *',
                                    border: const OutlineInputBorder(),
                                  ),
                                  items: [
                                    for (final c in group.choices)
                                      DropdownMenuItem(
                                        value: c.name,
                                        child: Text(c.extra > 0
                                            ? '${c.name} (+${formatWon(c.extra)})'
                                            : c.name),
                                      ),
                                  ],
                                  onChanged: onSale
                                      ? (v) => setState(() {
                                            if (v != null) {
                                              _selected[group.name] = v;
                                            }
                                          })
                                      : null,
                                ),
                              ),
                          ],
                          const Divider(height: 32),
                          Text('상품 설명', style: theme.textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Text(product.description,
                              style: theme.textTheme.bodyLarge),
                        ],
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
          unitPrice: product.price + product.optionExtra(_selected),
          onSale: onSale,
          onQuantityChanged: (q) => setState(() => _quantity = q),
          onAddToCart: () => _addToCart(product),
        ),
      ],
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
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8),
          ],
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
