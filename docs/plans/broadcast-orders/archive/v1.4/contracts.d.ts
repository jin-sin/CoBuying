/** 설계 계약 v1.4. 실행 코드가 아니다. 시간은 UTC ISO8601, ID는 불투명 문자열.
 * 서비스 브랜드: 오렌담마켓 / ORENDAM. sellerName·수취인명은 브랜드와 별도인 실제 주체.
 * 고객 전달 타입에 guestId, 토큰 원문, 저장소 영구 URL을 추가하지 않는다.
 * 모든 서버 응답은 권한 검사 뒤 구성한다. 서버 내부 엔티티는 별도 정의한다.
 */
export type Id = string;
export type Instant = string;
export type Currency = 'CNY' | 'KRW';
export type Money = { currency: Currency; minor: number }; // 정수 >= 0, CNY=분, KRW=원
export type Versioned = { id: Id; version: number }; // 버전 정수 >= 1
export type Method = 'wechat_transfer' | 'alipay_transfer';
export type CollectionMode = 'seller_direct'; // 플랫폼 수금은 후속 계약 버전
export type StaffPermission = 'manage_catalog' | 'manage_invoices' | 'verify_receipts' | 'manage_shipping';
export type PaymentState = 'unpaid' | 'pending_review' | 'needs_info' | 'confirmed';
export type ErrorCode =
  | 'UNAUTHENTICATED' | 'FORBIDDEN' | 'NOT_FOUND' | 'SESSION_EXPIRED'
  | 'VALIDATION_FAILED' | 'REQUEST_CLOSED' | 'VERSION_CONFLICT'
  | 'PRICE_CHANGED' | 'INVOICE_CHANGED' | 'PAYMENT_LOCKED'
  | 'EVIDENCE_NOT_READY' | 'EVIDENCE_INVALID' | 'DUPLICATE_RECEIPT'
  | 'AMOUNT_MISMATCH' | 'RECOVERY_INVALID' | 'IDEMPOTENCY_CONFLICT'
  | 'RATE_LIMITED' | 'MAINTENANCE' | 'PRODUCT_UNAVAILABLE'
  | 'PRODUCT_CHANGED' | 'PRODUCT_HAS_REQUESTS' | 'PRODUCT_LOCKED';
export type ApiError = {
  error: { code: ErrorCode; message: string; requestId: Id; retryable: boolean;
    fieldErrors?: Record<string, string>; currentVersion?: number; retryAfterSeconds?: number };
};
/** 다른 기기의 변경을 덮어쓰지 않는다. API의 If-Match와 Idempotency-Key에 대응. */
export type MutationContext = { expectedVersion: number; idempotencyKey: string };
export type CreateContext = { idempotencyKey: string };

