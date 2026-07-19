import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import 'app_notification.dart';
import 'notifications_providers.dart';

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  Future<void> _open(
      BuildContext context, WidgetRef ref, AppNotification n) async {
    if (!n.isRead) {
      // 실패해도 이동은 계속
      try {
        await ref.read(notificationsRepositoryProvider).markRead(n.id);
        ref.invalidate(notificationsProvider);
      } catch (_) {}
    }
    if (context.mounted && n.link.isNotEmpty) {
      context.push(n.link);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(notificationsProvider);
    final unread = ref.watch(unreadNotificationCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('알림'),
        actions: [
          if (unread > 0)
            TextButton(
              onPressed: () async {
                await ref.read(notificationsRepositoryProvider).markAllRead();
                ref.invalidate(notificationsProvider);
              },
              child: const Text('모두 읽음'),
            ),
        ],
      ),
      body: notifications.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('알림을 불러오지 못했습니다.\n$e')),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_none,
                      size: 64, color: Color(0xFFB9B1A8)),
                  SizedBox(height: 16),
                  Text('알림이 없습니다.', style: TextStyle(color: mutedText)),
                ],
              ),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final n = items[i];
                  return ListTile(
                    leading: Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: n.isRead
                            ? softBg
                            : const Color(0xFFFFEDE4),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        n.isRead
                            ? Icons.notifications_none
                            : Icons.notifications_active,
                        size: 20,
                        color: n.isRead
                            ? const Color(0xFFB9B1A8)
                            : const Color(0xFFC24A1D),
                      ),
                    ),
                    title: Text(n.title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                n.isRead ? FontWeight.w500 : FontWeight.w800)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(n.body,
                              style: const TextStyle(
                                  fontSize: 13, color: mutedText)),
                          const SizedBox(height: 2),
                          Text(formatDateTime(n.createdAt),
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFFB9B1A8))),
                        ],
                      ),
                    ),
                    isThreeLine: true,
                    onTap: () => _open(context, ref, n),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
