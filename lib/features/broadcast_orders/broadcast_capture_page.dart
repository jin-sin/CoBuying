import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/service_brand.dart';
import 'broadcast_repository.dart';

class BroadcastCapturePage extends StatefulWidget {
  const BroadcastCapturePage({
    super.key,
    required this.repository,
    required this.journal,
  });
  final BroadcastRepository repository;
  final BroadcastCommandJournal journal;
  @override
  State<BroadcastCapturePage> createState() => _BroadcastCapturePageState();
}

class _BroadcastCapturePageState extends State<BroadcastCapturePage> {
  late final BroadcastRepository repo;
  BroadcastWorkspace? data;
  BroadcastRow? staff;
  List<BroadcastRow> customers = [], matches = [], orderRows = [];
  String? customerNextName, customerNextId;
  String? matchNextName, matchNextId;
  int? orderNextSequence;
  bool customerPageLoading = false,
      orderPageLoading = false,
      searchLoading = false,
      matchPageLoading = false;
  String? listError;
  Timer? searchTimer;
  int searchGeneration = 0;
  String? error, sessionId, customerId, productId;
  String? staffError;
  final search = TextEditingController(), color = TextEditingController();
  final size = TextEditingController(),
      quantity = TextEditingController(text: '1');
  final note = TextEditingController();
  final searchFocus = FocusNode();
  int tab = 0;
  bool loading = true, saving = false, journalReady = false;
  String? journalError;
  BroadcastCommand? pending;
  void Function(BroadcastRow)? pendingSuccess;

  @override
  void initState() {
    super.initState();
    repo = widget.repository;
    _initialize();
  }

  Future<void> _initialize() async {
    await _restore();
    await _load();
  }