export interface BroadcastSession extends Versioned {
  sellerId: Id; sellerName: string; sellerSlug: string; title: string;
  currency: Currency; status: 'draft' | 'open' | 'closed' | 'archived';
  phase: 'introducing' | 'ordering'; acceptsRequests: boolean;
  requestClosesAt: Instant | null; publishedAt: Instant | null;
}
export interface ProductOption { id: Id; label: string; values: { id: Id; label: string }[] }
export interface BroadcastProduct extends Versioned {
  sessionId: Id; number: number; name: string; // 사진 없이 번호·이름으로 식별
  unitPrice: Money; options: ProductOption[]; allowCustomerNote: boolean;
  state: 'published' | 'paused' | 'sold_out';
}
export interface PublicCatalog {
  seller: { id: Id; name: string; slug: string };
  session: BroadcastSession | null; products: BroadcastProduct[];
  serverTime: Instant; // 이전 방송 개인 주문은 공개 응답에 포함하지 않음
}
export interface ProductDraftInput {
  name: string; unitPrice: Money | null;
  options?: ProductOption[]; // 생략하면 빈 목록
  allowCustomerNote?: boolean; // 기본 true, 목록이 없을 때 고객 옵션 메모 허용
}
export type ManagedProduct = Omit<BroadcastProduct, 'unitPrice' | 'state'> & {
  unitPrice: Money | null; state: BroadcastProduct['state'] | 'draft' | 'deleted';
  hasRequestHistory: boolean; canEdit: boolean; canDelete: boolean;
  // 서버가 권한·회차·판매 상태·취소 포함 접수 이력으로 산출. 최종 변경 트랜잭션에서 재검사.
};
/** 접수 이력이 있으면 모든 필드 변경을 PRODUCT_LOCKED로 거부한다. 상태는 availability로만 변경. */
export type ProductUpdateInput = Partial<ProductDraftInput> & { reason: string };
export type ProductActionInput = { reason: string };
export type ProductAvailabilityInput = ProductActionInput & { state: 'published' | 'paused' | 'sold_out' };
export interface StaffSessionView { session: BroadcastSession; products: ManagedProduct[]; permissions: StaffPermission[] }
export interface GuestAccess {
  expiresAt: Instant; csrfToken: string;
  scope: { kind: 'guest' } | { kind: 'request'; requestId: Id };
  // Set-Cookie의 자격 원문을 JavaScript에 반환하지 않음
}
export interface ContactInput {
  nickname: string; channel: 'wechat' | 'phone'; value: string;
  privacyNoticeVersion: string; // 고객이 확인한 개인정보 안내 버전
}
export interface RequestLineInput {
  productId: Id; productVersion: number; // 고객이 확인한 버전. 초안의 버전을 자동으로 최신 값으로 치환하지 않음.
  selections: { optionId: Id; valueId: Id }[]; customerNote?: string; quantity: number; // 정수 1..99
}
export interface RequestLine {
  id: Id; productId: Id; productVersion: number; number: number;
  productName: string; customerNote: string | null;
  currentProductState: BroadcastProduct['state'] | 'deleted'; currentProductVersion: number; // 현재 안내값; 저장 스냅샷과 구분
  selections: { optionId: Id; valueId: Id; optionLabel: string; valueLabel: string }[];
  quantity: number; quotedUnitPrice: Money;
}
export interface PurchaseRequest extends Versioned {
  sessionId: Id; sellerName: string; sessionTitle: string; number: string;
  status: 'submitted' | 'locked' | 'invoiced' | 'cancelled';
  nickname: string; contactMasked: string; lines: RequestLine[];
  estimatedTotal: Money; shippingAddress: MaskedAddress | null;
  invoiceId: Id | null; updatedAt: Instant;
}
export interface ShippingAddressInput {
  country: 'CN'; recipient: string; phoneCountryCode: string; phone: string;
  province: string; city: string; district: string; addressLine: string; postalCode?: string;
}
export interface MaskedAddress { recipientMasked: string; phoneMasked: string; region: string; detailMasked: string }
export interface InvoiceLine {
  requestLineId: Id; productName: string; optionsLabel: string;
  customerNote: string | null; requestedQuantity: number; requestedUnitPrice: Money;
  confirmedQuantity: number; unitPrice: Money; lineTotal: Money;
  excluded: boolean; exclusionReason: string | null; // 제외는 수량/합계 0, 별도 이력 표시. 원 요청 행을 삭제하지 않음.
}
export type InvoiceChange =
  | { kind: 'unit_price'; requestLineId: Id; before: Money; after: Money }
  | { kind: 'quantity'; requestLineId: Id; before: number; after: number }
  | { kind: 'item_excluded'; requestLineId: Id; previousQuantity: number; previousTotal: Money; reason: string }
  | { kind: 'shipping' | 'total'; before: Money; after: Money };
