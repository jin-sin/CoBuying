class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.link,
    required this.createdAt,
    this.readAt,
  });

  final String id;
  final String title;
  final String body;
  final String link; // 탭하면 이동할 앱 라우트 (빈 값이면 이동 없음)
  final DateTime createdAt;
  final DateTime? readAt;

  bool get isRead => readAt != null;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] as String,
        title: json['title'] as String,
        body: json['body'] as String? ?? '',
        link: json['link'] as String? ?? '',
        createdAt: DateTime.parse(json['created_at'] as String),
        readAt: json['read_at'] == null
            ? null
            : DateTime.parse(json['read_at'] as String),
      );
}
