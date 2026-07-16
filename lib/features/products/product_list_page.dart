import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../auth/auth_providers.dart';
import '../cart/cart_providers.dart';
import '../seller/seller_providers.dart';
import 'product.dart';
import 'products_providers.dart';
import 'widgets/countdown_badge.dart';

class ProductListPage extends ConsumerWidget {
  const ProductListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(activeProductsProvider);
    final user = ref.watch(currentUserProvider);
    final cartCount = ref.watch(cartItemCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('공동구매'),
        actions: [
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
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(activeProductsProvider.future),
        child: products.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _ErrorView(
            message: '상품을 불러오지 못했습니다.\n$e',
            onRetry: () => ref.invalidate(activeProductsProvider),
          ),
          data: (items) => items.isEmpty
              ? const _EmptyView()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.maxWidth / 320).floor().clamp(1, 4);
                    return GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.72,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _ProductCard(product: items[i]),
                    );
                  },
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
  const _ProductCard({required this.product});

  final Product product;

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
                  CountdownBadge(endsAt: product.endsAt, compact: true),
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