export type InvoiceChangeRequestInput = {
  invoiceContentVersion: number; reason: string; confirmedNotTransferred: true;
} & (
  | { kind: 'adjustment' }
  | { kind: 'remove_items'; removeRequestLineIds: Id[]; confirmedRemoval: true; cancelIfAllCurrentItemsRemoved: true }
);
export interface InvoiceChangeRequest extends Versioned {
  kind: 'adjustment' | 'remove_items'; removeRequestLineIds: Id[];
  confirmedRemoval: boolean; cancelIfAllCurrentItemsRemoved: boolean;
  reason: string; confirmedNotTransferred: true; previouslyAccepted: boolean; requestedAt: Instant;
}
export interface CancelInvoiceRequestInput {
  invoiceContentVersion: number; changeRequestId: Id; reason: string;
  customerRequestReviewed: true;
}
export interface InvoiceCancellation {
  changeRequestId: Id; reason: string; confirmedAt: Instant; confirmedByDisplay: string;
}
export interface RecipientSnapshot {
  id: Id; method: Method; displayName: string;
  accountHint: string; instructions: string; collectionMode: CollectionMode;
  // 실제 수취 경로가 확인된 설정만 노출. 공개 QR URL을 필수로 요구하지 않음.
}
export interface Invoice extends Versioned {
  contentVersion: number; supersedesId: Id | null; // 내용 판본과 상태 변경 version을 구분
  requestId: Id; number: string; status: 'issued' | 'accepted' | 'change_requested' | 'settled' | 'superseded' | 'void';
  lines: InvoiceLine[]; subtotal: Money; shipping: Money; total: Money;
  recipients: RecipientSnapshot[]; acceptedAt: Instant | null;
  paymentState: PaymentState; reviewMessage: string | null;
  changeReason: string | null; changes: InvoiceChange[]; changeRequest: InvoiceChangeRequest | null;
  resolvedChangeRequestId: Id | null; cancellation: InvoiceCancellation | null;
  // changes는 직전 청구(최초 발행은 원 구매 요청)와 서버가 비교. 과거 동의·변경 이력은 감사 기록에 보존.
  shipment: Shipment | null; issuedAt: Instant;
}
export interface InvoiceDraftInput {
  requestId: Id; requestVersion: number;
  lines: { requestLineId: Id; confirmedQuantity: number; unitPrice: Money; excluded: boolean; exclusionReason?: string }[];
  shipping: Money; recipientIds: Id[]; changeReason?: string;
  resolvesChangeRequestId?: Id; shippingRecheckedAfterExclusion?: true;
}
export interface EvidenceReservation {
  evidenceId: Id; uploadUrl: string; expiresAt: Instant; maxBytes: number;
  requiredHeaders: Record<string, string>;
}
export interface Evidence {
  id: Id; invoiceId: Id; invoiceContentVersion: number;
  state: 'reserved' | 'ready' | 'rejected'; filename: string; sizeBytes: number;
  // 단기 서명 열람 URL은 별도 API. objectKey는 반환하지 않음.
}
export interface TransferDetails {
  senderName: string; sentAmount: Money; sentAt: Instant; transactionReference?: string;
}
export type SubmissionInput = {
  invoiceContentVersion: number; recipientId: Id;
} & (
  | { kind: 'image'; evidenceIds: Id[]; details?: TransferDetails }
  | { kind: 'manual_details'; reason: string; details: TransferDetails }
);
export interface PaymentSubmission extends Versioned {
  invoiceId: Id; invoiceContentVersion: number; recipientId: Id;
  kind: 'image' | 'manual_details'; evidenceIds: Id[];
  details: TransferDetails | null; status: 'pending_review' | 'needs_info' | 'confirmed';
  reason: string | null; createdAt: Instant;
}
export interface ReceiptMatch {
  recipientId: Id; actualAmount: Money; receivedAt: Instant;
  receiverLedgerReference: string; senderDisplay: string;
  receiverLedgerChecked: true;
}
export type ReviewInput =
  | { decision: 'confirm'; match: ReceiptMatch }
  | { decision: 'needs_info'; reason: string };
export interface Receipt {
  id: Id; invoiceId: Id; invoiceContentVersion: number; submissionId: Id;
  collectionMode: CollectionMode; actualAmount: Money; receivedAt: Instant;
  reviewedAt: Instant; reviewedBy: Id;
}
export interface Shipment { status: 'preparing' | 'shipped' | 'delivered'; carrier: string | null; trackingNumber: string | null }
export interface RecoveryLink { url: string; expiresAt: Instant; requestId: Id; oneTime: true }
export interface RecoveryIssueInput {
  requestId: Id; verifiedContactRecordId: Id; reason: string;
  // 기존 연락 경로에서 본인 연결을 확인한 기록. 별명만으로 발급 금지.
}
export interface ExceptionRecord {
  id: Id; requestId: Id; kind: 'cancellation' | 'refund';
  status: 'requested' | 'verified_complete'; amount: Money | null; reason: string;
  externalReference: string | null; recordedBy: Id; createdAt: Instant;
}

