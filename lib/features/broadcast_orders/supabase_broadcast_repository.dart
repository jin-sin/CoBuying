import 'package:supabase_flutter/supabase_flutter.dart';
import 'broadcast_repository.dart';

class SupabaseBroadcastRepository implements BroadcastRepository {
  SupabaseBroadcastRepository(this.client, this.sellerId);
  final SupabaseClient client;
  final String sellerId;
  @override
  Future<BroadcastWorkspace> load() async => BroadcastWorkspace.fromJson(
    Map<String, dynamic>.from(
      await client.rpc('broadcast_workspace', params: {'p_seller_id': sellerId})
          as Map,
    ),
  );
  @override
  Future<BroadcastRow> customerPage(
    String query, {
    String? afterNickname,
    String? afterId,
  }) async => Map<String, dynamic>.from(
    await client.rpc(
          'broadcast_customer_page',
          params: {
            'p_seller_id': sellerId,
            'p_query': query,
            'p_after_nickname': afterNickname,
            'p_after_id': afterId,
          },
        )
        as Map,
  );
  @override
  Future<BroadcastRow> orderPage(
    String sessionId, {
    int? beforeSequence,
  }) async => Map<String, dynamic>.from(
    await client.rpc(
          'broadcast_order_page',
          params: {
            'p_seller_id': sellerId,
            'p_session_id': sessionId,
            'p_before_sequence': beforeSequence,
          },
        )
        as Map,
  );
  @override
  Future<BroadcastRow> execute(BroadcastCommand command) async {
    try {
      return Map<String, dynamic>.from(
        await client.rpc(
              command.name.startsWith('staff.')
                  ? 'broadcast_staff_manage'
                  : 'broadcast_command',
              params: command.name.startsWith('staff.')
                  ? {
                      'p_seller_id': sellerId,
                      'p_action': command.name.substring(6),
                      'p_user_id': command.data['user_id'],
                      'p_key': command.key,
                    }
                  : {
                      'p_seller_id': sellerId,
                      'p_command': command.name,
                      'p_data': command.data,
                      'p_key': command.key,
                    },
            )
            as Map,
      );
    } on PostgrestException catch (e) {
      // Only a definite PostgreSQL rejection permits changing the draft/key.
      // Transport/gateway failures may have happened AFTER commit: retry same key.
      if (e.code != null && RegExp(r'^(22|23|42|40|P0)').hasMatch(e.code!)) {
        throw BroadcastRejected(e.message, e.code);
      }
      rethrow;
    }
  }

  @override
  Future<BroadcastRow> staffOverview() async => Map<String, dynamic>.from(
    await client.rpc(
          'broadcast_staff_overview',
          params: {'p_seller_id': sellerId},
        )
        as Map,
  );
}
