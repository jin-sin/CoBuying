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
    this.businessNumber = '',
    this.onlineSalesNumber = '',
  });

  final String userId;
  final String shopName;
  final String bankName;
  final String bankAccount;
  final String accountHolder;
  final String contactPhone;
  final double commissionRate;
  final String status; // pending | approved | rejected | suspended
  final String businessNumber; // 사업자등록번호 (숫자 10자리)
  final String onlineSalesNumber; // 통신판매업 신고번호 (선택)

  /// 000-00-00000 표시용
  String get businessNumberFormatted => businessNumber.length == 10
      ? '${businessNumber.substring(0, 3)}-${businessNumber.substring(3, 5)}-${businessNumber.substring(5)}'
      : businessNumber;

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
        businessNumber: json['business_number'] as String? ?? '',
        onlineSalesNumber: json['online_sales_number'] as String? ?? '',
      );
}

/// seller_balances 뷰의 한 행 (누적 정산액과 지급 차감 잔액)
class SellerSettlement {
  const SellerSettlement({
    required this.orderCount,
    required this.grossSales,
    required this.totalFees,
    required this.netPayout,
    this.totalPaid = 0,
    this.balance = 0,
  });

  final int orderCount;
  final int grossSales; // 총 판매액
  final int totalFees; // 플랫폼 수수료
  final int netPayout; // 누적 정산액 (판매액 - 수수료)
  final int totalPaid; // 지급 완료 합계
  final int balance; // 미지급 잔액

  static const empty = SellerSettlement(
      orderCount: 0, grossSales: 0, totalFees: 0, netPayout: 0);

  factory SellerSettlement.fromJson(Map<String, dynamic> json) =>
      SellerSettlement(
        orderCount: (json['order_count'] as num).toInt(),
        grossSales: (json['gross_sales'] as num).toInt(),
        totalFees: (json['total_fees'] as num).toInt(),
        netPayout: (json['net_payout'] as num).toInt(),
        totalPaid: (json['total_paid'] as num? ?? 0).toInt(),
        balance: (json['balance'] as num? ?? json['net_payout'] as num).toInt(),
      );
}

/// 지급(정산 이체) 기록 한 건
class SellerPayout {
  const SellerPayout({
    required this.amount,
    required this.memo,
    required this.paidAt,
  });

  final int amount;
  final String memo;
  final DateTime paidAt;

  factory SellerPayout.fromJson(Map<String, dynamic> json) => SellerPayout(
        amount: (json['amount'] as num).toInt(),
        memo: json['memo'] as String? ?? '',
        paidAt: DateTime.parse(json['paid_at'] as String),
      );
}
