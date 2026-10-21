import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/service_brand.dart';

class BroadcastStaffJoinPage extends StatefulWidget {
  const BroadcastStaffJoinPage({
    super.key,
    required this.client,
    this.initialCode,
  });
  final SupabaseClient client;
  final String? initialCode;

  @override
  State<BroadcastStaffJoinPage> createState() => _BroadcastStaffJoinPageState();
}

class _BroadcastStaffJoinPageState extends State<BroadcastStaffJoinPage> {
  late final TextEditingController code;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    code = TextEditingController(text: widget.initialCode ?? '');
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> join() async {
    final value = code.text.trim();
    if (!RegExp(
      r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
      caseSensitive: false,
    ).hasMatch(value)) {
      setState(() => error = '참여 코드 형식을 확인해주세요.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = Map<String, dynamic>.from(
        await widget.client.rpc(
              'broadcast_staff_join',
              params: {'p_code': value},
            )
            as Map,
      );
      if (!mounted) return;
      context.go('/seller/broadcast?seller=${result['seller_id']}');
    } on PostgrestException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = '참여 결과를 확인하지 못했습니다. 같은 코드로 다시 확인해주세요.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('${ServiceBrand.shortName} · 방송 담당자 참여')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '판매자가 전달한 일회용 코드를 입력하세요. 참여 후 방송 주문과 해당 판매자의 고객 정보를 볼 수 있습니다.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: code,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: '참여 코드',
                  border: OutlineInputBorder(),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : join,
                child: Text(busy ? '참여 확인 중…' : '방송 담당자로 참여'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
