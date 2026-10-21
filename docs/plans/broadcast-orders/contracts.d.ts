/** v2.2.0 / requirements-v1 (2026-09-28). Planned full MVP types; B01–B08 are partially implemented. */
export type ID = string;
export type Currency = "KRW" | "CNY";
export interface Money {
  currency: Currency;
  minor: number;
}
export type Role = "assistant" | "manager";
/** B01 RPC results are bounded; cursors are null on the final page. */
export interface BroadcastCustomerPageRpc {
  items: Array<{ id: ID; seller_id: ID; nickname: string; wechat_note: string; created_at: string }>;
  next_nickname: string | null;
  next_id: ID | null;
}
export interface BroadcastOrderPageRpc {
  items: Array<{ id: ID; sequence: number; session_id: ID; customer_id: ID; nickname: string; product_id: ID; product_title: string; product_number: number; color: string; size: string; quantity: number; original: unknown }>;
  next_before_sequence: number | null;
}
/** B01 broadcast_staff_overview RPC response (snake_case is intentional). */
export interface StaffMembershipRpc {
  user_id: ID;
  role: Role;
}
export interface StaffInviteRpc {
  code: ID;
  expires_at: string;
}
export interface StaffOverviewRpc {
  members: StaffMembershipRpc[];
  invites: StaffInviteRpc[];
}
export interface Customer {
  id: ID;
  sellerId: ID;
  nickname: string;
  wechatNote: string;
  locator: string;
  address: Address | null;
}
export interface Address {
  country: "KR" | "CN";
  recipient: string;
  phone: string;
  region: string;
  detail: string;
  postalCode?: string;
}
export interface BroadcastSession {
  id: ID;
  version: number;
  sellerId: ID;
  date: string;
  title: string;
  kind: "new" | "special";
  krwPerCny: string;
  shippingKrw: number;
  shippingCnyFen: number;
  freeShippingCount: number;
  managementDays: number;
  closesAt: string;
  status: "draft" | "open" | "closed" | "archived";
}
export interface Product {
  id: ID;
  deletedAt: string | null;
  sessionId: ID;
  sellerId: ID;
  number: number;
  supplierId: ID;
  title: string;
  priceKrw: number;
  colors: string[];
  sizes: string[];
  visible: boolean;
  publicOrder: number;
  inOutfit: boolean;
  shippingExcluded: boolean;
  quantityLimited: boolean;
  availableQuantity: number | null;
  version: number;
}
export interface LineSnapshot {
  productId: ID;
  title: string;
  color: string;
  size: string;
  quantity: number;
  unitPriceKrw: number;
  note: string;
}
export interface OrderLine {
  id: ID;
  sellerId: ID;
  customerId: ID;
  sessionId: ID;
  sequence: string;
  createdAt: string;
  source: "broadcast_assistant" | "seller_input" | "customer_addition";
  createdBy: ID;
  original: LineSnapshot | { productId: ID; rawText: string };
  current: LineSnapshot | null;
  needsReview: boolean;
  cancelled: boolean;
  version: number;
}
export interface ChangeRequest {
  id: ID;
  customerId: ID;
  lineId: ID;
  reason: string;
  status: "open" | "applied" | "declined";
  resolution?: string;
}
export interface DepositEntry {
  id: ID;
  customerId: ID;
  receiverId: ID;
  received: Money;
  verifiedBy: ID;
  transactionRef: string;
  receivedAt: string;
}
export interface DepositAllocation {
  id: ID;
  depositId: ID;
  invoiceId: ID;
  amount: Money;
  reversedAt: string | null;
}
export interface Invoice {
  id: ID;
  version: number;
  customerId: ID;
  sessionId: ID;
  issuedAt: string;
  lines: Array<LineSnapshot & { orderLineId: ID }>;
  krwPerCny: string;
  country: "KR" | "CN";
  subtotalKrw: number;
  shipping: Money;
  depositKrw: number;
  totalKrw: number;
  totalCnyFen: number;
  selectedCurrency: Currency | null;
  acceptedAt: string | null;
  receiverSnapshots: ReceiverSnapshot[];
  shippingRule: {
    freeCount: number;
    excludedProductIds: ID[];
    krw: number;
    cnyFen: number;
  };
  status: "issued" | "superseded" | "void";
}
export interface Evidence {
  id: ID;
  invoiceId: ID;
  privateObjectKey: string;
  status: "uploading" | "stored" | "rejected";
  submittedAt: string | null;
}
export interface Receipt {
  id: ID;
  invoiceId: ID;
  evidenceId: ID;
  amount: Money;
  payerName: string;
  receiverId: ID;
  transactionRef: string;
  receivedAt: string;
  status: "pending_review" | "needs_info" | "confirmed" | "rejected";
  clarificationReason: string | null;
  evidenceHistoryIds: ID[];
  verifiedBy: ID | null;
}
export interface PaymentSummary {
  confirmed: Money;
  refunded: Money;
  netReceived: Money;
  remaining: Money;
  excess: Money;
  status:
    | "unpaid"
    | "reviewing"
    | "partial"
    | "settled"
    | "overpaid"
    | "refund_pending";
}
export interface RefundRecord {
  id: ID;
  invoiceId: ID;
  sourceReceiptIds: ID[];
  amount: Money;
  reason: string;
  status: "pending" | "confirmed";
  actualTransactionRef: string | null;
}
export interface PurchaseOrderItem {
  id: ID;
  purchaseOrderId: ID;
  supplierId: ID;
  productId: ID;
  color: string;
  size: string;
  quantity: number;
  orderedAt: string;
  allocations: Array<{ orderLineId: ID; quantity: number }>;
}
export interface Arrival {
  id: ID;
  purchaseOrderItemId: ID;
  arrivedAt: string;
  quantity: number;
  idempotencyKey: ID;
}
export interface CustomerAllocation {
  id: ID;
  arrivalId: ID;
  orderLineId: ID;
  quantity: number;
  confirmedBy: ID;
}
export interface DefectExchange {
  id: ID;
  allocationId: ID;
  quantity: number;
  status: "awaiting_exchange" | "replaced";
  note: string;
}
export interface Shipment {
  id: ID;
  customerId: ID;
  shippedAt: string;
  addressSnapshot: Address;
  courier: string;
  trackingNumber: string;
  lines: Array<{ orderLineId: ID; allocationId: ID; quantity: number }>;
  isPartial: boolean;
  additionalCustomerShippingMinor: 0;
}
export interface WorkTask {
  id: ID;
  customerId: ID;
  sourceId: ID;
  kind:
    | "change"
    | "addition"
    | "address"
    | "evidence"
    | "unpaid_3d"
    | "cancel_review"
    | "unarrived_14d"
    | "device_verification"
    | "refund";
  createdAt: string;
  resolvedAt: string | null;
  resolution: string | null;
}
/** Actual B01 uses Supabase snake_case JSON. Sequence is transported without reordering. */
export interface CaptureCommandInput {
  p_seller_id: ID;
  p_command:
    | "customer.create"
    | "session.create"
    | "session.update"
    | "product.create"
    | "product.update"
    | "product.archive"
    | "product.restore"
    | "product.reorder"
    | "product.publish"
    | "order.create"
    | "order.revise";
  p_data: Record<string, unknown>;
  p_key: ID;
}
export interface GuestSession {
  customerId: ID;
  sellerId: ID;
  deviceId: ID;
  expiresAt: string;
}
/** locator is not a credential; customer IDs are derived from the authenticated device session. */
export interface ActivateDeviceInput {
  token: string;
  csrfToken: string;
}

