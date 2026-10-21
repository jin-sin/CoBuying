#!/bin/sh
# Exercise the unchanged production adapter without unrelated native hooks.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/orendam-adapter-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/lib/features/broadcast_orders" "$test_dir/tools/broadcast-tests"
cp "$project_dir/lib/features/broadcast_orders/broadcast_repository.dart" \
   "$project_dir/lib/features/broadcast_orders/supabase_broadcast_repository.dart" \
   "$test_dir/lib/features/broadcast_orders/"
cp "$project_dir/tools/broadcast-tests/adapter_integration_test.dart" "$test_dir/tools/broadcast-tests/"
cat > "$test_dir/pubspec.yaml" <<'SPEC'
name: cobuying
environment:
  sdk: ^3.10.4
dependencies:
  flutter:
    sdk: flutter
  supabase_flutter: 2.16.0
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  uses-material-design: true
SPEC
cd "$test_dir"
flutter pub get >/dev/null
flutter test --no-pub tools/broadcast-tests/adapter_integration_test.dart
