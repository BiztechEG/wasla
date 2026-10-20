// Data classes for plans, subscriptions and invoices (phase 4).

import 'models.dart';

String _text(Object? value) => value as String? ?? '';

double _money(Object? value) => switch (value) {
  num n => n.toDouble(),
  String s => double.tryParse(s) ?? 0,
  _ => 0,
};

int? _intOrNull(Object? value) => (value as num?)?.toInt();

DateTime? _timeOrNull(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

List<Json> _list(Object? value) => [
  for (final item in (value as List? ?? const [])) Json.from(item as Map),
];

/// A plan as a company sees it: its limits and its price a month.
class PlanOption {
  const PlanOption({
    required this.id,
    required this.name,
    required this.priceUsd,
    required this.priceLocal,
    this.maxMembers,
    this.storageGb,
    this.offered = true,
    this.workspaces = 0,
    this.freeWorkers,
    this.extraWorkerUsd = 0,
  });

  final String id;
  final String name;

  /// Null means unlimited.
  final int? maxMembers;
  final int? storageGb;
  final double priceUsd;
  final double priceLocal;

  /// Whether companies can ask for it.
  final bool offered;

  /// How many workspaces are on it; only platform admins see this.
  final int workspaces;

  /// Workers without the app included free; null means twice the seats.
  /// Only platform admins see this.
  final int? freeWorkers;

  /// The monthly price of each worker past [freeWorkers]; 0 means no more
  /// can be added.
  final double extraWorkerUsd;

  bool get isFree => id == 'free';

  factory PlanOption.fromJson(Json json) => PlanOption(
    id: json['id'] as String,
    name: _text(json['name']),
    maxMembers: _intOrNull(json['max_members']),
    storageGb: _intOrNull(json['storage_gb']),
    priceUsd: _money(json['price_usd']),
    priceLocal: _money(json['price_local']),
    offered: json['offered'] as bool? ?? true,
    workspaces: _intOrNull(json['workspaces']) ?? 0,
    freeWorkers: _intOrNull(json['free_workers']),
    extraWorkerUsd: _money(json['extra_worker_usd']),
  );
}

/// A company that pays, with the currency it pays in.
class BillingCompany {
  const BillingCompany({
    required this.id,
    required this.name,
    required this.countryCode,
    required this.currency,
    required this.rate,
  });

  final String id;
  final String name;
  final String countryCode;
  final String currency;

  /// Local units for one US dollar; 1 while prices are in dollars.
  final double rate;

  factory BillingCompany.fromJson(Json json) => BillingCompany(
    id: json['id'] as String,
    name: _text(json['name']),
    countryCode: _text(json['country_code']),
    currency: _text(json['currency']),
    rate: _money(json['rate']),
  );
}

enum RequestStatus {
  pending,
  invoiced,
  cancelled;

  static RequestStatus parse(Object? value) =>
      values.firstWhere((s) => s.name == value, orElse: () => pending);
}

class PlanRequest {
  const PlanRequest({
    required this.id,
    required this.planId,
    required this.months,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String planId;
  final int months;
  final RequestStatus status;
  final DateTime createdAt;

  factory PlanRequest.fromJson(Json json) => PlanRequest(
    id: json['id'] as String,
    planId: json['plan_id'] as String,
    months: (json['months'] as num).toInt(),
    status: RequestStatus.parse(json['status']),
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

/// One workspace's plan and how much of it is used.
class WorkspaceBilling {
  const WorkspaceBilling({
    required this.id,
    required this.name,
    required this.planId,
    required this.planName,
    required this.members,
    required this.storageBytes,
    this.maxMembers,
    this.storageGb,
    this.paidUntil,
    this.request,
  });

  final String id;
  final String name;
  final String planId;
  final String planName;
  final int? maxMembers;
  final int? storageGb;

  /// Null on the free plan, and on a plan given without an end.
  final DateTime? paidUntil;
  final int members;
  final int storageBytes;

  /// A plan asked for and not yet paid.
  final PlanRequest? request;

  bool get isFree => planId == 'free';

  /// How long after paid time ends the workspace keeps its plan.
  static const grace = Duration(days: 7);

  factory WorkspaceBilling.fromJson(Json json) => WorkspaceBilling(
    id: json['id'] as String,
    name: _text(json['name']),
    planId: json['plan_id'] as String,
    planName: _text(json['plan_name']),
    maxMembers: _intOrNull(json['max_members']),
    storageGb: _intOrNull(json['storage_gb']),
    paidUntil: _timeOrNull(json['paid_until']),
    members: (json['members'] as num?)?.toInt() ?? 0,
    storageBytes: (json['storage_bytes'] as num?)?.toInt() ?? 0,
    request: json['request'] == null
        ? null
        : PlanRequest.fromJson(Json.from(json['request'] as Map)),
  );
}

enum InvoiceStatus {
  issued,
  paid,
  void_;

  String get wire => this == void_ ? 'void' : name;

  static InvoiceStatus parse(Object? value) => switch (value) {
    'paid' => paid,
    'void' => void_,
    _ => issued,
  };
}

class InvoiceLine {
  const InvoiceLine({
    required this.workspaceName,
    required this.planId,
    required this.planName,
    required this.members,
    required this.unitUsd,
    required this.amountUsd,
    required this.amountLocal,
    this.workspaceId,
    this.extraWorkers = 0,
    this.extraWorkerUsd = 0,
  });

  final String? workspaceId;
  final String workspaceName;
  final String planId;
  final String planName;
  final int members;

  /// A month, in dollars.
  final double unitUsd;
  final double amountUsd;
  final double amountLocal;

  /// Workers without the app past the plan's free number, and the monthly
  /// price of each.
  final int extraWorkers;
  final double extraWorkerUsd;

  factory InvoiceLine.fromJson(Json json) => InvoiceLine(
    workspaceId: json['workspace_id'] as String?,
    workspaceName: _text(json['workspace_name']),
    planId: json['plan_id'] as String,
    planName: _text(json['plan_name']),
    members: (json['members'] as num?)?.toInt() ?? 0,
    unitUsd: _money(json['unit_usd']),
    amountUsd: _money(json['amount_usd']),
    amountLocal: _money(json['amount_local']),
    extraWorkers: (json['extra_workers'] as num?)?.toInt() ?? 0,
    extraWorkerUsd: _money(json['extra_worker_usd']),
  );
}

class Invoice {
  const Invoice({
    required this.id,
    required this.number,
    required this.companyId,
    required this.companyName,
    required this.status,
    required this.months,
    required this.currency,
    required this.rate,
    required this.subtotalUsd,
    required this.discountPct,
    required this.totalUsd,
    required this.totalLocal,
    required this.issuedAt,
    required this.dueAt,
    this.note,
    this.paidAt,
    this.paymentRef,
    this.lines = const [],
  });

  final String id;
  final String number;
  final String companyId;
  final String companyName;
  final InvoiceStatus status;
  final int months;
  final String currency;
  final double rate;
  final double subtotalUsd;
  final double discountPct;
  final double totalUsd;
  final double totalLocal;
  final String? note;
  final DateTime issuedAt;
  final DateTime dueAt;
  final DateTime? paidAt;
  final String? paymentRef;
  final List<InvoiceLine> lines;

  bool isOverdue(DateTime now) =>
      status == InvoiceStatus.issued && dueAt.isBefore(now);

  factory Invoice.fromJson(Json json) => Invoice(
    id: json['id'] as String,
    number: _text(json['number']),
    companyId: json['company_id'] as String,
    companyName: _text(json['company_name']),
    status: InvoiceStatus.parse(json['status']),
    months: (json['months'] as num).toInt(),
    currency: _text(json['currency']),
    rate: _money(json['rate']),
    subtotalUsd: _money(json['subtotal_usd']),
    discountPct: _money(json['discount_pct']),
    totalUsd: _money(json['total_usd']),
    totalLocal: _money(json['total_local']),
    note: json['note'] as String?,
    issuedAt: DateTime.parse(json['issued_at'] as String),
    dueAt: DateTime.parse(json['due_at'] as String),
    paidAt: _timeOrNull(json['paid_at']),
    paymentRef: json['payment_ref'] as String?,
    lines: [for (final l in _list(json['lines'])) InvoiceLine.fromJson(l)],
  );
}

/// How to pay, as the platform admins wrote it.
class PaymentInfo {
  const PaymentInfo({this.instructions = '', this.phone = '', this.email = ''});

  final String instructions;
  final String phone;
  final String email;

  bool get isEmpty => instructions.isEmpty && phone.isEmpty && email.isEmpty;

  factory PaymentInfo.fromJson(Json json) => PaymentInfo(
    instructions: _text(json['instructions']),
    phone: _text(json['phone']),
    email: _text(json['email']),
  );
}

/// What the subscription screen shows for one company.
class BillingOverview {
  const BillingOverview({
    required this.company,
    this.plans = const [],
    this.workspaces = const [],
    this.invoices = const [],
    this.payment = const PaymentInfo(),
  });

  final BillingCompany company;
  final List<PlanOption> plans;
  final List<WorkspaceBilling> workspaces;

  /// Newest first; voided ones are left out.
  final List<Invoice> invoices;
  final PaymentInfo payment;

  PlanOption? plan(String id) => plans.where((p) => p.id == id).firstOrNull;

  factory BillingOverview.fromJson(Json json) => BillingOverview(
    company: BillingCompany.fromJson(Json.from(json['company'] as Map)),
    plans: [for (final p in _list(json['plans'])) PlanOption.fromJson(p)],
    workspaces: [
      for (final w in _list(json['workspaces'])) WorkspaceBilling.fromJson(w),
    ],
    invoices: [for (final i in _list(json['invoices'])) Invoice.fromJson(i)],
    payment: json['payment'] == null
        ? const PaymentInfo()
        : PaymentInfo.fromJson(Json.from(json['payment'] as Map)),
  );
}

/// One workspace on a new invoice, and an agreed price when it has one.
class InvoiceItem {
  const InvoiceItem({
    required this.workspaceId,
    required this.planId,
    this.priceUsd,
  });

  final String workspaceId;
  final String planId;
  final double? priceUsd;

  Json toJson() => {
    'workspace_id': workspaceId,
    'plan_id': planId,
    'price_usd': ?priceUsd,
  };
}

// Platform admin views.

class AdminOverview {
  const AdminOverview({
    this.companies = 0,
    this.workspaces = 0,
    this.paidWorkspaces = 0,
    this.members = 0,
    this.pendingRequests = 0,
    this.unpaidInvoices = 0,
    this.unpaidUsd = 0,
    this.paidUsd30d = 0,
  });

  final int companies;
  final int workspaces;
  final int paidWorkspaces;
  final int members;
  final int pendingRequests;
  final int unpaidInvoices;
  final double unpaidUsd;
  final double paidUsd30d;

  factory AdminOverview.fromJson(Json json) => AdminOverview(
    companies: _intOrNull(json['companies']) ?? 0,
    workspaces: _intOrNull(json['workspaces']) ?? 0,
    paidWorkspaces: _intOrNull(json['paid_workspaces']) ?? 0,
    members: _intOrNull(json['members']) ?? 0,
    pendingRequests: _intOrNull(json['pending_requests']) ?? 0,
    unpaidInvoices: _intOrNull(json['unpaid_invoices']) ?? 0,
    unpaidUsd: _money(json['unpaid_usd']),
    paidUsd30d: _money(json['paid_usd_30d']),
  );
}

class AdminWorkspace {
  const AdminWorkspace({
    required this.id,
    required this.name,
    required this.planId,
    required this.planName,
    required this.members,
    this.paidUntil,
  });

  final String id;
  final String name;
  final String planId;
  final String planName;
  final int members;
  final DateTime? paidUntil;

  factory AdminWorkspace.fromJson(Json json) => AdminWorkspace(
    id: json['id'] as String,
    name: _text(json['name']),
    planId: json['plan_id'] as String,
    planName: _text(json['plan_name']),
    members: (json['members'] as num?)?.toInt() ?? 0,
    paidUntil: _timeOrNull(json['paid_until']),
  );
}

class AdminCompany {
  const AdminCompany({
    required this.id,
    required this.name,
    required this.countryCode,
    required this.ownerName,
    required this.ownerEmail,
    required this.createdAt,
    this.workspaces = const [],
    this.pendingRequests = 0,
    this.unpaidInvoices = 0,
  });

  final String id;
  final String name;
  final String countryCode;
  final String ownerName;
  final String ownerEmail;
  final DateTime createdAt;
  final List<AdminWorkspace> workspaces;
  final int pendingRequests;
  final int unpaidInvoices;

  factory AdminCompany.fromJson(Json json) => AdminCompany(
    id: json['id'] as String,
    name: _text(json['name']),
    countryCode: _text(json['country_code']),
    ownerName: _text(json['owner_name']),
    ownerEmail: _text(json['owner_email']),
    createdAt: DateTime.parse(json['created_at'] as String),
    workspaces: [
      for (final w in _list(json['workspaces'])) AdminWorkspace.fromJson(w),
    ],
    pendingRequests: _intOrNull(json['pending_requests']) ?? 0,
    unpaidInvoices: _intOrNull(json['unpaid_invoices']) ?? 0,
  );
}

class AdminRequest {
  const AdminRequest({
    required this.id,
    required this.companyId,
    required this.companyName,
    required this.workspaceId,
    required this.workspaceName,
    required this.currentPlan,
    required this.planId,
    required this.planName,
    required this.months,
    required this.requestedByName,
    required this.createdAt,
    this.note,
  });

  final String id;
  final String companyId;
  final String companyName;
  final String workspaceId;
  final String workspaceName;

  /// The name of the plan the workspace is on now.
  final String currentPlan;
  final String planId;
  final String planName;
  final int months;
  final String? note;
  final String requestedByName;
  final DateTime createdAt;

  factory AdminRequest.fromJson(Json json) => AdminRequest(
    id: json['id'] as String,
    companyId: json['company_id'] as String,
    companyName: _text(json['company_name']),
    workspaceId: json['workspace_id'] as String,
    workspaceName: _text(json['workspace_name']),
    currentPlan: _text(json['current_plan']),
    planId: json['plan_id'] as String,
    planName: _text(json['plan_name']),
    months: (json['months'] as num).toInt(),
    note: json['note'] as String?,
    requestedByName: _text(json['requested_by_name']),
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

/// A country's currency and its rate now, if one was set.
class CountryRate {
  const CountryRate({
    required this.countryCode,
    required this.currency,
    this.rate,
    this.effectiveFrom,
    this.setByName,
  });

  final String countryCode;
  final String currency;
  final double? rate;
  final DateTime? effectiveFrom;
  final String? setByName;

  factory CountryRate.fromJson(Json json) => CountryRate(
    countryCode: _text(json['country_code']),
    currency: _text(json['currency']),
    rate: json['rate'] == null ? null : _money(json['rate']),
    effectiveFrom: _timeOrNull(json['effective_from']),
    setByName: json['set_by_name'] as String?,
  );
}
