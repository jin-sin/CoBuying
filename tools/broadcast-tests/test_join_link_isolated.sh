#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/orendam-join-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/lib/features/auth" "$test_dir/lib/features/broadcast_orders" "$test_dir/lib/core" "$test_dir/lib/router" "$test_dir/tools/broadcast-tests"
cp "$project_dir/lib/features/auth/login_page.dart" "$test_dir/lib/features/auth/"
cp "$project_dir/lib/features/broadcast_orders/broadcast_staff_join_page.dart" "$test_dir/lib/features/broadcast_orders/"
cp "$project_dir/lib/core/brand.dart" "$project_dir/lib/core/theme.dart" "$project_dir/lib/core/service_brand.dart" "$test_dir/lib/core/"
cp "$project_dir/lib/router/auth_redirect.dart" "$test_dir/lib/router/"
cp "$project_dir/tools/broadcast-tests/join_link_test.dart" "$test_dir/tools/broadcast-tests/"
cat > "$test_dir/lib/features/auth/auth_providers.dart" <<'STUB'
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
late SupabaseClient testClient;
final supabaseClientProvider = Provider<SupabaseClient>((_) => testClient);
final authRepositoryProvider = Provider<TestAuthRepository>((_) => TestAuthRepository(testClient));
class TestAuthRepository {
  TestAuthRepository(this.client);
  final SupabaseClient client;
  User? get currentUser => client.auth.currentUser;
  Future<void> signInWithKakao() => throw UnimplementedError();
}
STUB
cat > "$test_dir/pubspec.yaml" <<'SPEC'
name: cobuying
environment:
  sdk: ^3.10.4
dependencies:
  flutter:
    sdk: flutter
  flutter_riverpod: ^3.3.2
  go_router: ^17.3.0
  supabase_flutter: ^2.16.0
  http: ^1.6.0
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  uses-material-design: true
SPEC
cd "$test_dir"
flutter test --dart-define=BROADCAST_TEST_AUTH=true tools/broadcast-tests/join_link_test.dart
