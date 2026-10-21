import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';
import 'broadcast_repository.dart';

class BroadcastBillingPage extends StatefulWidget {
  const BroadcastBillingPage({
    super.key,
    required this.client,
    required this.sellerId,
  });
  final SupabaseClient client;
  final String sellerId;
  @override
  State<BroadcastBillingPage> createState() => _BroadcastBillingPageState();
}

class _BroadcastBillingPageState extends State<BroadcastBillingPage> {
  final search = TextEditingController();
  List<Map<String, dynamic>> customers = [],
      sessions = [],
      orders = [],
      receivers = [],
      deposits = [];
  Map<String, dynamic>? pending, lastInvoice, activeInvoice, destination;
  String? customerId, sessionId, country, error;
  num depositAvailable = 0;
  bool busy = false, journalReady = false;
  String get _pendingName =>
      'broadcast_billing_pending_${widget.sellerId}_${widget.client.auth.currentUser?.id}';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingName);
      if (raw != null) {
        pending = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
      journalReady = true;
      final workspace = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_workspace',
              params: {'p_seller_id': widget.sellerId},
            )
            as Map,
      );
      if (!mounted) return;
      setState(
        () => sessions = (workspace['sessions'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
      await _search();
      await _loadReceivers();
    } catch (e) {
      if (mounted) {
        setState(() => error = '청구 화면을 불러오지 못했습니다. 기기 요청 기록을 확인해주세요: $e');
      }
    }
  }

  Future<void> _loadReceivers() async {
    try {
      final rows =
          await widget.client.rpc(
                'broadcast_receiver_page',
                params: {'p_seller_id': widget.sellerId},
              )
              as List;
      if (mounted) {
        setState(
          () => receivers = rows
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '수취 안내를 불러오지 못했습니다: $e');
    }
  }

  Future<void> _search() async {
    try {
      final page = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_customer_page',
              params: {
                'p_seller_id': widget.sellerId,
                'p_query': search.text.trim(),
                'p_limit': 50,
              },
            )
            as Map,
      );
      if (mounted) {
        setState(
          () => customers = (page['items'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '고객을 찾지 못했습니다: $e');
    }
  }

  Future<void> _preview() async {
    if (customerId == null || sessionId == null) return;
    setState(() => busy = true);
    try {
      final data = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_billing_preview',
              params: {
                'p_seller_id': widget.sellerId,
                'p_customer_id': customerId,
                'p_session_id': sessionId,
              },
            )
            as Map,
      );
      final revision = await widget.client.rpc(
        'broadcast_invoice_revision_preview',
        params: {
          'p_seller_id': widget.sellerId,
          'p_customer_id': customerId,
          'p_session_id': sessionId,
        },
      );
      final currentDestination = await widget.client.rpc(
        'broadcast_manager_destination',
        params: {'p_seller_id': widget.sellerId, 'p_customer_id': customerId},
      );
      if (!mounted) return;
      setState(() {
        orders = (data['orders'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        deposits = (data['deposits'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        country = data['country'] as String?;
        depositAvailable = data['deposit_available_krw'] as num? ?? 0;
        activeInvoice = revision == null
            ? null
            : Map<String, dynamic>.from(revision as Map);
        destination = currentDestination == null
            ? null
            : Map<String, dynamic>.from(currentDestination as Map);
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '청구 후보를 불러오지 못했습니다: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _sendPending() async {
    final action = pending;
    if (action == null) return;
    setState(() => busy = true);
    try {
      final isReceiver = action['command'] == 'receiver.upsert';
      final isReceiverQr = action['command'] == 'receiver.qr.attach';
      final isRevision = action['command'] == 'invoice.revise';
      final isLineCorrection = action['command'] == 'invoice.line.correct';
      final isCountryRevision = action['command'] == 'invoice.country.revise';
      final isDepositReturn = action['command'] == 'deposit.return';
      final isDepositVoid = action['command'] == 'deposit.void';
      final isAddress = action['command'] == 'destination.correct';
      final result = Map<String, dynamic>.from(
        await widget.client.rpc(
              isAddress
                  ? 'broadcast_manager_address'
                  : isDepositReturn
                  ? 'broadcast_deposit_return'
                  : isDepositVoid
                  ? 'broadcast_deposit_void'
                  : isReceiver
                  ? 'broadcast_receiver_command'
                  : isReceiverQr
                  ? 'broadcast_receiver_qr_attach'
                  : isRevision
                  ? 'broadcast_invoice_revise'
                  : isLineCorrection
                  ? 'broadcast_invoice_revise_line'
                  : isCountryRevision
                  ? 'broadcast_invoice_country_revise'
                  : 'broadcast_billing_command',
              params: isAddress
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_customer_id': action['data']['customer_id'],
                      'p_address': action['data']['address'],
                      'p_expected_version': action['data']['expected_version'],
                      'p_reason': action['data']['reason'],
                      'p_key': action['key'],
                    }
                  : isDepositReturn
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_data': action['data'],
                      'p_key': action['key'],
                    }
                  : isDepositVoid
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_deposit_id': action['data']['deposit_id'],
                      'p_reason': action['data']['reason'],
                      'p_key': action['key'],
                    }
                  : isRevision
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_invoice_id': action['data']['invoice_id'],
                      'p_excluded_line_ids':
                          action['data']['excluded_line_ids'],
                      'p_reason': action['data']['reason'],
                      'p_key': action['key'],
                    }
                  : isLineCorrection
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_invoice_id': action['data']['invoice_id'],
                      'p_change': action['data']['change'],
                      'p_reason': action['data']['reason'],
                      'p_key': action['key'],
                    }
                  : isCountryRevision
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_invoice_id': action['data']['invoice_id'],
                      'p_country': action['data']['country'],
                      'p_reason': action['data']['reason'],
                      'p_key': action['key'],
                    }
                  : isReceiver
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_data': action['data'],
                      'p_key': action['key'],
                    }
                  : isReceiverQr
                  ? {
                      'p_seller_id': widget.sellerId,
                      'p_method': action['data']['method'],
                      'p_object_id': action['data']['object_id'],
                      'p_content_type': action['data']['content_type'],
                      'p_key': action['key'],
                    }
                  : {
                      'p_seller_id': widget.sellerId,
                      'p_command': action['command'],
                      'p_data': action['data'],
                      'p_key': action['key'],
                    },
            )
            as Map,
      );
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.remove(_pendingName)) {
        throw StateError('확정된 청구 요청 기록을 지우지 못했습니다.');
      }
      if (action['command'] == 'invoice.issue' ||
          isRevision ||
          isLineCorrection ||
          isCountryRevision) {
        lastInvoice = result;
      }
      pending = null;
      if (isReceiver || isReceiverQr) await _loadReceivers();
      if (customerId != null && sessionId != null) await _preview();
    } catch (e) {
      if (mounted) {
        setState(() => error = '청구 결과를 확인하지 못했습니다. 같은 요청으로 재확인해주세요: $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _editReceiver(String method) async {
    final existing = receivers.where((r) => r['method'] == method).firstOrNull;
    final holder = TextEditingController(
      text: existing?['holder'] as String? ?? '',
    );
    final instructions = TextEditingController(
      text: existing?['instructions'] as String? ?? '',
    );
    bool active = existing?['active'] == true;
    bool verified = false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            '${method == 'bank'
                ? '한국 계좌'
                : method == 'wechat'
                ? '위챗페이'
                : '알리페이'} 수취 안내',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: holder,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: '실제 수취인 명의'),
                ),
                TextField(
                  controller: instructions,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '고객에게 보일 송금 안내'),
                ),
                SwitchListTile(
                  title: const Text('새 청구서에 안내'),
                  value: active,
                  onChanged: (value) => update(() {
                    active = value;
                    verified = false;
                  }),
                ),
                if (active)
                  CheckboxListTile(
                    title: const Text('실제 수취 계정과 안내를 확인했습니다'),
                    value: verified,
                    onChanged: (value) =>
                        update(() => verified = value ?? false),
                  ),
                const Text('변경 내용은 새 청구서에만 적용됩니다. 기존 청구서 안내는 유지됩니다.'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: active && !verified
                  ? null
                  : () => Navigator.pop(context, {
                      'method': method,
                      'holder': holder.text.trim(),
                      'instructions': instructions.text.trim(),
                      'active': active,
                      'verified': verified,
                    }),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    holder.dispose();
    instructions.dispose();
    if (result == null) return;
    if ((result['holder'] as String).isEmpty ||
        (result['instructions'] as String).isEmpty) {
      setState(() => error = '수취인 명의와 안내를 입력해주세요.');
      return;
    }
    await _command('receiver.upsert', result);
  }

  Future<void> _uploadReceiverQr(String method) async {
    if (busy || pending != null) return;
    setState(() => busy = true);
    try {
      final image = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (image == null) return;
      final bytes = await image.readAsBytes();
      String? mime;
      String? ext;
      if (bytes.length >= 8 &&
          bytes[0] == 137 &&
          bytes[1] == 80 &&
          bytes[2] == 78 &&
          bytes[3] == 71) {
        mime = 'image/png';
        ext = 'png';
      } else if (bytes.length >= 3 &&
          bytes[0] == 255 &&
          bytes[1] == 216 &&
          bytes[2] == 255) {
        mime = 'image/jpeg';
        ext = 'jpg';
      }
      if (mime == null || bytes.isEmpty || bytes.length > 2097152) {
        throw StateError('2MB 이하 PNG 또는 JPG 수취 QR을 선택해주세요.');
      }
      final objectId = BroadcastCommand('receiver.qr.object', {}).key;
      await widget.client.storage
          .from('broadcast-receiver-qr')
          .uploadBinary(
            '${widget.sellerId}/$objectId.$ext',
            bytes,
            fileOptions: FileOptions(contentType: mime),
          );
      if (!mounted) return;
      setState(() => busy = false);
      await _command('receiver.qr.attach', {
        'method': method,
        'object_id': objectId,
        'content_type': mime,
      });
    } catch (e) {
      if (mounted) setState(() => error = '수취 QR 업로드/연결 실패: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _command(String command, Map<String, dynamic> data) async {
    if (!journalReady || pending != null) return;
    final next = {
      'command': command,
      'data': data,
      'key': BroadcastCommand(command, {}).key,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_pendingName, jsonEncode(next))) {
        throw StateError('재시도 키 저장 실패');
      }
      pending = next;
      await _sendPending();
    } catch (e) {
      if (mounted) setState(() => error = '청구 명령을 시작하지 못했습니다: $e');
    }
  }

  Future<void> _verifyDeposit() async {
    if (customerId == null) return;
    final amount = TextEditingController(text: '10000');
    final receiver = TextEditingController();
    final reference = TextEditingController();
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('실제 선입금 확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('실제 수취내역을 확인한 뒤 기록합니다. 중복 거래번호는 서버가 거절합니다.'),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '수취 금액 (원)'),
            ),
            TextField(
              controller: receiver,
              decoration: const InputDecoration(labelText: '수취 계정'),
            ),
            TextField(
              controller: reference,
              decoration: const InputDecoration(labelText: '거래번호'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'amount': amount.text.trim(),
              'receiver': receiver.text.trim(),
              'reference': reference.text.trim(),
            }),
            child: const Text('실수취 확인'),
          ),
        ],
      ),
    );
    amount.dispose();
    receiver.dispose();
    reference.dispose();
    if (values == null) return;
    final money = int.tryParse(values['amount'] ?? '');
    if (money == null ||
        money <= 0 ||
        values['receiver']!.isEmpty ||
        values['reference']!.isEmpty) {
      setState(() => error = '수취 금액·계정·거래번호를 입력해주세요.');
      return;
    }
    await _command('deposit.verify', {
      'customer_id': customerId,
      'amount_krw': money,
      'receiver': values['receiver'],
      'transaction_ref': values['reference'],
      'received_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _returnDeposit(Map<String, dynamic> deposit) async {
    final amount = TextEditingController(text: '${deposit['available_krw']}');
    final receiver = TextEditingController();
    final reference = TextEditingController();
    final reason = TextEditingController();
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('실제 선입금 반환 기록'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '미배분 잔액 ${deposit['available_krw']}원만 반환할 수 있습니다. 실제 송금 후 거래내역을 확인하세요.',
              ),
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '반환액 (원)'),
              ),
              TextField(
                controller: receiver,
                decoration: const InputDecoration(labelText: '반환한 계정'),
              ),
              TextField(
                controller: reference,
                decoration: const InputDecoration(labelText: '실제 반환 거래번호'),
              ),
              TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: '반환 사유'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'amount': amount.text.trim(),
              'receiver': receiver.text.trim(),
              'reference': reference.text.trim(),
              'reason': reason.text.trim(),
            }),
            child: const Text('반환 거래 기록'),
          ),
        ],
      ),
    );
    amount.dispose();
    receiver.dispose();
    reference.dispose();
    reason.dispose();
    if (values == null) return;
    final money = int.tryParse(values['amount'] ?? '');
    final available = num.tryParse('${deposit['available_krw']}') ?? 0;
    if (money == null ||
        money <= 0 ||
        money > available ||
        values['receiver']!.isEmpty ||
        values['reference']!.isEmpty ||
        values['reason']!.isEmpty) {
      setState(() => error = '미배분 잔액과 실제 반환 거래내역을 확인해주세요.');
      return;
    }
    await _command('deposit.return', {
      'deposit_id': deposit['id'],
      'amount_krw': money,
      'receiver': values['receiver'],
      'transaction_ref': values['reference'],
      'reason': values['reason'],
      'returned_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _voidDeposit(Map<String, dynamic> deposit) async {
    final reason = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('선입금 오기입 정정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '이 ${deposit['amount_krw']}원 기록이 실제 수취가 아니었는지 확인하세요. 청구에 배분되거나 실제 반환된 기록은 정정할 수 없습니다.',
            ),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: '오기입 사유'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('돌아가기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, reason.text.trim()),
            child: const Text('오기입 기록 무효화'),
          ),
        ],
      ),
    );
    reason.dispose();
    if (value == null) return;
    if (value.isEmpty) {
      setState(() => error = '오기입 사유를 입력해주세요.');
      return;
    }
    await _command('deposit.void', {
      'deposit_id': deposit['id'],
      'reason': value,
    });
  }

  Future<void> _correctAddress() async {
    final current = destination;
    if (customerId == null || current == null) return;
    final address = Map<String, dynamic>.from(current['address'] as Map? ?? {});
    final recipient = TextEditingController(
      text: address['recipient'] as String? ?? '',
    );
    final phone = TextEditingController(
      text: address['phone'] as String? ?? '',
    );
    final region = TextEditingController(
      text: address['region'] as String? ?? '',
    );
    final detail = TextEditingController(
      text: address['detail'] as String? ?? '',
    );
    final reason = TextEditingController();
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('판매자 배송주소 정정'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('배송국가 ${current['country']} · 이미 출고된 배송지에는 적용되지 않습니다.'),
              TextField(
                controller: recipient,
                decoration: const InputDecoration(labelText: '받는 사람'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: '연락처'),
              ),
              TextField(
                controller: region,
                decoration: const InputDecoration(labelText: '지역·기본주소'),
              ),
              TextField(
                controller: detail,
                decoration: const InputDecoration(labelText: '상세주소'),
              ),
              TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: '정정 사유'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'recipient': recipient.text.trim(),
              'phone': phone.text.trim(),
              'region': region.text.trim(),
              'detail': detail.text.trim(),
              'reason': reason.text.trim(),
            }),
            child: const Text('정정 저장'),
          ),
        ],
      ),
    );
    recipient.dispose();
    phone.dispose();
    region.dispose();
    detail.dispose();
    reason.dispose();
    if (values == null) return;
    if (values.values.any((value) => value.isEmpty)) {
      setState(() => error = '주소와 정정 사유를 모두 입력해주세요.');
      return;
    }
    await _command('destination.correct', {
      'customer_id': customerId,
      'expected_version': current['version'],
      'address': {...address, 'country': current['country'], ...values}
        ..remove('reason'),
      'reason': values['reason'],
    });
  }

  Future<void> _issue() async {
    if (customerId == null ||
        sessionId == null ||
        country == null ||
        orders.isEmpty) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('정산서 발행'),
        content: Text(
          '현재 주문 ${orders.length}행, 배송국가 $country, 선입금 잔액 $depositAvailable원을 확인했습니다. 서버가 환율·배송·택포·차감 금액을 확정합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('돌아가기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('발행'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _command('invoice.issue', {
        'customer_id': customerId,
        'session_id': sessionId,
      });
    }
  }

  Future<void> _revise() async {
    final invoice = activeInvoice;
    if (invoice == null || invoice['locked'] == true) return;
    final selected = <String>{};
    final reason = TextEditingController();
    final lines = (invoice['lines'] as List? ?? []).cast<Map>();
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('정산서 ${invoice['version']}판 정정'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('제외할 상품을 선택하세요. 이전 판본과 원 주문 기록은 보존됩니다.'),
                  ...lines.map(
                    (line) => CheckboxListTile(
                      title: Text(
                        '${line['product_title']} · ${line['color']} ${line['size']} · ${line['quantity']}개',
                      ),
                      value: selected.contains(line['id']),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          selected.add(line['id'] as String);
                        } else {
                          selected.remove(line['id']);
                        }
                      }),
                    ),
                  ),
                  TextField(
                    controller: reason,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: '정정 사유 (고객에게 표시)',
                    ),
                  ),
                  const Text(
                    '새 청구서는 서버에서 금액·배송비·선입금을 다시 계산합니다. 고객은 새 판본을 다시 확인해야 합니다.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, {
                      'invoice_id': invoice['id'],
                      'excluded_line_ids': selected.toList()..sort(),
                      'reason': reason.text.trim(),
                    }),
              child: Text(selected.length == lines.length ? '정산서 무효화' : '새 판본 발행'),
            ),
          ],
        ),
      ),
    );
    reason.dispose();
    if (data == null) return;
    if ((data['reason'] as String).isEmpty) {
      setState(() => error = '정정 사유를 입력해주세요.');
      return;
    }
    await _command('invoice.revise', data);
  }

  Future<void> _correctLine(Map<String, dynamic> line) async {
    final invoice = activeInvoice;
    if (invoice == null || invoice['locked'] == true) return;
    final color = TextEditingController(text: '${line['color'] ?? ''}');
    final size = TextEditingController(text: '${line['size'] ?? ''}');
    final quantity = TextEditingController(text: '${line['quantity'] ?? 1}');
    final price = TextEditingController(text: '${line['unit_price_krw'] ?? 0}');
    final reason = TextEditingController();
    bool cancelled = false;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('${line['product_title']} 정정'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '입금·증빙 전 판매자 입력 실수만 정정합니다. 이전 청구는 보존되고 고객이 새 판본을 다시 확인합니다.',
                ),
                TextField(
                  controller: color,
                  decoration: const InputDecoration(labelText: '색상'),
                ),
                TextField(
                  controller: size,
                  decoration: const InputDecoration(labelText: '사이즈'),
                ),
                TextField(
                  controller: quantity,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '수량'),
                ),
                TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '단가 (원)'),
                ),
                CheckboxListTile(
                  title: const Text('상품 취소'),
                  value: cancelled,
                  onChanged: (value) =>
                      update(() => cancelled = value ?? false),
                ),
                TextField(
                  controller: reason,
                  decoration: const InputDecoration(labelText: '정정 사유'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'color': color.text.trim(),
                'size': size.text.trim(),
                'quantity': int.tryParse(quantity.text),
                'unit_price_krw': int.tryParse(price.text),
                'cancelled': cancelled,
                'reason': reason.text.trim(),
              }),
              child: const Text('새 청구 판본 발행'),
            ),
          ],
        ),
      ),
    );
    color.dispose();
    size.dispose();
    quantity.dispose();
    price.dispose();
    reason.dispose();
    if (values == null) return;
    if ((values['reason'] as String).isEmpty ||
        (values['cancelled'] != true &&
            (values['quantity'] == null || values['unit_price_krw'] == null))) {
      setState(() => error = '정정 사유·수량·단가를 확인해주세요.');
      return;
    }
    final change = Map<String, dynamic>.from(values)..remove('reason');
    await _command('invoice.line.correct', {
      'invoice_id': invoice['id'],
      'reason': values['reason'],
      'change': {
        'order_line_id': line['id'],
        'expected_version': line['current_version'],
        ...change,
      },
    });
  }

  Future<void> _reviseCountry() async {
    final invoice = activeInvoice;
    if (invoice == null || invoice['locked'] == true || country == null) return;
    final nextCountry = country == 'KR' ? 'CN' : 'KR';
    final reason = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('배송국가를 $nextCountry로 정정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '이전 청구는 보존합니다. 배송비/환율을 다시 계산하고 기존 주소를 비운 뒤 고객에게 새 판본과 주소 확인을 요청합니다.',
            ),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: '정정 사유'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('돌아가기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, reason.text.trim()),
            child: const Text('새 판본 발행'),
          ),
        ],
      ),
    );
    reason.dispose();
    if (value == null) return;
    if (value.isEmpty) {
      setState(() => error = '배송국가 정정 사유를 입력해주세요.');
      return;
    }
    await _command('invoice.country.revise', {
      'invoice_id': invoice['id'],
      'country': nextCountry,
      'reason': value,
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('${ServiceBrand.shortName} · 정산'),
      actions: [
        IconButton(
          onPressed: busy ? null : _preview,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (pending != null)
          Card(
            child: ListTile(
              title: const Text('결과 미확인 정산 요청'),
              subtitle: Text('${pending!['command']} · 같은 키로 재확인'),
              trailing: FilledButton(
                onPressed: busy ? null : _sendPending,
                child: const Text('재확인'),
              ),
            ),
          ),
        TextField(
          controller: search,
          decoration: InputDecoration(
            labelText: '더우인 닉네임 검색',
            suffixIcon: IconButton(
              onPressed: _search,
              icon: const Icon(Icons.search),
            ),
          ),
        ),
        ...customers.map(
          (c) => ListTile(
            title: Text('${c['nickname']}'),
            subtitle: Text('${c['id']}'),
            selected: customerId == c['id'],
            onTap: busy
                ? null
                : () {
                    setState(() {
                      customerId = c['id'] as String;
                      orders = [];
                    });
                    _preview();
                  },
          ),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey(sessionId),
          initialValue: sessionId,
          decoration: const InputDecoration(labelText: '방송'),
          items: sessions
              .map(
                (s) => DropdownMenuItem(
                  value: s['id'] as String,
                  child: Text('${s['title']}'),
                ),
              )
              .toList(),
          onChanged: busy
              ? null
              : (value) {
                  setState(() {
                    sessionId = value;
                    orders = [];
                  });
                  _preview();
                },
        ),
        const SizedBox(height: 12),
        Text('배송국가: ${country ?? '미선택'} · 사용 가능 선입금: $depositAvailable원'),
        if (destination != null)
          OutlinedButton(
            onPressed: busy || pending != null ? null : _correctAddress,
            child: const Text('배송주소 정정'),
          ),
        ...deposits.map(
          (d) => Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('선입금 ${d['amount_krw']}원 · 미배분 ${d['available_krw']}원'),
                  OutlinedButton(
                    onPressed:
                        busy ||
                            pending != null ||
                            (num.tryParse('${d['available_krw']}') ?? 0) <= 0
                        ? null
                        : () => _returnDeposit(d),
                    child: const Text('실제 반환 기록'),
                  ),
                  OutlinedButton(
                    onPressed: busy || pending != null
                        ? null
                        : () => _voidDeposit(d),
                    child: const Text('오기입 무효화'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Text('수취 안내', style: Theme.of(context).textTheme.titleMedium),
        ...receivers.map(
          (r) => Text(
            '${r['method']} · ${r['currency']} · ${r['holder']} · ${r['active'] == true ? '활성' : '중지'} · QR ${r['has_qr'] == true ? '등록' : '없음'}',
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final method in ['bank', 'wechat', 'alipay'])
              OutlinedButton(
                onPressed: busy || pending != null || !journalReady
                    ? null
                    : () => _editReceiver(method),
                child: Text(
                  method == 'bank'
                      ? '한국 계좌 설정'
                      : method == 'wechat'
                      ? '위챗페이 설정'
                      : '알리페이 설정',
                ),
              ),
            for (final method in ['wechat', 'alipay'])
              OutlinedButton(
                onPressed: busy || pending != null || !journalReady
                    ? null
                    : () => _uploadReceiverQr(method),
                child: Text('${method == 'wechat' ? '위챗' : '알리페이'} 수취 QR 등록'),
              ),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed:
                  busy || pending != null || !journalReady || customerId == null
                  ? null
                  : () => _command('destination.country', {
                      'customer_id': customerId,
                      'country': 'KR',
                    }),
              child: const Text('한국 배송'),
            ),
            OutlinedButton(
              onPressed:
                  busy || pending != null || !journalReady || customerId == null
                  ? null
                  : () => _command('destination.country', {
                      'customer_id': customerId,
                      'country': 'CN',
                    }),
              child: const Text('중국 배송'),
            ),
            OutlinedButton(
              onPressed:
                  busy || pending != null || !journalReady || customerId == null
                  ? null
                  : _verifyDeposit,
              child: const Text('선입금 실수취 기록'),
            ),
          ],
        ),
        ...orders.map(
          (o) => ListTile(
            title: Text('${o['product_title']} · ${o['color']} / ${o['size']}'),
            trailing: Text('${o['quantity']}개 × ${o['unit_price_krw']}원'),
          ),
        ),
        if (activeInvoice != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '현재 정산서 ${activeInvoice!['version']}판 · ${activeInvoice!['total_krw']}원',
                  ),
                  Text(
                    activeInvoice!['locked'] == true
                        ? '증빙·입금·발주가 진행되어 정정할 수 없습니다.'
                        : '입력 실수나 상품 제외는 새 판본으로 정정합니다.',
                  ),
                  ...(activeInvoice!['lines'] as List? ?? []).map((raw) {
                    final line = Map<String, dynamic>.from(raw as Map);
                    return ListTile(
                      title: Text(
                        '${line['product_title']} · ${line['color']} / ${line['size']}',
                      ),
                      subtitle: Text(
                        '${line['quantity']}개 × ${line['unit_price_krw']}원',
                      ),
                      trailing: TextButton(
                        onPressed:
                            busy ||
                                pending != null ||
                                activeInvoice!['locked'] == true
                            ? null
                            : () => _correctLine(line),
                        child: const Text('정정'),
                      ),
                    );
                  }),
                  OutlinedButton(
                    onPressed:
                        busy ||
                            pending != null ||
                            activeInvoice!['locked'] == true
                        ? null
                        : _revise,
                    child: const Text('상품 제외·재발행'),
                  ),
                  OutlinedButton(
                    onPressed:
                        busy ||
                            pending != null ||
                            activeInvoice!['locked'] == true
                        ? null
                        : _reviseCountry,
                    child: const Text('배송국가 정정·재발행'),
                  ),
                ],
              ),
            ),
          ),
        FilledButton(
          onPressed: busy || pending != null || !journalReady ? null : _issue,
          child: const Text('정산서 발행'),
        ),
        if (lastInvoice != null && lastInvoice!['status'] == 'void')
          const Text('청구 상품을 모두 취소하여 정산서를 무효화했습니다.'),
        if (lastInvoice != null && lastInvoice!['status'] != 'void')
          Text(
            '발행 완료 · 잔액 ${lastInvoice!['total_krw']}원 / ${lastInvoice!['total_cny_fen']}전',
          ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ],
    ),
  );
}
