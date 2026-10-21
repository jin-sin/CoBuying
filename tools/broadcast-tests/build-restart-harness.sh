#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
test_dir="$project_dir/tools/broadcast-tests/.cache/restart-web"
mkdir -p "$test_dir/lib/features/broadcast_orders" "$test_dir/lib/core" "$test_dir/web"
cp "$project_dir/lib/features/broadcast_orders/broadcast_capture_page.dart" "$project_dir/lib/features/broadcast_orders/broadcast_repository.dart" "$project_dir/lib/features/broadcast_orders/shared_preferences_command_journal.dart" "$test_dir/lib/features/broadcast_orders/"
cp "$project_dir/lib/core/service_brand.dart" "$test_dir/lib/core/"
cp "$project_dir/tools/broadcast-tests/restart_harness_main.dart" "$test_dir/lib/main.dart"
cat > "$test_dir/pubspec.yaml" <<'SPEC'
name: cobuying
environment:
  sdk: ^3.10.4
dependencies:
  flutter:
    sdk: flutter
  shared_preferences: ^2.5.5
flutter:
  uses-material-design: true
SPEC
cat > "$test_dir/web/index.html" <<'HTML'
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>방송 재시작 시험</title></head><body><script src="flutter_bootstrap.js" async></script></body></html>
HTML
cd "$test_dir"
flutter pub get
flutter build web --no-pub
echo "$test_dir/build/web"
