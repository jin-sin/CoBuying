class SellerProfile {
  const SellerProfile({
    required this.userId,
    required this.shopName,
    required this.bankName,
    required this.bankAccount,
    required this.accountHolder,
    required this.contactPhone,
    required this.commissionRate,
    required this.status,
  });

  final String userId;
  final String shopName;
  final String bankName;
  final String bankAccount;
  final String accountHolder;
  final String contactPhone;
  final double commissionRate;
  final String status; // pending | approved | rejected | suspended

  bool get isApproved => status == 'approved';

  String get statusLabel => switch (status) {
        'pending' => '승인 대기중',
        'approved' => '승인됨',
        'rejected' => '반려됨',
        'suspended' => '이용 정지',
        _ => status,
      };

  factory SellerProfile.fromJson(Map<String, dynamic> json) => SellerProfile(
        userId: json['user_id'] as String,
        shopName: json['shop_name'] as String,
        bankName: json['bank_name'] as String,
        bankAccount: json['bank_account'] as String,
        accountHolder: json['account_holder'] as String,
        contactPhone: json['contact_phone'] as String? ?? '',
        commissionRate: (json['commission_rate'] as num).toDouble(),
        status: json['status'] as String,
      );
}

/// seller_settlements 뷰의 한 행
class SellerSettlement {
  const SellerSettlement({
    required this.orderCount,
    required this.grossSales,
    required this.totalFees,
    required this.netPayout,
  });

  final int orderCount;
  final int grossSales; // 총 판매액
  final int totalFees; // 플랫폼 수수료
  final int netPayout; // 셀러 지급액

  static const empty = SellerSettlement(
      orderCount: 0, grossSales: 0, totalFees: 0, netPayout: 0);

  factory SellerSettlement.fromJson(Map<String, dynamic> json) =>
      SellerSettlement(
        orderCount: (json['order_count'] as num).toInt(),
        grossSales: (json['gross_sales'] as num).toInt(),
        totalFees: (json['total_fees'] as num).toInt(),
        netPayout: (json['net_payout'] as num).toInt(),
      );
}
