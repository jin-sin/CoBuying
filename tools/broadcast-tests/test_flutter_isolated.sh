#!/bin/sh
# Test unchanged broadcast widgets without unrelated native plugin build hooks.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/orendam-widget-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/lib/features/broadcast_orders" "$test_dir/lib/core" "$test_dir/test"
cp "$project_dir/lib/features/broadcast_orders/broadcast_capture_page.dart" "$project_dir/lib/features/broadcast_orders/broadcast_repository.dart" "$project_dir/lib/features/broadcast_orders/shared_preferences_command_journal.dart" "$test_dir/lib/features/broadcast_orders/"
cp "$project_dir/lib/core/service_brand.dart" "$test_dir/lib/core/"
cp "$project_dir/test/broadcast_capture_test.dart" "$test_dir/test/"
cat > "$test_dir/pubspec.yaml" <<'SPEC'
name: cobuying
environment:
  sdk: ^3.10.4
dependencies:
  flutter:
    sdk: flutter
  shared_preferences: ^2.5.5
dev_dependencies:
  flutter_test:
    sdk: flutter
  shared_preferences_platform_interface: ^2.4.2
flutter:
  uses-material-design: true
SPEC
cd "$test_dir"
flutter test test/broadcast_capture_test.dart