/** 인증 정보는 어댑터가 부가한다. 이 타입만으로 서버 권한이 보장되지 않음. */
export interface BroadcastGuestGateway {
  getCatalog(slug: string): Promise<PublicCatalog>;
  getGuestAccess(): Promise<GuestAccess>;
  startGuest(context: CreateContext): Promise<GuestAccess>;
  endGuest(): Promise<void>;
  getMyRequests(): Promise<PurchaseRequest[]>;
  getRequest(id: Id): Promise<PurchaseRequest>;
  createRequest(sessionId: Id, input: { contact: ContactInput; lines: RequestLineInput[] }, context: CreateContext): Promise<PurchaseRequest>;
  replaceRequest(id: Id, input: { lines: RequestLineInput[] }, context: MutationContext): Promise<PurchaseRequest>;
  cancelRequest(id: Id, context: MutationContext): Promise<PurchaseRequest>;
  saveAddress(id: Id, input: ShippingAddressInput, context: MutationContext): Promise<PurchaseRequest>;
  getInvoice(id: Id): Promise<Invoice>;
  listInvoiceHistory(requestId: Id, cursor?: string): Promise<{ items: Invoice[]; nextCursor: string | null }>;
  acceptInvoice(id: Id, context: MutationContext): Promise<Invoice>;
  requestInvoiceChange(id: Id, input: InvoiceChangeRequestInput, context: MutationContext): Promise<Invoice>;
  reserveEvidence(id: Id, input: { invoiceContentVersion: number; filename: string; contentType: string; sizeBytes: number }, context: CreateContext): Promise<EvidenceReservation>;
  completeEvidence(id: Id, context: CreateContext): Promise<Evidence>;
  submitPayment(id: Id, input: SubmissionInput, context: MutationContext): Promise<PaymentSubmission>;
  exchangeRecovery(token: string, context: CreateContext): Promise<GuestAccess>;
}
export interface BroadcastStaffGateway {
  getWorkspace(sessionId: Id): Promise<StaffSessionView>;
  createSession(input: { sellerId: Id; title: string; currency: Currency }, context: CreateContext): Promise<BroadcastSession>;
  updateSession(id: Id, input: { status?: BroadcastSession['status']; phase?: BroadcastSession['phase']; requestClosesAt?: Instant | null }, context: MutationContext): Promise<BroadcastSession>;
  saveProduct(sessionId: Id, input: ProductDraftInput, context: CreateContext): Promise<ManagedProduct>;
  updateProduct(id: Id, input: ProductUpdateInput, context: MutationContext): Promise<ManagedProduct>;
  setProductAvailability(id: Id, input: ProductAvailabilityInput, context: MutationContext): Promise<ManagedProduct>;
  deleteProduct(id: Id, input: ProductActionInput, context: MutationContext): Promise<ManagedProduct>;
  restoreProduct(id: Id, input: ProductActionInput, context: MutationContext): Promise<ManagedProduct>;
  listRequests(sessionId: Id, cursor?: string): Promise<{ items: PurchaseRequest[]; nextCursor: string | null }>;
  getShippingAddress(id: Id): Promise<ShippingAddressInput>; // 배송 권한 및 열람 감사
  issueInvoice(input: InvoiceDraftInput, context: CreateContext): Promise<Invoice>;
  reissueInvoice(id: Id, input: InvoiceDraftInput, context: MutationContext): Promise<Invoice>;
  cancelInvoicedRequest(id: Id, input: CancelInvoiceRequestInput, context: MutationContext): Promise<{ request: PurchaseRequest; invoice: Invoice }>;
  listInvoiceHistory(requestId: Id, cursor?: string): Promise<{ items: Invoice[]; nextCursor: string | null }>;
  listSubmissions(sessionId: Id, cursor?: string): Promise<{ items: PaymentSubmission[]; nextCursor: string | null }>;
  getEvidenceReadUrl(id: Id): Promise<{ url: string; expiresAt: Instant }>;
  reviewSubmission(id: Id, input: ReviewInput, context: MutationContext): Promise<{ submission: PaymentSubmission; receipt: Receipt | null }>;
  issueRecovery(input: RecoveryIssueInput, context: CreateContext): Promise<RecoveryLink>;
  updateShipment(invoiceId: Id, input: Shipment, context: MutationContext): Promise<Invoice>;
  recordException(input: Omit<ExceptionRecord, 'id' | 'recordedBy' | 'createdAt'>, context: CreateContext): Promise<ExceptionRecord>;
}
