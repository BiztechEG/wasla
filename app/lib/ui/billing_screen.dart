import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/billing_models.dart';
import '../state/billing_providers.dart';
import '../state/providers.dart';
import 'admin_billing.dart';
import 'billing_format.dart';
import 'chat_format.dart';
import 'widgets.dart';

/// Opens the subscription page of the company [workspaceId] belongs to, for
/// a billing notification. Nothing opens for a workspace one has left.
void openBilling(BuildContext context, WidgetRef ref, String workspaceId) {
  final memberships = ref.read(membershipsProvider).value ?? const [];
  final m = memberships.where((m) => m.workspaceId == workspaceId).firstOrNull;
  if (m == null || !m.isCompanyOwner) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BillingScreen(companyId: m.companyId),
    ),
  );
}

/// A company's plans, invoices and how to pay. Its owner asks for plans
/// here; a platform admin sees the same page with invoicing tools.
class BillingScreen extends ConsumerWidget {
  const BillingScreen({
    super.key,
    required this.companyId,
    this.admin = false,
    this.subtitle,
  });

  final String companyId;

  /// Opened from the platform admin pages.
  final bool admin;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final value = ref.watch(billingProvider(companyId));
    final b = value.value;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(admin ? (b?.company.name ?? '') : l.subscriptionTitle),
            if ((admin ? subtitle : b?.company.name) case final line?)
              Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: admin && b != null && b.workspaces.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => InvoiceComposer(billing: b),
                ),
              ),
              icon: const Icon(Icons.receipt_long_outlined),
              label: Text(l.newInvoice),
            )
          : null,
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(billingProvider(companyId)),
        builder: (b) {
          final unpaid = b.invoices
              .where((i) => i.status == InvoiceStatus.issued)
              .toList();
          return RefreshIndicator(
            onRefresh: () => ref.refresh(billingProvider(companyId).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                PageWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!admin && unpaid.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _UnpaidBanner(invoices: unpaid),
                      ],
                      SectionTitle(l.workspacesSection),
                      for (final w in b.workspaces)
                        _WorkspaceCard(billing: b, workspace: w, admin: admin),
                      SectionTitle(l.invoicesSection),
                      if (b.invoices.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            l.noInvoices,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      else
                        TileGroup(
                          children: [
                            for (final i in b.invoices)
                              InvoiceTile(
                                invoice: i,
                                onTap: () => openInvoice(
                                  context,
                                  i,
                                  payment: b.payment,
                                  admin: admin,
                                ),
                              ),
                          ],
                        ),
                      if (!admin && !b.payment.isEmpty) ...[
                        SectionTitle(l.howToPay),
                        PaymentCard(payment: b.payment),
                      ],
                      if (!admin) ...[
                        const SizedBox(height: 16),
                        Text(
                          l.billingFootnote,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _UnpaidBanner extends StatelessWidget {
  const _UnpaidBanner({required this.invoices});

  final List<Invoice> invoices;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final late = invoices.any((i) => i.isOverdue(DateTime.now()));
    final color = late ? scheme.error : scheme.tertiary;
    final first = invoices.first;
    return Card(
      color: color.withValues(alpha: 0.10),
      child: ListTile(
        leading: Icon(Icons.receipt_long_outlined, color: color),
        title: Text(
          l.unpaidInvoices(invoices.length),
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${first.number} · ${money(context, first.totalLocal, first.currency)}',
        ),
      ),
    );
  }
}

class _WorkspaceCard extends ConsumerWidget {
  const _WorkspaceCard({
    required this.billing,
    required this.workspace,
    required this.admin,
  });

  final BillingOverview billing;
  final WorkspaceBilling workspace;
  final bool admin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final w = workspace;
    final now = DateTime.now();
    const gb = 1024 * 1024 * 1024;

    final (String status, Color? statusColor) = switch (w.paidUntil) {
      _ when w.isFree => (l.onFreePlan, null),
      null => (l.planNoEnd, null),
      final until when until.isAfter(now) => (
        l.paidUntil(dateText(context, until)),
        until.difference(now) <= WorkspaceBilling.grace ? scheme.error : null,
      ),
      final until => (
        l.planEnded(
          dateText(context, until),
          dateText(context, until.add(WorkspaceBilling.grace)),
        ),
        scheme.error,
      ),
    };

    final request = w.request;
    final requestedPlan = request == null
        ? null
        : planLabel(l, billing.plan(request.planId)?.name ?? request.planId);
    final storageUsed = w.storageBytes >= gb
        ? l.sizeGb((w.storageBytes / gb).toStringAsFixed(1))
        : fileSize(l, w.storageBytes);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Avatar(name: w.name, radius: 18),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    w.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Tag(planLabel(l, w.planName), strong: !w.isFree),
              ],
            ),
            const SizedBox(height: 14),
            UsageBar(
              label: w.maxMembers == null
                  ? l.membersUsedUnlimited(w.members)
                  : l.membersUsed(w.members, w.maxMembers!),
              used: w.members.toDouble(),
              limit: w.maxMembers?.toDouble(),
            ),
            const SizedBox(height: 10),
            UsageBar(
              label: w.storageGb == null
                  ? l.storageUsedUnlimited(storageUsed)
                  : l.storageUsed(storageUsed, l.sizeGb('${w.storageGb}')),
              used: w.storageBytes.toDouble(),
              limit: w.storageGb == null ? null : w.storageGb! * gb.toDouble(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  statusColor == null
                      ? Icons.event_available_outlined
                      : Icons.error_outline,
                  size: 18,
                  color: statusColor ?? scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: statusColor ?? scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (request != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  request.status == RequestStatus.invoiced
                      ? l.requestInvoiced(requestedPlan!)
                      : l.requestPending(
                          requestedPlan!,
                          l.monthsCount(request.months),
                        ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (admin)
                  OutlinedButton.icon(
                    onPressed: () => setPlanByHand(context, ref, billing, w),
                    icon: const Icon(Icons.tune, size: 18),
                    label: Text(l.setPlanByHand),
                  )
                else ...[
                  FilledButton.tonal(
                    onPressed: () => showPlanSheet(context, ref, billing, w),
                    child: Text(
                      request?.status == RequestStatus.pending
                          ? l.changeRequest
                          : w.isFree
                          ? l.upgradePlan
                          : l.renewOrChange,
                    ),
                  ),
                  if (request?.status == RequestStatus.pending)
                    TextButton(
                      onPressed: () async {
                        final yes = await confirm(
                          context,
                          message: l.cancelRequestConfirm,
                          action: l.cancelRequest,
                          destructive: true,
                        );
                        if (!yes || !context.mounted) return;
                        final ok = await runAction(
                          context,
                          () => ref
                              .read(apiProvider)
                              .cancelPlanRequest(request!.id),
                        );
                        if (ok && context.mounted) refreshBilling(ref);
                      },
                      child: Text(l.cancelRequest),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Lets a company owner ask for a plan for one workspace.
Future<void> showPlanSheet(
  BuildContext context,
  WidgetRef ref,
  BillingOverview billing,
  WorkspaceBilling workspace,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _PlanSheet(billing: billing, workspace: workspace),
);

class _PlanSheet extends ConsumerStatefulWidget {
  const _PlanSheet({required this.billing, required this.workspace});

  final BillingOverview billing;
  final WorkspaceBilling workspace;

  @override
  ConsumerState<_PlanSheet> createState() => _PlanSheetState();
}

class _PlanSheetState extends ConsumerState<_PlanSheet> {
  static const _months = [1, 3, 6, 12];

  final _note = TextEditingController();
  late String? _plan = _initialPlan();
  late int _monthsPicked = widget.workspace.request?.months ?? 1;

  List<PlanOption> get _plans =>
      widget.billing.plans.where((p) => !p.isFree && p.offered).toList();

  bool _fits(PlanOption p) =>
      p.maxMembers == null || p.maxMembers! >= widget.workspace.members;

  String? _initialPlan() {
    final w = widget.workspace;
    for (final id in [w.request?.planId, w.planId]) {
      final match = _plans.where((p) => p.id == id && _fits(p)).firstOrNull;
      if (match != null) return match.id;
    }
    return _plans.where(_fits).firstOrNull?.id;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final l = context.l10n;
    final navigator = Navigator.of(context);
    final note = _note.text.trim();
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .requestPlan(
            widget.workspace.id,
            _plan!,
            months: _monthsPicked,
            note: note.isEmpty ? null : note,
          ),
      done: l.planRequestSent,
    );
    if (!ok || !mounted) return;
    refreshBilling(ref);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currency = widget.billing.company.currency;
    final chosen = _plans.where((p) => p.id == _plan).firstOrNull;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: PageWidth(
          max: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.choosePlanFor(widget.workspace.name),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              if (_plans.isEmpty) Text(l.noPlansOffered),
              for (final p in _plans)
                _PlanChoice(
                  plan: p,
                  currency: currency,
                  selected: p.id == _plan,
                  tooSmall: !_fits(p),
                  members: widget.workspace.members,
                  onTap: () => setState(() => _plan = p.id),
                ),
              const SizedBox(height: 8),
              Text(l.forHowLong, style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in _months)
                    ChoiceChip(
                      label: Text(l.monthsCount(m)),
                      selected: _monthsPicked == m,
                      onSelected: (_) => setState(() => _monthsPicked = m),
                    ),
                ],
              ),
              if (chosen != null && chosen.priceUsd > 0) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.estimatedTotal,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      money(
                        context,
                        chosen.priceLocal * _monthsPicked,
                        currency,
                      ),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _note,
                maxLines: 3,
                minLines: 1,
                inputFormatters: messageLimit,
                decoration: InputDecoration(labelText: l.requestNote),
              ),
              const SizedBox(height: 12),
              Text(
                l.requestHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              BusyButton(
                label: l.sendRequest,
                onPressed: _plan == null ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanChoice extends StatelessWidget {
  const _PlanChoice({
    required this.plan,
    required this.currency,
    required this.selected,
    required this.tooSmall,
    required this.members,
    required this.onTap,
  });

  final PlanOption plan;
  final String currency;
  final bool selected;
  final bool tooSmall;
  final int members;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        enabled: !tooSmall,
        onTap: onTap,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? scheme.primary : null,
        ),
        title: Text(
          planLabel(l, plan.name),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          tooSmall ? l.planTooSmall(members) : planLimits(l, plan),
          style: tooSmall ? TextStyle(color: scheme.error) : null,
        ),
        trailing: plan.priceUsd > 0
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    money(context, plan.priceLocal, currency),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(l.perMonth, style: theme.textTheme.bodySmall),
                ],
              )
            : Text(l.priceOnInvoice, style: theme.textTheme.bodySmall),
      ),
    );
  }
}

class InvoiceTile extends StatelessWidget {
  const InvoiceTile({
    super.key,
    required this.invoice,
    required this.onTap,
    this.showCompany = false,
  });

  final Invoice invoice;
  final VoidCallback onTap;
  final bool showCompany;

  @override
  Widget build(BuildContext context) {
    final i = invoice;
    return ListTile(
      onTap: onTap,
      leading: const Icon(Icons.receipt_long_outlined),
      title: Text(
        showCompany ? '${i.companyName} · ${i.number}' : i.number,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(dateText(context, i.issuedAt)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            money(context, i.totalLocal, i.currency),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          InvoiceStatusTag(i),
        ],
      ),
    );
  }
}

void openInvoice(
  BuildContext context,
  Invoice invoice, {
  PaymentInfo? payment,
  bool admin = false,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        InvoiceScreen(invoice: invoice, payment: payment, admin: admin),
  ),
);

class InvoiceScreen extends ConsumerWidget {
  const InvoiceScreen({
    super.key,
    required this.invoice,
    this.payment,
    this.admin = false,
  });

  final Invoice invoice;
  final PaymentInfo? payment;
  final bool admin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final i = invoice;
    final local = i.currency != 'USD';
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: AppBar(title: Text(i.number)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          PageWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                i.companyName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            InvoiceStatusTag(i),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _Row(l.issuedOn, dateText(context, i.issuedAt)),
                        if (i.status == InvoiceStatus.issued)
                          _Row(
                            l.dueOn,
                            dateText(context, i.dueAt),
                            color: i.isOverdue(DateTime.now())
                                ? scheme.error
                                : null,
                          ),
                        if (i.paidAt != null)
                          _Row(l.paidOn, dateText(context, i.paidAt!)),
                        if (i.paymentRef != null)
                          _Row(l.paymentReference, i.paymentRef!),
                        _Row(l.invoicePeriod, l.monthsCount(i.months)),
                      ],
                    ),
                  ),
                ),
                SectionTitle(l.invoiceLines),
                TileGroup(
                  children: [
                    for (final line in i.lines)
                      ListTile(
                        title: Text(line.workspaceName),
                        subtitle: Text(
                          [
                            planLabel(l, line.planName),
                            l.lineUnit(usd(context, line.unitUsd)),
                            l.memberCount(line.members),
                          ].join(' · '),
                        ),
                        trailing: Text(
                          money(context, line.amountLocal, i.currency),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Row(l.subtotal, usd(context, i.subtotalUsd)),
                        if (i.discountPct > 0)
                          _Row(
                            l.discount,
                            '${i.discountPct.toStringAsFixed(i.discountPct == i.discountPct.roundToDouble() ? 0 : 2)}%',
                          ),
                        _Row(l.totalUsd, usd(context, i.totalUsd)),
                        if (local)
                          _Row(
                            l.exchangeRate,
                            l.rateLine(money(context, i.rate, i.currency)),
                          ),
                        const Divider(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l.amountDue,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            Text(
                              money(context, i.totalLocal, i.currency),
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (i.note != null) ...[
                  const SizedBox(height: 12),
                  Text(i.note!, style: muted),
                ],
                if (!admin &&
                    i.status == InvoiceStatus.issued &&
                    payment != null &&
                    !payment!.isEmpty) ...[
                  SectionTitle(l.howToPay),
                  PaymentCard(payment: payment!),
                ],
                if (admin && i.status == InvoiceStatus.issued) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => markInvoicePaid(context, ref, i),
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(l.markPaid),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                    ),
                    onPressed: () => voidInvoice(context, ref, i),
                    child: Text(l.voidInvoice),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How to pay, with the phone and email ready to tap.
class PaymentCard extends StatelessWidget {
  const PaymentCard({super.key, required this.payment});

  final PaymentInfo payment;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (payment.instructions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: SelectableText(payment.instructions),
            ),
          if (payment.phone.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: LtrLine(payment.phone),
              onTap: () => openLink(
                context,
                'tel:${payment.phone.replaceAll(RegExp(r'[^0-9+]'), '')}',
              ),
            ),
          if (payment.email.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.mail_outline),
              title: LtrLine(payment.email),
              onTap: () => openLink(context, 'mailto:${payment.email}'),
            ),
        ],
      ),
    );
  }
}