/** Planned v2.1 details. Not yet implemented in B01 RPC. */
export interface ReceiverSetting {
  id: ID;
  sellerId: ID;
  method: "bank" | "wechat" | "alipay";
  currency: Currency;
  holder: string;
  instructions: string;
  privateQrObjectId: ID | null;
  verifiedBy: ID | null;
  verifiedAt: string | null;
  active: boolean;
  version: number;
}
export interface ReceiverSnapshot extends Omit<ReceiverSetting, "active"> {
  capturedAt: string;
}
export interface DeviceRequest {
  id: ID;
  customerId: ID;
  requestDeviceNonceHash: string;
  status: "pending" | "approved" | "activated" | "expired" | "revoked";
  verifiedBy: ID | null;
  verifiedAt: string | null;
  activationExpiresAt: string | null;
}
export interface AddressRevision {
  id: ID;
  customerId: ID;
  before: Address | null;
  after: Address;
  actorId: ID;
  reason: string;
  createdAt: string;
  /** Existing shipment snapshots are never updated. */
  supersededInvoiceIds: ID[];
}
export interface ExportRequest {
  id: ID;
  sellerId: ID;
  requestedBy: ID;
  kind: "supplier" | "customers";
  sessionIds: ID[];
  supplierId: ID | null;
  status: "queued" | "ready" | "failed" | "expired";
  snapshotAt: string;
  rowCount: number;
  /** Signed short-lived download. Staff session required; no public object. */
  downloadUrl: string | null;
}
