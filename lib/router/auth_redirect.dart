/// Preserve the in-app destination (including a broadcast invite code) across
/// authentication. The destination must remain an internal app route.
String? authRedirect(Uri uri, {required bool loggedIn}) {
  const authRequired = [
    '/cart', '/checkout', '/orders', '/seller', '/payment',
    '/notifications', '/wishlist', '/admin',
  ];
  final path = uri.path;
  final needsAuth = authRequired.any((prefix) => path.startsWith(prefix));
  if (needsAuth && !loggedIn) {
    return '/login?from=${Uri.encodeComponent(uri.toString())}';
  }
  if (path == '/login' && loggedIn) {
    final from = uri.queryParameters['from'];
    if (from != null && from.startsWith('/') && !from.startsWith('//')) {
      return from;
    }
    return '/';
  }
  return null;
}
