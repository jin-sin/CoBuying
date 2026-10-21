import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cobuying/features/broadcast_orders/broadcast_capture_page.dart';
import 'package:cobuying/features/broadcast_orders/broadcast_repository.dart';
import 'package:cobuying/features/broadcast_orders/shared_preferences_command_journal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class MemoryJournal implements BroadcastCommandJournal {
  BroadcastCommand? value;
  bool failSave = false;
  @override
  Future<BroadcastCommand?> load() async => value;
  @override
  Future<void> save(BroadcastCommand command) async {
    if (failSave) throw StateError('disk unavailable');
    if (value != null && value!.key != command.key) throw StateError('pending');
    value = command;
  }

  @override
  Future<void> clear(BroadcastCommand command) async {
    if (value?.key == command.key) value = null;
  }
}

class TestRepository implements BroadcastRepository {
  final commands = <BroadcastCommand>[];
  final customerQueries = <String>[];
  bool failNext = false;
  final members = <BroadcastRow>[];
  final invites = <BroadcastRow>[];
  @override
  Future<BroadcastRow> customerPage(
    String query, {
    String? afterNickname,
    String? afterId,
  }) async {
    customerQueries.add(query);
    return {
      'items': query.isEmpty || '몽이맘'.contains(query)
          ? [
              {'id': 'c', 'nickname': '몽이맘', 'wechat_note': '확인된 위챗'},
            ]
          : <BroadcastRow>[],
      'next_nickname': null,
      'next_id': null,
    };
  }

