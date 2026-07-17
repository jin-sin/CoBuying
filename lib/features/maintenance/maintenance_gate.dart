import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'maintenance_providers.dart';

/// 점검 시간대면 앱 전체를 안내 화면으로 덮는다.
class MaintenanceGate extends ConsumerWidget {
  const MaintenanceGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(maintenanceActiveProvider)) return child;

    final config = ref.watch(maintenanceConfigProvider).value;
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bedtime_outlined,
                    size: 64, color: theme.colorScheme.primary),
                const SizedBox(height: 24),
                Text('break time ~',
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                Text(
                  config?.message ?? '지금은 서버 점검 시간이에요.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 8),
                if (config != null)
                  Text(
                    '점검 시간: ${config.start} ~ ${config.end}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: Colors.grey[600]),
                  ),
                const SizedBox(height: 32),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('다시 확인'),
                  onPressed: () => ref.invalidate(maintenanceConfigProvider),
                ),
                const SizedBox(height: 8),
                // 관리자가 설정 실수로 잠기지 않게 하는 우회 (이번 실행 한정)
                TextButton(
                  onPressed: () =>
                      ref.read(maintenanceBypassProvider.notifier).enable(),
                  child: Text('무시하고 계속',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
