import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../lib/features/broadcast_orders/broadcast_repository.dart';
import '../../lib/features/broadcast_orders/supabase_broadcast_repository.dart';

void main() {
  test('실제 SupabaseBroadcastRepository → HTTP → RPC', () async {
    final env = Platform.environment;
    String required(String name) {
      final value = env[name];
      if (value == null || value.isEmpty) {
        throw StateError('$name is required by npm run test:adapter');
      }
      return value;
    }

    final url = required('BROADCAST_TEST_URL');
    final owner = required('BROADCAST_TEST_OWNER');
    final apiKey = env['BROADCAST_TEST_API_KEY'] ?? 'local-test-key';
    final client = SupabaseClient(
      url,
      apiKey,
      accessToken: () async => required('BROADCAST_TEST_OWNER_JWT'),
    );
    final repo = SupabaseBroadcastRepository(client, owner);
    try {
      final workspace = await repo.load();
      expect(workspace.role, 'manager');
      expect(workspace.orders, isEmpty);
      expect(workspace.products.any((row) => row['id'] == required('BROADCAST_TEST_PRODUCT') && row['has_orders'] == true), isTrue);

      final customers = await repo.customerPage(env['BROADCAST_TEST_CUSTOMER_QUERY'] ?? '몽');
      expect((customers['items'] as List).first['id'], required('BROADCAST_TEST_CUSTOMER'));
      final orders = await repo.orderPage(required('BROADCAST_TEST_SESSION'));
      expect((orders['items'] as List).length, greaterThanOrEqualTo(21));

      final command = BroadcastCommand('order.create', {
        'session_id': required('BROADCAST_TEST_SESSION'),
        'customer_id': required('BROADCAST_TEST_CUSTOMER'),
        'product_id': required('BROADCAST_TEST_PRODUCT'),
        'color': '검정', 'size': 'M', 'quantity': 1,
      });
      final first = await repo.execute(command);
      final retry = await repo.execute(command);
      expect(retry['id'], first['id']);
      expect((await repo.staffOverview())['members'], isA<List>());

      final stranger = SupabaseClient(
        url,
        apiKey,
        accessToken: () async => required('BROADCAST_TEST_STRANGER_JWT'),
      );
      try {
        await expectLater(
          SupabaseBroadcastRepository(stranger, owner).load(),
          throwsA(isA<PostgrestException>()),
        );
      } finally {
        stranger.dispose();
      }
    } finally {
      client.dispose();
    }
  });
}
