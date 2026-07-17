import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/order.dart';
import 'seller_profile.dart';

class SellerRepository {
  SellerRepository(this._client);

  final SupabaseClient _client;

  Future<SellerProfile?> fetchMyProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    final row = await _client
        .from('seller_profiles')
        .select()
        .eq('user_id', user.id)
        .maybeSingle();
    return row == null ? null : SellerProfile.fromJson(row);
  }

  /// 셀러 입점 신청 (status는 DB 기본값 pending)
  Future<void> apply({
    required String shopName,
    required String bankName,
    required String bankAccount,
    required String accountHolder,
    required String contactPhone,
    required String businessNumber,
    String onlineSalesNumber = '',
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw const AuthException('로그인이 필요합니다.');
    await _client.from('seller_profiles').insert({
      'user_id': user.id,
      'shop_name': shopName,
      'bank_name': bankName,
      'bank_account': bankAccount,
      'account_holder': accountHolder,
      'contact_phone': contactPhone,
      'business_number': businessNumber,
      'online_sales_number': onlineSalesNumber,
    });
  }

  /// 상호명·정산 계좌 수정 (status/수수료율은 DB 트리거가 셀러 변경을 차단)
  Future<void> updateInfo({
    required String shopName,
    required String bankName,
    required String bankAccount,
    required String accountHolder,
    required String contactPhone,
    required String businessNumber,
    String onlineSalesNumber = '',
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) throw const AuthException('로그인이 필요합니다.');
    await _client.from('seller_profiles').update({
      'shop_name': shopName,
      'bank_name': bankName,
      'bank_account': bankAccount,
      'account_holder': accountHolder,
      'contact_phone': contactPhone,
      'business_number': businessNumber,
      'online_sales_number': onlineSalesNumber,
    }).eq('user_id', user.id);
  }

  /// 내 판매 내역: 내 상품이 팔린 주문 아이템 + 주문 정보
  Future<List<(OrderItem, Order)>> fetchMySales() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];
    final rows = await _client
        .from('order_items')
        .select('*, orders!inner(*)')
        .eq('seller_id', user.id);
    final sales = rows
        .map((row) => (
              OrderItem.fromJson(row),
              Order.fromJson(row['orders'] as Map<String, dynamic>),
            ))
        .toList();
    sales.sort((a, b) => b.$2.createdAt.compareTo(a.$2.createdAt));
    return sales;
  }

  /// 내 정산 요약 (결제 완료 이후 상태의 주문 집계 - 지급 차감 잔액 포함)
  Future<SellerSettlement> fetchMySettlement() async {
    final user = _client.auth.currentUser;
    if (user == null) return SellerSettlement.empty;
    final row = await _client
        .from('seller_balances')
        .select()
        .eq('seller_id', user.id)
        .maybeSingle();
    return row == null ? SellerSettlement.empty : SellerSettlement.fromJson(row);
  }

  /// 지급 내역 (셀러: 본인 것만, 관리자: sellerId 지정)
  Future<List<SellerPayout>> fetchPayouts([String? sellerId]) async {
    final id = sellerId ?? _client.auth.currentUser?.id;
    if (id == null) return [];
    final rows = await _client
        .from('seller_payouts')
        .select()
        .eq('seller_id', id)
        .order('paid_at', ascending: false);
    return rows.map(SellerPayout.fromJson).toList();
  }

  // ----- 관리자용 -----

  Future<List<SellerProfile>> fetchAllSellers() async {
    final rows = await _client
        .from('seller_profiles')
        .select()
        .order('created_at', ascending: false);
    return rows.map(SellerProfile.fromJson).toList();
  }

  Future<void> updateSellerStatus(String userId, String status) async {
    await _client
        .from('seller_profiles')
        .update({'status': status}).eq('user_id', userId);
  }

  Future<void> updateCommissionRate(String userId, double rate) async {
    await _client
        .from('seller_profiles')
        .update({'commission_rate': rate}).eq('user_id', userId);
  }

  /// 관리자용: 전체 셀러 정산 집계 (seller_id → 정산 요약, 잔액 포함)
  Future<Map<String, SellerSettlement>> fetchAllSettlements() async {
    final rows = await _client.from('seller_balances').select();
    return {
      for (final row in rows)
        row['seller_id'] as String: SellerSettlement.fromJson(row),
    };
  }

  /// 관리자용: 지급 기록 등록 (셀러 계좌로 이체한 뒤 기록)
  Future<void> recordPayout({
    required String sellerId,
    required int amount,
    String memo = '',
  }) async {
    await _client.from('seller_payouts').insert({
      'seller_id': sellerId,
      'amount': amount,
      'memo': memo,
    });
  }
}
