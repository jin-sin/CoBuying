import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'customer_http_io.dart'
    if (dart.library.js_interop) 'customer_http_web.dart';

class BroadcastCustomerApi {
  BroadcastCustomerApi(this.locator, {String? gatewayOrigin})
    : _base =
          gatewayOrigin ??
          const String.fromEnvironment('BROADCAST_GATEWAY_ORIGIN') {
    _client = customerHttpClient();
  }

  final String locator, _base;
  late final http.Client _client;
  String get _root => '$_base/api/broadcast/v2';
  String receiverQrUrl(String invoiceId, String method) =>
      '$_root/customer/$locator/invoices/$invoiceId/receiver-qr/$method';

  Future<dynamic> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final request = http.Request(method, Uri.parse('$_root$path'));
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode >= 400) {
      throw Exception(decoded is Map ? (decoded['error'] ?? '요청 실패') : '요청 실패');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> requestAccess() async =>
      Map<String, dynamic>.from(
        await _request('POST', '/access/request', {'locator': locator}) as Map,
      );
  Future<void> activate(String requestId, String token) async {
    await _request('POST', '/access/activate', {
      'request_id': requestId,
      'token': token,
    });
  }

  Future<Map<String, dynamic>> view() async => Map<String, dynamic>.from(
    await _request('GET', '/customer/$locator') as Map,
  );
  Future<List<Map<String, dynamic>>> requests() async =>
      (await _request('GET', '/customer/$locator/requests') as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
  Future<Map<String, dynamic>> submit({
    required String kind,
    required String targetId,
    required String rawText,
    required String requestKey,
  }) async => Map<String, dynamic>.from(
    await _request('POST', '/customer/$locator/requests', {
          'kind': kind,
          'target_id': targetId,
          'raw_text': rawText,
          'request_key': requestKey,
        })
        as Map,
  );
  Future<Map<String, dynamic>> billing() async => Map<String, dynamic>.from(
    await _request('GET', '/customer/$locator/billing') as Map,
  );
  Future<Map<String, dynamic>> saveAddress(
    Map<String, dynamic> address,
    int expectedVersion,
  ) async => Map<String, dynamic>.from(
    await _request('POST', '/customer/$locator/address', {
          'address': address,
          'expected_version': expectedVersion,
        })
        as Map,
  );
  Future<Map<String, dynamic>> acceptInvoice(String invoiceId) async =>
      Map<String, dynamic>.from(
        await _request(
              'POST',
              '/customer/$locator/invoices/$invoiceId/accept',
              {},
            )
            as Map,
      );
  Future<List<Map<String, dynamic>>> shipments() async =>
      (await _request('GET', '/customer/$locator/shipments') as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
  Future<Map<String, dynamic>> uploadEvidence(
    String invoiceId,
    String key,
    Uint8List bytes,
    String contentType,
  ) async {
    final url = Uri.parse(
      '$_root/customer/$locator/evidence',
    ).replace(queryParameters: {'invoice': invoiceId, 'key': key});
    final request = http.Request('POST', url)
      ..headers['content-type'] = contentType
      ..bodyBytes = bytes;
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    final decoded = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw Exception(decoded is Map ? decoded['error'] : '업로드 실패');
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  Future<Map<String, dynamic>> submitReceipt(
    String evidenceId,
    String currency,
    int amountMinor,
    String payerName,
  ) async => Map<String, dynamic>.from(
    await _request('POST', '/customer/$locator/receipts', {
          'evidence_id': evidenceId,
          'currency': currency,
          'amount_minor': amountMinor,
          'payer_name': payerName,
        })
        as Map,
  );
  Future<List<Map<String, dynamic>>> payments() async =>
      (await _request('GET', '/customer/$locator/payments') as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
  Future<List<Map<String, dynamic>>> depositReturns() async =>
      (await _request('GET', '/customer/$locator/deposit-returns') as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
  Future<List<Map<String, dynamic>>> receiptsNeedingInfo() async =>
      (await _request('GET', '/customer/$locator/receipts/needs-info') as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
  Future<Map<String, dynamic>> supplementReceipt(
    String receiptId,
    String evidenceId,
  ) async => Map<String, dynamic>.from(
    await _request(
          'POST',
          '/customer/$locator/receipts/$receiptId/supplement',
          {'evidence_id': evidenceId},
        )
        as Map,
  );
  void close() => _client.close();
}
