import 'dart:convert';
import 'dart:math';

typedef BroadcastRow = Map<String, dynamic>;

class BroadcastWorkspace {
  const BroadcastWorkspace({
    required this.role,
    required this.customers,
    required this.sessions,
    required this.products,
    required this.orders,
  });
  factory BroadcastWorkspace.fromJson(BroadcastRow json) => BroadcastWorkspace(
    role: json['role'] as String,
    customers: _rows(json['customers']),
    sessions: _rows(json['sessions']),
    products: _rows(json['products']),
    orders: _rows(json['orders']),
  );
  static List<BroadcastRow> _rows(dynamic value) =>
      (value as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  final String role;
  final List<BroadcastRow> customers, sessions, products, orders;
}

abstract class BroadcastRepository {
  Future<BroadcastWorkspace> load();
  Future<BroadcastRow> customerPage(
    String query, {
    String? afterNickname,
    String? afterId,
  });
  Future<BroadcastRow> orderPage(String sessionId, {int? beforeSequence});
  Future<BroadcastRow> execute(BroadcastCommand command);
  Future<BroadcastRow> staffOverview();
}

/// Keep this object unchanged until the server confirms success, including on timeout.
/// A genuinely new order must create a new command even if the options match.
class BroadcastCommand {
  BroadcastCommand(this.name, BroadcastRow data)
    : key = _uuid(),
      payload = jsonEncode(data);
  BroadcastCommand.restore(this.name, this.key, this.payload) {
    if (name.isEmpty ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(key) ||
        jsonDecode(payload) is! Map<String, dynamic>) {
      throw const FormatException('Invalid saved broadcast command');
    }
  }
  final String name, key, payload;
  BroadcastRow get data =>
      Map<String, dynamic>.from(jsonDecode(payload) as Map);
  static String _uuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}

/// One unresolved mutation per signed-in actor and seller. Writes must finish
/// before the corresponding RPC is sent.
abstract class BroadcastCommandJournal {
  Future<BroadcastCommand?> load();
  Future<void> save(BroadcastCommand command);
  Future<void> clear(BroadcastCommand command);
}

class BroadcastRejected implements Exception {
  const BroadcastRejected(this.message, this.code);
  final String message;
  final String? code;
}
