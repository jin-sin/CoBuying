import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'legal.dart';

/// 법적 고지 진입 허브 — 약관·개인정보·사업자정보로 연결.
class InfoHubPage extends StatelessWidget {
  const InfoHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <(String, IconData, String)>[
      ('셀러 입점 안내', Icons.storefront_outlined, '/partner'),
      ('이용약관', Icons.description_outlined, '/terms'),
      ('개인정보처리방침', Icons.privacy_tip_outlined, '/privacy'),
      ('사업자정보', Icons.store_outlined, '/business'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('약관 및 정책')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final (label, icon, route) in items)
                SoftCard(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 4),
                  onTap: () => context.push(route),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(icon, color: brandOrange),
                    title: Text(label,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.chevron_right,
                        color: mutedText),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 이용약관·개인정보처리방침 공용 렌더러
class LegalDocPage extends StatelessWidget {
  const LegalDocPage({super.key, required this.doc});

  final LegalDoc doc;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(doc.title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              Text(doc.updated,
                  style: const TextStyle(fontSize: 12, color: mutedText)),
              const SizedBox(height: 16),
              for (final (heading, body) in doc.sections) ...[
                Text(heading,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: inkText)),
                const SizedBox(height: 6),
                Text(body,
                    style: const TextStyle(
                        fontSize: 13.5, height: 1.65, color: Color(0xFF4A443E))),
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 사업자정보 (전자상거래법 표시 의무 항목) + 통신판매중개자 고지
class BusinessInfoPage extends StatelessWidget {
  const BusinessInfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('사업자정보')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (label, value) in BusinessInfo.rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 128,
                              child: Text(label,
                                  style: const TextStyle(
                                      fontSize: 13, color: mutedText)),
                            ),
                            Expanded(
                              child: Text(value,
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: softBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  brokerNotice,
                  style: TextStyle(
                      fontSize: 12.5, height: 1.6, color: Color(0xFF6E675F)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
