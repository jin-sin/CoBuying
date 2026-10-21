import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/broadcast_orders/broadcast_capture_page.dart';
import 'features/broadcast_orders/broadcast_repository.dart';
import 'features/broadcast_orders/shared_preferences_command_journal.dart';

void main() => runApp(
  MaterialApp(
    home: BroadcastCapturePage(
      repository: _BrowserRepository(),
      journal: SharedPreferencesCommandJournal(
        actorId: 'browser-test-actor',
        sellerId: 'browser-test-seller',
      ),
    ),
  ),
);

/// Only the browser storage/restart path is under test. The actual HTTP/JWT
/// path is exercised separately by http.test.mjs against PostgREST.
class _BrowserRepository implements BroadcastRepository {
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  @override
  Future<BroadcastWorkspace> load() async => BroadcastWorkspace(
    role: 'manager',
    customers: const [],
    orders: const [],
    sessions: [
      {
        'id': 'browser-test-session',
        'title': '재시작 검증 방송',
        'kind': 'new',
        'status': 'open',
        'broadcast_date': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 9))
            .toIso8601String()
            .substring(0, 10),
        'closes_at': '2099-01-01T00:00:00Z',
        'version': 1,
        'exchange_rate': 190,
        'shipping_krw': 4000,
        'shipping_cny_fen': 3000,
        'free_shipping_count': 5,
        'management_days': 3,
      },
    ],
    products: const [
      {
        'id': 'browser-test-product',
        'session_id': 'browser-test-session',
        'number': 27,
        'title': '데님조끼',
        'supplier': '테스트 거래처',
        'price_krw': 12000,
        'colors': ['검정'],
        'sizes': ['M'],
        'visible': true,
        'in_outfit': true,
        'public_order': 1,
        'deleted_at': null,
        'version': 1,
        'has_orders': false,
      },
    ],
  );

  @override
  Future<BroadcastRow> customerPage(
    String query, {
    String? afterNickname,
    String? afterId,
  }) async => {
    'items': query.isEmpty || '몽이맘'.contains(query)
        ? [
            {
              'id': 'browser-test-customer',
              'nickname': '몽이맘',
              'wechat_note': '기존 위챗',
            },
          ]
        : <BroadcastRow>[],
    'next_nickname': null,
    'next_id': null,
  };

  @override
  Future<BroadcastRow> orderPage(
    String sessionId, {
    int? beforeSequence,
  }) async => {'items': <BroadcastRow>[], 'next_before_sequence': null};

  @override
  Future<BroadcastRow> staffOverview() async => {'members': [], 'invites': []};

  @override
  Future<BroadcastRow> execute(BroadcastCommand command) async {
    final key = 'broadcast.fake-receipt.${command.key}';
    final saved = await _preferences.getString(key);
    if (saved == null) {
      await _preferences.setString(key, command.payload);
      throw StateError('simulated response loss after commit');
    }
    if (saved != command.payload)
      throw const BroadcastRejected('재시도 원문이 다릅니다.', '22023');
    return {'id': 'browser-test-result', 'key': command.key};
  }
}