  @override
  Future<BroadcastRow> orderPage(
    String sessionId, {
    int? beforeSequence,
  }) async => {'items': <BroadcastRow>[], 'next_before_sequence': null};
  @override
  Future<BroadcastRow> staffOverview() async => {
    'members': members,
    'invites': invites,
  };
  @override
  Future<BroadcastWorkspace> load() async => const BroadcastWorkspace(
    role: 'manager',
    customers: [
      {'id': 'c', 'nickname': '몽이맘', 'wechat_note': '확인된 위챗'},
    ],
    sessions: [
      {
        'id': 's',
        'title': '신상 방송',
        'status': 'open',
        'broadcast_date': '2026-09-28',
        'closes_at': '2099-01-01T00:00:00Z',
        'version': 1,
        'kind': 'new',
        'exchange_rate': 190,
        'shipping_krw': 4000,
        'shipping_cny_fen': 3000,
        'free_shipping_count': 5,
        'management_days': 3,
      },
    ],
    products: [
      {
        'id': 'p',
        'session_id': 's',
        'number': 27,
        'title': '데님조끼',
        'supplier': '마루',
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
    orders: [],
  );
  @override
  Future<BroadcastRow> execute(BroadcastCommand command) async {
    commands.add(command);
    if (failNext) {
      failNext = false;
      throw Exception('response lost');
    }
    if (command.name == 'staff.invite') {
      final invite = {
        'code': '11111111-1111-4111-8111-111111111111',
        'expires_at': '2099-01-01T00:00:00Z',
      };
      invites.add(invite);
      return invite;
    }
    if (command.name == 'staff.remove') {
      members.removeWhere((m) => m['user_id'] == command.data['user_id']);
      return {'removed': true};
    }
    return {'id': command.name.startsWith('session.') ? 's' : 'saved'};
  }
}

void main() {
  test('기기 기록은 배우/판매자 범위가 다르고 같은 키만 정리한다', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final preferences = SharedPreferencesAsync();
    final one = SharedPreferencesCommandJournal(
      actorId: 'actor-1',
      sellerId: 'seller-1',
      preferences: preferences,
    );
    final otherActor = SharedPreferencesCommandJournal(
      actorId: 'actor-2',
      sellerId: 'seller-1',
      preferences: preferences,
    );
    final otherSeller = SharedPreferencesCommandJournal(
      actorId: 'actor-1',
      sellerId: 'seller-2',
      preferences: preferences,
    );
    final command = BroadcastCommand('order.create', {'quantity': 1});
    await one.save(command);
    expect((await one.load())!.key, command.key);
    expect((await one.load())!.payload, command.payload);
    expect(await otherActor.load(), isNull);
    expect(await otherSeller.load(), isNull);
    await expectLater(
      one.save(BroadcastCommand('order.create', {'quantity': 2})),
      throwsStateError,
    );
    await expectLater(
      one.clear(BroadcastCommand('order.create', {'quantity': 1})),
      throwsStateError,
    );
    await one.clear(command);
    expect(await one.load(), isNull);
  });
  test('명령은 입력 스냅샷을 유지하고 새 저장은 새 UUID를 사용한다', () {
    final input = {'quantity': 1};
    final a = BroadcastCommand('order.create', input);
    input['quantity'] = 2;
    expect(a.data['quantity'], 1);
    expect(a.key, isNot(BroadcastCommand('order.create', {'quantity': 1}).key));
    expect(
      a.key,
      matches(
        RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ),
      ),
    );
  });
  testWidgets('재시작 후 미확인 명령은 같은 키와 원문으로만 재전송된다', (tester) async {
    final repo = TestRepository();
    final journal = MemoryJournal();
    final original = BroadcastCommand('order.create', {
      'session_id': 's',
      'customer_id': 'c',
      'product_id': 'p',
      'color': '검정',
      'size': 'M',
      'quantity': 1,
    });
    await journal.save(original);
    await tester.pumpWidget(
      MaterialApp(
        home: BroadcastCapturePage(repository: repo, journal: journal),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('이전 저장의 결과'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('주문 1건 저장'),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('저장 결과 다시 확인'));
    await tester.pumpAndSettle();
    expect(repo.commands.single.key, original.key);
    expect(repo.commands.single.payload, original.payload);
    expect(await journal.load(), isNull);
  });
  testWidgets('기기 보관 실패 시 서버에 전송하지 않는다', (tester) async {
    final repo = TestRepository();
    final journal = MemoryJournal()..failSave = true;
    await tester.pumpWidget(
      MaterialApp(
        home: BroadcastCapturePage(repository: repo, journal: journal),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '고객 닉네임 검색'), '몽');
    await tester.pumpAndSettle();
    await tester.tap(find.text('몽이맘'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('주문 상품'));
    await tester.tap(find.text('주문 상품'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('27번 · 데님조끼').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('주문 1건 저장'));
    await tester.tap(find.text('주문 1건 저장'));
    await tester.pumpAndSettle();
    expect(repo.commands, isEmpty);
    expect(find.textContaining('서버 전송은 시작하지'), findsOneWidget);
  });
  testWidgets('판매자 화면에서 보조 참여 코드 생성과 접근 회수', (tester) async {
    final repo = TestRepository()
      ..members.add({
        'user_id': '22222222-2222-4222-8222-222222222222',
        'role': 'assistant',
      });
    await tester.pumpWidget(
      MaterialApp(
        home: BroadcastCapturePage(repository: repo, journal: MemoryJournal()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('방송·고객'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('보조 참여 코드 만들기'));
    await tester.tap(find.text('보조 참여 코드 만들기'));
    await tester.pumpAndSettle();
    expect(repo.commands.last.name, 'staff.invite');
    expect(find.text('사용 가능한 참여 코드'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('담당자 접근 회수'));
    await tester.tap(find.byTooltip('담당자 접근 회수'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('접근 회수'));
    await tester.pumpAndSettle();
    expect(repo.commands.last.name, 'staff.remove');
    expect(
      repo.commands.last.data['user_id'],
      '22222222-2222-4222-8222-222222222222',
    );
  });
  testWidgets('모바일 검색·저장, 응답 유실 재시도 키 보존, 반복 주문 새 키', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = TestRepository()..failNext = true;
    await tester.pumpWidget(
      MaterialApp(
        home: BroadcastCapturePage(repository: repo, journal: MemoryJournal()),
      ),
    );
    await tester.pumpAndSettle();
    final search = find.widgetWithText(TextField, '고객 닉네임 검색');
    await tester.enterText(search, '몽');
    await tester.pumpAndSettle();
    expect(repo.customerQueries, contains('몽'));
    await tester.tap(find.text('몽이맘'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('주문 상품'));
    await tester.tap(find.text('주문 상품'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('27번 · 데님조끼').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('주문 1건 저장'));
    await tester.tap(find.text('주문 1건 저장'));
    await tester.pumpAndSettle();
    expect(repo.commands.length, 1);
    expect(find.textContaining('저장 결과를 확인하지'), findsOneWidget);
    await tester.ensureVisible(find.text('저장 결과 다시 확인'));
    await tester.tap(find.text('저장 결과 다시 확인'));
    await tester.pumpAndSettle();
    expect(repo.commands.length, 2);
    expect(repo.commands[0].key, repo.commands[1].key);
    expect(repo.commands[1].data['quantity'], 1);
    await tester.ensureVisible(search);
    await tester.enterText(search, '몽');
    await tester.pumpAndSettle();
    await tester.tap(find.text('몽이맘'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('주문 1건 저장'));
    await tester.tap(find.text('주문 1건 저장'));
    await tester.pumpAndSettle();
    expect(repo.commands.length, 3);
    expect(repo.commands[2].key, isNot(repo.commands[1].key));
    expect(repo.commands[2].data['color'], '검정');
    expect(tester.takeException(), isNull);
  });
  testWidgets('모바일 상품 정정과 방송 마감이 실제 명령으로 전달된다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = TestRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: BroadcastCapturePage(repository: repo, journal: MemoryJournal()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('상품').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('상품 수정'));
    await tester.tap(find.text('상품 수정'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '제품명'), '니트 조끼');
    await tester.enterText(
      find.widgetWithText(TextFormField, '가격 (원)'),
      '12500',
    );
    await tester.tap(find.text('택포 제외'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장').last);
    await tester.pumpAndSettle();
    expect(repo.commands.last.name, 'product.update');
    expect(repo.commands.last.data['title'], '니트 조끼');
    expect(repo.commands.last.data['price_krw'], 12500);
    expect(repo.commands.last.data['shipping_excluded'], true);
    await tester.ensureVisible(find.text('방송·고객'));
    await tester.tap(find.text('방송·고객'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('선택 방송 설정·마감'));
    await tester.tap(find.text('선택 방송 설정·마감'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '상태 (준비/접수/마감)'),
      '마감',
    );
    await tester.tap(find.text('저장').last);
    await tester.pumpAndSettle();
    expect(repo.commands.last.name, 'session.update');
    expect(repo.commands.last.data['status'], 'closed');
    expect(repo.commands.last.data['broadcast_date'], '2026-09-28');
    expect(tester.takeException(), isNull);
  });
}
