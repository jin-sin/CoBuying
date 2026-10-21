import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_home_page.dart';
import '../features/broadcast_orders/broadcast_capture_page.dart';
import '../features/broadcast_orders/broadcast_customer_page.dart';
import '../features/broadcast_orders/broadcast_customer_requests_page.dart';
import '../features/broadcast_orders/broadcast_tasks_page.dart';
import '../features/broadcast_orders/broadcast_receipts_page.dart';
import '../features/broadcast_orders/broadcast_purchases_page.dart';
import '../features/broadcast_orders/broadcast_inventory_page.dart';
import '../features/broadcast_orders/broadcast_shipments_page.dart';
import '../features/broadcast_orders/broadcast_billing_page.dart';
import '../features/broadcast_orders/broadcast_staff_join_page.dart';
import '../features/broadcast_orders/shared_preferences_command_journal.dart';
import '../features/broadcast_orders/supabase_broadcast_repository.dart';
import '../features/admin/product_edit_page.dart';
import '../features/auth/auth_providers.dart';
import '../features/auth/login_page.dart';
import '../features/cart/cart_page.dart';
import '../features/info/info_pages.dart';
import '../features/info/legal.dart';
import '../features/orders/checkout_page.dart';
import '../features/orders/order_detail_page.dart';
import '../features/orders/order_list_page.dart';
import '../features/notifications/notifications_page.dart';
import '../features/orders/payment_result_page.dart';
import '../features/products/product_detail_page.dart';
import '../features/products/product_list_page.dart';
import '../features/seller/partner_page.dart';
import '../features/seller/seller_home_page.dart';
import '../features/seller/shop_page.dart';
import '../features/wishlist/wishlist_page.dart';
import 'app_shell.dart';
import 'auth_redirect.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authRepo = ref.watch(authRepositoryProvider);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: _StreamListenable(authRepo.onAuthStateChange),
    redirect: (context, state) =>
        authRedirect(state.uri, loggedIn: authRepo.currentUser != null),
    routes: [
      // 하단 네비게이션 탭 4개 (홈/찜/알림/주문) — 시안 C
      ShellRoute(
        builder: (_, _, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const ProductListPage()),
          GoRoute(path: '/wishlist', builder: (_, _) => const WishlistPage()),
          GoRoute(
            path: '/notifications',
            builder: (_, _) => const NotificationsPage(),
          ),
          GoRoute(path: '/orders', builder: (_, _) => const OrderListPage()),
        ],
      ),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/broadcast/:locator',
          builder: (_, state) => BroadcastCustomerPage(
            locator: state.pathParameters['locator']!,
            activationRequest: state.uri.queryParameters['request'],
            activationToken: state.uri.queryParameters['token'],
          ),
        ),
      // 법적 고지 (로그인 불필요 — 공개)
      GoRoute(path: '/info', builder: (_, _) => const InfoHubPage()),
      GoRoute(
        path: '/terms',
        builder: (_, _) => LegalDocPage(doc: termsDoc),
      ),
      GoRoute(
        path: '/privacy',
        builder: (_, _) => LegalDocPage(doc: privacyDoc),
      ),
      GoRoute(path: '/business', builder: (_, _) => const BusinessInfoPage()),
      // 셀러 입점 안내 — 공개. 셀러 후보에게 그대로 보낼 수 있는 링크가 필요해서
      // 로그인 뒤에 있는 /seller와 분리했다 (_authRequired가 /seller 전체를 막는다)
      GoRoute(path: '/partner', builder: (_, _) => const PartnerPage()),
      // 셀러 전용 판매 링크 — 공개. 셀러가 인스타·카톡에 걸어두는 주소라
      // 로그인 벽을 두면 안 된다. 짧게 유지하려고 /s 로 잡았다.
      GoRoute(
        path: '/s/:slug',
        builder: (_, state) => ShopPage(slug: state.pathParameters['slug']!),
      ),
      GoRoute(
        path: '/product/:id',
        builder: (_, state) =>
            ProductDetailPage(productId: state.pathParameters['id']!),
      ),
      GoRoute(path: '/cart', builder: (_, _) => const CartPage()),
      GoRoute(path: '/checkout', builder: (_, _) => const CheckoutPage()),
      GoRoute(
        path: '/orders/:id',
        builder: (_, state) => OrderDetailPage(
          orderId: state.pathParameters['id']!,
          justPlaced: state.uri.queryParameters['placed'] == '1',
        ),
      ),
      // 토스 결제창 리다이렉트 진입점. 토스는 쿼리를 프래그먼트 앞에 붙이므로
      // (/?paymentKey=...#/payment/success) 실제 주소창 쿼리(Uri.base)도 함께 읽는다.
      GoRoute(
        path: '/payment/success',
        builder: (_, state) => PaymentSuccessPage(
          params: {
            ...launchQueryParams,
            ...Uri.base.queryParameters,
            ...state.uri.queryParameters,
          },
        ),
      ),
      GoRoute(
        path: '/payment/fail',
        builder: (_, state) => PaymentFailPage(
          params: {
            ...launchQueryParams,
            ...Uri.base.queryParameters,
            ...state.uri.queryParameters,
          },
        ),
      ),
      GoRoute(path: '/seller', builder: (_, _) => const SellerHomePage()),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/billing',
          builder: (_, state) => BroadcastBillingPage(
            client: ref.read(supabaseClientProvider),
            sellerId:
                state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/purchases',
          builder: (_, state) => BroadcastPurchasesPage(
            client: ref.read(supabaseClientProvider),
            sellerId:
                state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/inventory',
          builder: (_, state) => BroadcastInventoryPage(
            client: ref.read(supabaseClientProvider),
            sellerId:
                state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/shipments',
          builder: (_, state) => BroadcastShipmentsPage(
            client: ref.read(supabaseClientProvider),
            sellerId:
                state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/receipts',
          builder: (_, state) => BroadcastReceiptsPage(
            client: ref.read(supabaseClientProvider),
            sellerId:
                state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/tasks',
          builder: (_, state) => BroadcastTasksPage(
            client: ref.read(supabaseClientProvider),
            sellerId:
                state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/requests',
          builder: (_, state) => BroadcastCustomerRequestsPage(
            client: ref.read(supabaseClientProvider),
            sellerId:
                state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast/join',
          builder: (_, state) => BroadcastStaffJoinPage(
            client: ref.read(supabaseClientProvider),
            initialCode: state.uri.queryParameters['code'],
          ),
        ),
      if (const bool.fromEnvironment('BROADCAST_ORDERS_ENABLED'))
        GoRoute(
          path: '/seller/broadcast',
          builder: (_, state) => BroadcastCapturePage(
            key: ValueKey(
              'broadcast-${authRepo.currentUser!.id}-${state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id}',
            ),
            repository: SupabaseBroadcastRepository(
              ref.read(supabaseClientProvider),
              state.uri.queryParameters['seller'] ?? authRepo.currentUser!.id,
            ),
            journal: SharedPreferencesCommandJournal(
              actorId: authRepo.currentUser!.id,
              sellerId:
                  state.uri.queryParameters['seller'] ??
                  authRepo.currentUser!.id,
            ),
          ),
        ),
      GoRoute(
        path: '/seller/product/new',
        builder: (_, _) => const ProductEditPage(),
      ),
      GoRoute(
        path: '/seller/product/:id',
        builder: (_, state) =>
            ProductEditPage(productId: state.pathParameters['id']),
      ),
      GoRoute(path: '/admin', builder: (_, _) => const AdminHomePage()),
      // 상품 등록은 셀러 전용. 관리자는 중재(수정/숨김)만 가능.
      GoRoute(
        path: '/admin/product/:id',
        builder: (_, state) =>
            ProductEditPage(productId: state.pathParameters['id']),
      ),
    ],
  );
});

/// Stream을 GoRouter의 refreshListenable로 변환
class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<dynamic> stream) {
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
