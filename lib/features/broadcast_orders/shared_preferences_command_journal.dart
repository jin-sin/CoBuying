import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'broadcast_repository.dart';

/// Keeps only the unresolved command. The actor/seller scope prevents an
/// account switch from replaying another account's mutation.
class SharedPreferencesCommandJournal implements BroadcastCommandJournal {
  SharedPreferencesCommandJournal({
    required String actorId,
    required String sellerId,
    SharedPreferencesAsync? preferences,
  }) : _key = 'broadcast.pending.v1.$actorId.$sellerId',
       _preferences = preferences ?? SharedPreferencesAsync();

  final String _key;
  final SharedPreferencesAsync _preferences;

  @override
  Future<BroadcastCommand?> load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return null;
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    if (saved['version'] != 1) {
      throw const FormatException('Unknown broadcast command format');
    }
    return BroadcastCommand.restore(
      saved['name'] as String,
      saved['key'] as String,
      saved['payload'] as String,
    );
  }

  @override
  Future<void> save(BroadcastCommand command) async {
    final existing = await load();
    if (existing != null && existing.key != command.key) {
      throw StateError('Resolve the previous broadcast command first');
    }
    await _preferences.setString(
      _key,
      jsonEncode({
        'version': 1,
        'name': command.name,
        'key': command.key,
        'payload': command.payload,
      }),
    );
  }

  @override
  Future<void> clear(BroadcastCommand command) async {
    final existing = await load();
    if (existing == null) return;
    if (existing.key != command.key) {
      throw StateError('A different broadcast command is pending');
    }
    await _preferences.remove(_key);
  }
}