  Future<void> _restore() async {
    try {
      final saved = await widget.journal.load();
      if (!mounted) return;
      setState(() {
        pending = saved;
        pendingSuccess = null;
        journalReady = true;
        journalError = null;
        if (saved != null) {
          error = '이전 저장의 결과가 확인되지 않았습니다. 같은 요청으로 다시 확인해주세요.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        journalReady = false;
        journalError = '기기에 저장된 미확인 요청을 읽지 못했습니다. 새 주문을 접수하기 전에 다시 확인해주세요.';
      });
    }
  }

  @override
  void dispose() {
    searchTimer?.cancel();
    for (final c in [search, color, size, quantity, note]) {
      c.dispose();
    }
    searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final next = await repo.load();
      final selected =
          sessionId ??
          (next.sessions.isEmpty ? null : next.sessions.first['id'] as String);
      final customerResult = await repo.customerPage('');
      final orderResult = selected == null
          ? null
          : await repo.orderPage(selected);
      BroadcastRow? nextStaff;
      String? nextStaffError;
      if (next.role == 'manager') {
        try {
          nextStaff = await repo.staffOverview();
        } catch (_) {
          nextStaffError = '담당자 목록을 불러오지 못했습니다. 새로고침으로 다시 확인해주세요.';
        }
      }
      if (!mounted) return;
      setState(() {
        data = next;
        customers = _pageRows(customerResult);
        customerNextName = customerResult['next_nickname'] as String?;
        customerNextId = customerResult['next_id'] as String?;
        orderRows = orderResult == null ? [] : _pageRows(orderResult);
        orderNextSequence = orderResult?['next_before_sequence'] as int?;
        listError = null;
        staff = nextStaff;
        staffError = nextStaffError;
        if (pending == null) error = null;
        loading = false;
        sessionId = selected;
        if (productId != null &&
            !next.products.any(
              (p) => p['id'] == productId && p['deleted_at'] == null,
            )) {
          productId = null;
        }
      });
      if (search.text.trim().isNotEmpty) _searchCustomers(search.text);
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '방송 데이터를 불러오지 못했습니다. 접속과 권한을 확인해주세요.';
        });
      }
    }
  }

  List<BroadcastRow> _pageRows(BroadcastRow result) => (result['items'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  Future<void> _moreCustomers() async {
    if (customerPageLoading || customerNextId == null) return;
    setState(() => customerPageLoading = true);
    try {
      final page = await repo.customerPage(
        '',
        afterNickname: customerNextName,
        afterId: customerNextId,
      );
      if (!mounted) return;
      setState(() {
        customers.addAll(_pageRows(page));
        customerNextName = page['next_nickname'] as String?;
        customerNextId = page['next_id'] as String?;
      });
    } catch (_) {
      if (mounted) {
        setState(() => listError = '고객 목록을 더 불러오지 못했습니다. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => customerPageLoading = false);
    }
  }

  Future<void> _moreOrders() async {
    if (orderPageLoading || orderNextSequence == null || sessionId == null) {
      return;
    }
    final selected = sessionId!;
    setState(() => orderPageLoading = true);
    try {
      final page = await repo.orderPage(
        selected,
        beforeSequence: orderNextSequence,
      );
      if (!mounted || sessionId != selected) return;
      setState(() {
        orderRows.addAll(_pageRows(page));
        orderNextSequence = page['next_before_sequence'] as int?;
      });
    } catch (_) {
      if (mounted) {
        setState(() => listError = '주문 기록을 더 불러오지 못했습니다. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => orderPageLoading = false);
    }
  }

  Future<void> _selectSession(String? id) async {
    setState(() {
      sessionId = id;
      productId = null;
      orderRows = [];
      orderNextSequence = null;
    });
    if (id == null) return;
    try {
      final page = await repo.orderPage(id);
      if (!mounted || sessionId != id) return;
      setState(() {
        orderRows = _pageRows(page);
        orderNextSequence = page['next_before_sequence'] as int?;
      });
    } catch (_) {
      if (mounted) setState(() => listError = '주문 기록을 불러오지 못했습니다. 새로고침해주세요.');
    }
  }

  void _searchCustomers(String value) {
    searchTimer?.cancel();
    final generation = ++searchGeneration;
    setState(() {
      customerId = null;
      matches = [];
      matchNextName = null;
      matchNextId = null;
      searchLoading = value.trim().isNotEmpty;
    });
    if (value.trim().isEmpty) return;
    searchTimer = Timer(const Duration(milliseconds: 250), () async {
      try {
        final page = await repo.customerPage(value.trim());
        if (!mounted || generation != searchGeneration) return;
        setState(() {
          matches = _pageRows(page);
          matchNextName = page['next_nickname'] as String?;
          matchNextId = page['next_id'] as String?;
          searchLoading = false;
        });
      } catch (_) {
        if (!mounted || generation != searchGeneration) return;
        setState(() {
          searchLoading = false;
          listError = '고객 검색에 실패했습니다. 다시 입력해주세요.';
        });
      }
    });
  }

  Future<void> _moreMatches() async {
    if (matchPageLoading || matchNextId == null) return;
    final generation = searchGeneration;
    setState(() => matchPageLoading = true);
    try {
      final page = await repo.customerPage(
        search.text.trim(),
        afterNickname: matchNextName,
        afterId: matchNextId,
      );
      if (!mounted || generation != searchGeneration) return;
      setState(() {
        matches.addAll(_pageRows(page));
        matchNextName = page['next_nickname'] as String?;
        matchNextId = page['next_id'] as String?;
      });
    } catch (_) {
      if (mounted && generation == searchGeneration) {
        setState(() => listError = '검색 결과를 더 불러오지 못했습니다. 다시 시도해주세요.');
      }
    } finally {
      if (mounted) setState(() => matchPageLoading = false);
    }
  }

  Future<void> _send(
    String command,
    BroadcastRow payload, {
    void Function(BroadcastRow)? success,
  }) async {
    if (locked) return;
    final next = BroadcastCommand(command, payload);
    setState(() {
      pending = next;
      pendingSuccess = success;
      saving = true;
    });
    try {
      await widget.journal.save(next);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        saving = false;
        journalReady = false;
        journalError =
            '요청을 기기에 보관하지 못했습니다. 서버 전송은 시작하지 않았습니다. 저장소 상태를 다시 확인해주세요.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => saving = false);
    await _retry();
  }

  Future<void> _retry() async {
    if (saving || !journalReady || pending == null) return;
    setState(() {
      saving = true;
      error = null;
    });
    BroadcastRow result;
    try {
      result = await repo.execute(pending!);
    } on BroadcastRejected catch (e) {
      if (!mounted) return;
      try {
        await widget.journal.clear(pending!);
      } catch (_) {
        if (mounted) {
          setState(() {
            saving = false;
            journalReady = false;
            journalError = '거절된 요청의 기기 기록을 정리하지 못했습니다. 다시 확인해주세요.';
          });
        }
        return;
      }
      if (!mounted) return;
      // A definite server rejection did not commit; allow correcting the form.
      setState(() {
        saving = false;
        pending = null;
        pendingSuccess = null;
        error = e.message;
      });
      await _reloadAfterConflict(e.code);
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '저장 결과를 확인하지 못했습니다. 아래 버튼으로 같은 요청을 다시 확인해주세요.';
        });
      }
      return; // Preserve the key AND exact payload; do not permit another save.
    }
    if (!mounted) return;
    try {
      await widget.journal.clear(pending!);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          journalReady = false;
          journalError = '서버 저장은 확인됐지만 기기 기록을 정리하지 못했습니다. 다시 확인해주세요.';
        });
      }
      return;
    }
    if (!mounted) return;
    final done = pendingSuccess;
    setState(() {
      saving = false;
      pending = null;
      pendingSuccess = null;
    });
    done?.call(result);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('저장했습니다')));
    await _load();
  }

  Future<void> _reloadAfterConflict(String? code) async {
    if (code == '40001') await _load();
  }

  bool get locked => !journalReady || saving || pending != null;
  List<BroadcastRow> get products =>
      data!.products.where((p) => p['session_id'] == sessionId).toList()..sort(
        (a, b) =>
            (a['public_order'] as int).compareTo(b['public_order'] as int),
      );
  List<BroadcastRow> get activeProducts =>
      products.where((p) => p['deleted_at'] == null).toList();
  BroadcastRow? get currentSession =>
      data!.sessions.where((s) => s['id'] == sessionId).firstOrNull;
  bool get intakeOpen {
    final session = currentSession;
    if (session == null || session['status'] != 'open') return false;
    final starts = DateTime.tryParse(
      '${session['broadcast_date']}T00:00:00+09:00',
    );
    final ends = DateTime.tryParse('${session['closes_at']}');
    final now = DateTime.now();
    return starts != null &&
        !starts.isAfter(now) &&
        ends != null &&
        ends.isAfter(now);
  }

  List<BroadcastRow> get orders => orderRows;
  String customerName(BroadcastRow order) =>
      order['nickname'] as String? ?? '고객';
  Widget field(
    String label,
    TextEditingController controller, {
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      enabled: !locked,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly] : null,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !locked,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('${ServiceBrand.shortName} · 방송 입력'),
        actions: [
          if (data?.role == 'manager')
            IconButton(
              onPressed: locked
                  ? null
                  : () => context.go('/seller/broadcast/receipts'),
              icon: const Icon(Icons.payments_outlined),
              tooltip: '입금 확인',
            ),
          if (data?.role == 'manager')
            IconButton(
              onPressed: locked
                  ? null
                  : () => context.go('/seller/broadcast/tasks'),
              icon: const Icon(Icons.notifications_active_outlined),
              tooltip: '처리할 일',
            ),
          if (data?.role == 'manager')
            IconButton(
              onPressed: locked
                  ? null
                  : () => context.go('/seller/broadcast/requests'),
              icon: const Icon(Icons.fact_check_outlined),
              tooltip: '고객 요청',
            ),
          if (data?.role == 'manager')
            IconButton(
              onPressed: locked
                  ? null
                  : () => context.go('/seller/broadcast/purchases'),
              icon: const Icon(Icons.inventory_2_outlined),
              tooltip: '발주·내보내기',
            ),
          if (data?.role == 'manager')
            IconButton(
              onPressed: locked
                  ? null
                  : () => context.go('/seller/broadcast/inventory'),
              icon: const Icon(Icons.move_to_inbox_outlined),
              tooltip: '입고·미송',
            ),
          if (data?.role == 'manager')
            IconButton(
              onPressed: locked
                  ? null
                  : () => context.go('/seller/broadcast/shipments'),
              icon: const Icon(Icons.local_shipping_outlined),
              tooltip: '부분출고·송장',
            ),
          if (data?.role == 'manager')
            IconButton(
              onPressed: locked
                  ? null
                  : () => context.go('/seller/broadcast/billing'),
              icon: const Icon(Icons.receipt_long_outlined),
              tooltip: '정산서',
            ),
          IconButton(
            onPressed: locked ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '개발 중 · 직원 주문 접수 기능',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Text('정산·발주·배송은 시험 구현 중이며 운영 적용 전 검증이 필요합니다.'),
                      const SizedBox(height: 12),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (listError != null)
                        Text(
                          listError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (journalError != null) ...[
                        Text(
                          journalError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        OutlinedButton(
                          onPressed: saving ? null : _restore,
                          child: const Text('기기 저장소 다시 확인'),
                        ),
                      ],
                      if (pending != null)
                        FilledButton(
                          onPressed: saving || !journalReady ? null : _retry,
                          child: Text(saving ? '저장 확인 중…' : '저장 결과 다시 확인'),
                        ),
                      if (data != null) ...[
                        DropdownButtonFormField<String>(
                          initialValue: sessionId,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '방송'),
                          items: data!.sessions
                              .map(
                                (s) => DropdownMenuItem<String>(
                                  value: s['id'] as String,
                                  child: Text(
                                    s['title'] as String,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: locked ? null : _selectSession,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: List.generate(
                            4,
                            (i) => ChoiceChip(
                              label: Text(['빠른 입력', '상품', '주문 기록', '방송·고객'][i]),
                              selected: tab == i,
                              onSelected: locked
                                  ? null
                                  : (_) => setState(() => tab = i),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (tab == 0) ..._capture(),
                        if (tab == 1) ..._products(),
                        if (tab == 2) ..._orders(),
                        if (tab == 3) ..._setup(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    ),
  );
  List<Widget> _capture() => [
    if (!intakeOpen)
      const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text('이 방송은 준비 중이거나 접수가 마감됐습니다. 방송 설정을 확인해주세요.'),
      ),
    TextField(
      controller: search,
      focusNode: searchFocus,
      enabled: !locked,
      decoration: const InputDecoration(
        labelText: '고객 닉네임 검색',
        hintText: '몽',
        prefixIcon: Icon(Icons.search),
        border: OutlineInputBorder(),
      ),
      onChanged: _searchCustomers,
    ),
    const SizedBox(height: 8),
    if (searchLoading) const LinearProgressIndicator(),
    ...matches.map(
      (c) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(c['nickname'] as String),
        subtitle: Text(c['wechat_note'] as String),
        selected: customerId == c['id'],
        trailing: customerId == c['id'] ? const Icon(Icons.check_circle) : null,
        onTap: locked
            ? null
            : () => setState(() => customerId = c['id'] as String),
      ),
    ),
    if (matchNextId != null)
      OutlinedButton(
        onPressed: matchPageLoading ? null : _moreMatches,
        child: Text(matchPageLoading ? '불러오는 중…' : '검색 결과 더 보기'),
      ),
    TextButton(
      onPressed: locked ? null : _newCustomer,
      child: const Text('새 고객 등록'),
    ),
    DropdownButtonFormField<String>(
      key: ValueKey('product-$sessionId-$productId'),
      initialValue: productId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '주문 상품',
        border: OutlineInputBorder(),
      ),
      items: activeProducts
          .map(
            (p) => DropdownMenuItem<String>(
              value: p['id'] as String,
              child: Text(
                '${p['number']}번 · ${p['title']}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: locked
          ? null
          : (id) => setState(() {
              productId = id;
              final p = activeProducts.firstWhere((p) => p['id'] == id);
              color.text = (p['colors'] as List).firstOrNull?.toString() ?? '';
              size.text = (p['sizes'] as List).firstOrNull?.toString() ?? '';
            }),
    ),
    const SizedBox(height: 12),
    field('컬러', color),
    field('사이즈', size),
    field('수량', quantity, number: true),
    field('특이사항 (선택)', note),
    FilledButton(
      onPressed:
          locked || !intakeOpen || customerId == null || productId == null
          ? null
          : () {
              final q = int.tryParse(quantity.text);
              if (q == null || q < 1 || q > 999) {
                setState(() => error = '수량은 1~999로 입력해주세요.');
                return;
              }
              _send(
                'order.create',
                {
                  'session_id': sessionId,
                  'customer_id': customerId,
                  'product_id': productId,
                  'color': color.text.trim(),
                  'size': size.text.trim(),
                  'quantity': q,
                  'note': note.text,
                },
                success: (_) {
                  searchTimer?.cancel();
                  searchGeneration++;
                  setState(() {
                    customerId = null;
                    search.clear();
                    matches = [];
                    matchNextName = null;
                    matchNextId = null;
                    searchLoading = false;
                    note.clear();
                    quantity.text = '1';
                  });
                  searchFocus.requestFocus();
                },
              );
            },
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Text('주문 1건 저장'),
      ),
    ),
    const SizedBox(height: 8),
    const Text('같은 상품을 다시 주문해도 별도 행으로 저장합니다. 상품·옵션은 다음 입력에 유지됩니다.'),
  ];
  List<Widget> _products() => [
    FilledButton(
      onPressed:
          locked ||
              sessionId == null ||
              !['draft', 'open'].contains(currentSession?['status'])
          ? null
          : _newProduct,
      child: const Text('상품 빠른 등록'),
    ),
    const Text(
      '사진 없이 등록합니다. 상품을 수정하면 비공개로 돌아가며 다시 공개해야 합니다. 접수 뒤에는 상품 원본을 잠급니다.',
    ),
    ...products.asMap().entries.map((entry) {
      final p = entry.value;
      final deleted = p['deleted_at'] != null;
      final activeIndex = activeProducts.indexWhere((x) => x['id'] == p['id']);
      final hasOrders = p['has_orders'] == true;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${p['number']}번 · ${p['title']}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text('${p['supplier']} · ₩${p['price_krw']}'),
              if (p['shipping_excluded'] == true) const Text('택포 계산 제외'),
              if (p['quantity_limited'] == true)
                Text('판매 가능 수량 ${p['available_quantity']} · 자동 품절은 후속'),
              if (deleted) const Text('삭제된 상품 · 번호 보존'),
              if (!deleted) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('고객 공개'),
                  value: p['visible'] as bool,
                  onChanged: locked
                      ? null
                      : (v) => _publish(p, v, v && (p['in_outfit'] as bool)),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('현재 코디에 함께 표시'),
                  value: p['in_outfit'] as bool,
                  onChanged: locked || !(p['visible'] as bool)
                      ? null
                      : (v) => _publish(p, true, v!),
                ),
              ],
              Wrap(
                spacing: 8,
                children: [
                  if (!deleted && !hasOrders)
                    TextButton(
                      onPressed: locked ? null : () => _productForm(p),
                      child: const Text('상품 수정'),
                    ),
                  if (!deleted && !hasOrders)
                    TextButton(
                      onPressed: locked
                          ? null
                          : () => _productCommand('product.archive', p),
                      child: const Text('삭제'),
                    ),
                  if (deleted)
                    TextButton(
                      onPressed: locked
                          ? null
                          : () => _productCommand('product.restore', p),
                      child: const Text('복구'),
                    ),
                  if (!deleted && activeIndex > 0)
                    TextButton(
                      onPressed: locked
                          ? null
                          : () => _productCommand(
                              'product.reorder',
                              p,
                              direction: 'up',
                            ),
                      child: const Text('순서 위로'),
                    ),
                  if (!deleted && activeIndex < activeProducts.length - 1)
                    TextButton(
                      onPressed: locked
                          ? null
                          : () => _productCommand(
                              'product.reorder',
                              p,
                              direction: 'down',
                            ),
                      child: const Text('순서 아래로'),
                    ),
                ],
              ),
              if (hasOrders) const Text('접수 이력 있음 · 주문은 고객별 정정'),
            ],
          ),
        ),
      );
    }),
  ];
  void _productCommand(String command, BroadcastRow p, {String? direction}) =>
      _send(
        command,
        {'id': p['id'], 'version': p['version'], 'direction': direction},
        success: (_) {
          if (command == 'product.archive' && productId == p['id']) {
            setState(() => productId = null);
          }
        },
      );
  void _publish(BroadcastRow p, bool visible, bool outfit) =>
      _send('product.publish', {
        'id': p['id'],
        'version': p['version'],
        'visible': visible,
        'in_outfit': outfit,
      });
  List<Widget> _orders() => [
    Text('최근 접수 ${orders.length}건 · 원 주문 순서 보존'),
    ...orders.map(
      (o) => Card(
        child: ListTile(
          title: Text(
            '${customerName(o)} · ${o['product_number']}번 ${o['product_title']}',
          ),
          subtitle: Text(
            '${o['color']} / ${o['size']} / ${o['quantity']}개\n#${o['sequence']} · ${o['cancelled'] == true
                ? '취소'
                : o['source'] == 'broadcast_assistant'
                ? '보조 입력'
                : '판매자 입력'}',
          ),
          trailing: data!.role == 'manager'
              ? IconButton(
                  tooltip: '주문 정정',
                  onPressed:
                      locked ||
                          o['payment_locked'] == true ||
                          o['invoice_id'] != null
                      ? null
                      : () => _editOrder(o),
                  icon: const Icon(Icons.edit_outlined),
                )
              : null,
        ),
      ),
    ),
    if (orderNextSequence != null)
      OutlinedButton(
        onPressed: orderPageLoading ? null : _moreOrders,
        child: Text(orderPageLoading ? '불러오는 중…' : '이전 주문 더 보기'),
      ),
  ];
  String sessionStatus(String value) => switch (value) {
    'draft' => '준비 중',
    'open' => '주문 접수 중',
    'closed' => '접수 마감',
    _ => '보관',
  };
  List<Widget> _setup() => [
    if (data!.role == 'manager') ..._staffControls(),
    if (data!.role == 'manager')
      FilledButton(
        onPressed: locked ? null : _newSession,
        child: const Text('방송 만들기'),
      ),
    if (data!.role == 'manager' && currentSession != null)
      OutlinedButton(
        onPressed: locked ? null : () => _sessionForm(currentSession),
        child: const Text('선택 방송 설정·마감'),
      ),
    if (currentSession != null)
      Text(
        '방송 날짜 ${currentSession!['broadcast_date']} · 상태 ${sessionStatus(currentSession!['status'] as String)} · 접수 마감 ${currentSession!['closes_at']}',
      ),
    OutlinedButton(
      onPressed: locked ? null : _newCustomer,
      child: const Text('고객 등록'),
    ),
    const Text('고객 주소는 정산서 발행 후 받습니다. 등록 시 요구하지 않습니다.'),
    ...customers.map(
      (c) => ListTile(
        title: Text(c['nickname'] as String),
        subtitle: Text(c['wechat_note'] as String),
      ),
    ),
    if (customerNextId != null)
      OutlinedButton(
        onPressed: customerPageLoading ? null : _moreCustomers,
        child: Text(customerPageLoading ? '불러오는 중…' : '고객 더 보기'),
      ),
  ];
  List<Widget> _staffControls() => [
    const Divider(),
    const Text('방송 보조 담당자', style: TextStyle(fontWeight: FontWeight.bold)),
    const Text('기존 오렌담 로그인 사용자가 30분짜리 코드로 참여합니다. 코드는 한 번만 사용할 수 있습니다.'),
    if (staffError != null) Text(staffError!),
    FilledButton.tonal(
      onPressed: locked || staff == null
          ? null
          : () => _send('staff.invite', {}),
      child: const Text('보조 참여 코드 만들기'),
    ),
    if (staff != null) ...[
      ...((staff!['invites'] as List? ?? []).cast<Map>()).map((invite) {
        final code = invite['code'] as String;
        final link = (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')
            ? '${Uri.base.origin}/#/seller/broadcast/join?code=$code'
            : code;
        return ListTile(
          title: const Text('사용 가능한 참여 코드'),
          subtitle: Text('만료 ${invite['expires_at']} · $code'),
          trailing: IconButton(
            tooltip: '참여 링크 복사',
            onPressed: () => Clipboard.setData(ClipboardData(text: link)),
            icon: const Icon(Icons.copy),
          ),
        );
      }),
      ...((staff!['members'] as List? ?? []).cast<Map>()).map((member) {
        final id = member['user_id'] as String;
        return ListTile(
          title: Text(
            '담당자 ${id.substring(0, 8)} · ${member['role'] == 'manager' ? '관리자' : '보조'}',
          ),
          subtitle: Text(id),
          trailing: IconButton(
            tooltip: '담당자 접근 회수',
            onPressed: locked ? null : () => _removeStaff(id),
            icon: const Icon(Icons.person_remove_outlined),
          ),
        );
      }),
    ],
    const Divider(),
  ];

  Future<void> _removeStaff(String userId) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('담당자 접근 회수'),
        content: const Text('이 담당자는 방송 주문과 고객 정보를 더 이상 조회할 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('유지'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('접근 회수'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _send('staff.remove', {'user_id': userId});
    }
  }

  Future<Map<String, String>?> _form(
    String title,
    Map<String, String> fields, {
    Set<String> optional = const {},
  }) async {
    return showDialog<Map<String, String>>(
      context: context,
      builder: (_) =>
          _CaptureFormDialog(title: title, fields: fields, optional: optional),
    );
  }

  Future<void> _newCustomer() async {
    final f = await _form(
      '새 고객',
      {'더우인 닉네임': search.text, '위챗 관리 정보': ''},
      optional: {'위챗 관리 정보'},
    );
    if (f != null && mounted) {
      await _send('customer.create', {
        'nickname': f['더우인 닉네임'],
        'wechat_note': f['위챗 관리 정보'],
      });
    }
  }

  Future<void> _newSession() => _sessionForm(null);

  Future<void> _sessionForm(BroadcastRow? existing) async {
    final today = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 9))
        .toIso8601String()
        .substring(0, 10);
    final f = await _form(existing == null ? '방송 만들기' : '방송 설정·마감', {
      '방송 이름': existing?['title']?.toString() ?? '',
      '방송 날짜 (YYYY-MM-DD)': existing?['broadcast_date']?.toString() ?? today,
      '종류 (신상/특가)': existing?['kind'] == 'special' ? '특가' : '신상',
      '상태 (준비/접수/마감)': switch (existing?['status']) {
        'draft' => '준비',
        'closed' => '마감',
        _ => '접수',
      },
      '1위안당 원화': existing?['exchange_rate']?.toString() ?? '190',
      '한국 배송비 (원)': existing?['shipping_krw']?.toString() ?? '4000',
      '중국 배송비 (위안)': existing == null
          ? '30'
          : ((existing['shipping_cny_fen'] as num) / 100).toStringAsFixed(2),
      '택포 기준 장수': existing?['free_shipping_count']?.toString() ?? '5',
      '집중 관리 일수': existing?['management_days']?.toString() ?? '3',
    });
    if (f == null || !mounted) return;
    final dateText = f['방송 날짜 (YYYY-MM-DD)']!;
    final date = DateTime.tryParse(dateText);
    final rate = double.tryParse(f['1위안당 원화']!);
    final krw = int.tryParse(f['한국 배송비 (원)']!);
    final cny = double.tryParse(f['중국 배송비 (위안)']!);
    final count = int.tryParse(f['택포 기준 장수']!);
    final days = int.tryParse(f['집중 관리 일수']!);
    if (date == null ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText) ||
        date.toIso8601String().substring(0, 10) != dateText ||
        rate == null ||
        !rate.isFinite ||
        rate <= 0 ||
        rate > 99999999 ||
        krw == null ||
        krw < 0 ||
        cny == null ||
        !cny.isFinite ||
        cny < 0 ||
        count == null ||
        count < 1 ||
        days == null ||
        days < 1 ||
        days > 30 ||
        !['신상', '특가'].contains(f['종류 (신상/특가)']) ||
        !['준비', '접수', '마감'].contains(f['상태 (준비/접수/마감)'])) {
      setState(() => error = '날짜·종류·상태·환율·배송비·기간을 확인해주세요.');
      return;
    }
    final payload = <String, dynamic>{
      if (existing != null) 'id': existing['id'],
      if (existing != null) 'version': existing['version'],
      'title': f['방송 이름'],
      'broadcast_date': dateText,
      'kind': f['종류 (신상/특가)'] == '특가' ? 'special' : 'new',
      'status': switch (f['상태 (준비/접수/마감)']) {
        '준비' => 'draft',
        '마감' => 'closed',
        _ => 'open',
      },
      'exchange_rate': rate,
      'shipping_krw': krw,
      'shipping_cny_fen': (cny * 100).round(),
      'free_shipping_count': count,
      'management_days': days,
    };
    await _send(
      existing == null ? 'session.create' : 'session.update',
      payload,
      success: (result) {
        setState(() {
          sessionId = result['id'] as String;
          productId = null;
        });
      },
    );
  }

  List<String> _options(String text) =>
      text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  Future<void> _newProduct() => _productForm(null);

  Future<void> _productForm(BroadcastRow? existing) async {
    final f = await _form(
      existing == null ? '상품 빠른 등록' : '상품 수정',
      {
        '거래처': existing?['supplier']?.toString() ?? '',
        '제품명': existing?['title']?.toString() ?? '',
        '가격 (원)': existing?['price_krw']?.toString() ?? '',
        '컬러 (쉼표로 구분)': (existing?['colors'] as List?)?.join(', ') ?? '',
        '사이즈 (쉼표로 구분)': (existing?['sizes'] as List?)?.join(', ') ?? 'FREE',
        '택포 제외': existing?['shipping_excluded'] == true ? '예' : '아니오',
        '수량 제한': existing?['quantity_limited'] == true ? '예' : '아니오',
        '판매 가능 수량': existing?['available_quantity']?.toString() ?? '',
      },
      optional: {'컬러 (쉼표로 구분)', '사이즈 (쉼표로 구분)', '판매 가능 수량'},
    );
    if (f == null || !mounted) return;
    final price = int.tryParse(f['가격 (원)']!);
    final available = int.tryParse(f['판매 가능 수량']!);
    final limited = f['수량 제한'] == '예';
    if (price == null ||
        price < 0 ||
        price > 100000000 ||
        (limited && (available == null || available < 0)) ||
        (f['판매 가능 수량']!.isNotEmpty && (available == null || available < 0))) {
      setState(() => error = '가격과 판매 가능 수량을 확인해주세요.');
      return;
    }
    await _send(existing == null ? 'product.create' : 'product.update', {
      if (existing == null) 'session_id': sessionId,
      if (existing != null) 'id': existing['id'],
      if (existing != null) 'version': existing['version'],
      'supplier': f['거래처'],
      'title': f['제품명'],
      'price_krw': price,
      'colors': _options(f['컬러 (쉼표로 구분)']!),
      'sizes': _options(f['사이즈 (쉼표로 구분)']!),
      'shipping_excluded': f['택포 제외'] == '예',
      'quantity_limited': limited,
      'available_quantity': available,
    });
  }

  Future<void> _editOrder(BroadcastRow o) async {
    final f = await _form(
      '입금 전 주문 정정',
      {
        '컬러': o['color'] as String,
        '사이즈': o['size'] as String,
        '수량': '${o['quantity']}',
        '메모': o['note'] as String,
        '수정 사유': '',
      },
      optional: {'컬러', '사이즈', '메모'},
    );
    if (f == null || !mounted) return;
    final q = int.tryParse(f['수량']!);
    if (q == null || q < 1 || q > 999) {
      setState(() => error = '수량을 확인해주세요.');
      return;
    }
    await _send('order.revise', {
      'id': o['id'],
      'version': o['version'],
      'color': f['컬러'],
      'size': f['사이즈'],
      'quantity': q,
      'note': f['메모'],
      'reason': f['수정 사유'],
      'cancelled': o['cancelled'],
    });
  }
}

