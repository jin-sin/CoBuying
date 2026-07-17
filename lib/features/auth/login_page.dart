import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth_providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _busy = false;

  Future<void> _signIn(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      // 앱 네이티브 로그인은 페이지 리다이렉트 없이 세션이 생기므로 명시적으로
      // 이동한다. (웹 OAuth는 이 시점에 아직 세션이 없어 그냥 지나간다)
      if (mounted && ref.read(authRepositoryProvider).currentUser != null) {
        final from =
            GoRouterState.of(context).uri.queryParameters['from'];
        context.go(from ?? '/');
        return;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is UnimplementedError ? '${e.message}' : '로그인에 실패했습니다: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.read(authRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('로그인')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.shopping_bag_outlined, size: 72),
                const SizedBox(height: 12),
                Text('공동구매',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 40),
                _SocialButton(
                  label: '카카오로 시작하기',
                  background: const Color(0xFFFEE500),
                  foreground: Colors.black87,
                  icon: Icons.chat_bubble,
                  onPressed: _busy ? null : () => _signIn(auth.signInWithKakao),
                ),
                const SizedBox(height: 12),
                _SocialButton(
                  label: '네이버로 시작하기',
                  background: const Color(0xFF03C75A),
                  foreground: Colors.white,
                  icon: Icons.eco,
                  onPressed: _busy ? null : () => _signIn(auth.signInWithNaver),
                ),
                const SizedBox(height: 12),
                _SocialButton(
                  label: '페이스북으로 시작하기',
                  background: const Color(0xFF1877F2),
                  foreground: Colors.white,
                  icon: Icons.facebook,
                  onPressed:
                      _busy ? null : () => _signIn(auth.signInWithFacebook),
                ),
                if (_busy) ...[
                  const SizedBox(height: 24),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
      ),
      icon: Icon(icon),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onPressed: onPressed,
    );
  }
}
