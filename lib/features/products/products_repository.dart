import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'product.dart';

class ProductsRepository {
  ProductsRepository(this._client);

  final SupabaseClient _client;

  /// 판매 중인 상품 목록 (기한 지난 상품 제외, DB 뷰 사용)
  Future<List<Product>> fetchActiveProducts() async {
    final rows = await _client
        .from('active_products')
        .select()
        .order('ends_at', ascending: true);
    return rows.map(Product.fromJson).toList();
  }

  /// 관리자용: 상태 무관 전체 상품
  Future<List<Product>> fetchAllProducts() async {
    final rows =
        await _client.from('products').select().order('created_at', ascending: false);
    return rows.map(Product.fromJson).toList();
  }

  /// 셀러용: 내가 등록한 상품 (RLS로도 이중 보호됨)
  Future<List<Product>> fetchMyProducts() async {
    final user = _client.auth.currentUser;
    if (user == null) return [];
    final rows = await _client
        .from('products')
        .select()
        .eq('seller_id', user.id)
        .order('created_at', ascending: false);
    return rows.map(Product.fromJson).toList();
  }

  /// 공개 스토어프론트용: 한 셀러의 상품 (숨김 제외 — RLS도 같은 조건).
  /// 마감된 것까지 가져온다. 지난 공구가 보여야 스토어가 살아있어 보인다.
  Future<List<Product>> fetchShopProducts(String sellerId) async {
    final rows = await _client
        .from('products')
        .select()
        .eq('seller_id', sellerId)
        .neq('status', 'hidden')
        .order('ends_at', ascending: false);
    return rows.map(Product.fromJson).toList();
  }

  Future<Product?> fetchProduct(String id) async {
    final row =
        await _client.from('products').select().eq('id', id).maybeSingle();
    return row == null ? null : Product.fromJson(row);
  }

  Future<void> createProduct(Product product) async {
    final user = _client.auth.currentUser;
    if (user == null) throw const AuthException('로그인이 필요합니다.');
    await _client.from('products').insert({
      ...product.toInsertJson(),
      'seller_id': user.id,
    });
  }

  Future<void> updateProduct(String id, Product product) async {
    await _client.from('products').update(product.toInsertJson()).eq('id', id);
  }

  Future<void> updateStatus(String id, String status) async {
    await _client.from('products').update({'status': status}).eq('id', id);
  }

  /// 이미지 업로드 후 public URL 반환
  Future<String> uploadImage(String fileName, Uint8List bytes) async {
    final path = '${DateTime.now().millisecondsSinceEpoch}_$fileName';
    await _client.storage.from('product-images').uploadBinary(path, bytes);
    return _client.storage.from('product-images').getPublicUrl(path);
  }
}