class _CaptureFormDialog extends StatefulWidget {
  const _CaptureFormDialog({
    required this.title,
    required this.fields,
    required this.optional,
  });
  final String title;
  final Map<String, String> fields;
  final Set<String> optional;
  @override
  State<_CaptureFormDialog> createState() => _CaptureFormDialogState();
}

class _CaptureFormDialogState extends State<_CaptureFormDialog> {
  late final controllers = widget.fields.map(
    (k, v) => MapEntry(k, TextEditingController(text: v)),
  );
  final formKey = GlobalKey<FormState>();
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: controllers.entries
              .map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: (e.key == '택포 제외' || e.key == '수량 제한')
                      ? SwitchListTile(
                          title: Text(e.key),
                          value: e.value.text == '예',
                          onChanged: (v) =>
                              setState(() => e.value.text = v ? '예' : '아니오'),
                        )
                      : TextFormField(
                          controller: e.value,
                          decoration: InputDecoration(labelText: e.key),
                          validator: (v) =>
                              !widget.optional.contains(e.key) &&
                                  (v ?? '').trim().isEmpty
                              ? '입력해주세요'
                              : null,
                        ),
                ),
              )
              .toList(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('닫기'),
      ),
      FilledButton(
        onPressed: () {
          if (formKey.currentState!.validate()) {
            Navigator.pop(
              context,
              controllers.map((k, v) => MapEntry(k, v.text.trim())),
            );
          }
        },
        child: const Text('저장'),
      ),
    ],
  );
}
