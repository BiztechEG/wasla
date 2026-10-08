import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/billing_models.dart';
import '../state/billing_providers.dart';
import '../state/providers.dart';
import 'admin_billing.dart';
import 'billing_format.dart';
import 'billing_screen.dart';
import 'chat_format.dart';
import 'create_workspace_screen.dart';
import 'widgets.dart';

/// The platform admin dashboard: figures and plan requests, companies,
/// invoices, and prices. On the web it is a platform admin's first page.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key, this.app});

  /// When given, the page is the first one and leads to the app.
  final Widget? app;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.adminTitle),
          actions: [
            if (app != null)
              TextButton.icon(
                onPressed: () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => app!)),
                icon: const Icon(Icons.apps),
                label: Text(l.openApp),
              ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: l.adminOverviewTab),
              Tab(text: l.adminCompaniesTab),
              Tab(text: l.adminInvoicesTab),
              Tab(text: l.adminPricesTab),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _OverviewTab(),
            _CompaniesTab(),
            _InvoicesTab(),
            _PricesTab(),
          ],
        ),
      ),
    );
  }
}

void _openCompany(BuildContext context, String companyId, {String? subtitle}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BillingScreen(
          companyId: companyId,
          admin: true,
          subtitle: subtitle,
        ),
      ),
    );

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final overview = ref.watch(adminOverviewProvider);
    final requests = ref.watch(adminRequestsProvider);

    Future<void> refresh() async {
      ref.invalidate(adminOverviewProvider);
      ref.invalidate(adminRequestsProvider);
      await ref.read(adminRequestsProvider.future);
    }

    return AsyncView(
      value: overview,
      onRetry: refresh,
      builder: (o) => RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            PageWidth(
              max: 960,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatGrid(
                    children: [
                      _Stat(l.statCompanies, '${o.companies}'),
                      _Stat(l.statWorkspaces, '${o.workspaces}'),
                      _Stat(l.statPaidWorkspaces, '${o.paidWorkspaces}'),
                      _Stat(l.statMembers, '${o.members}'),
                      _Stat(
                        l.statUnpaid(o.unpaidInvoices),
                        usd(context, o.unpaidUsd),
                        warn: o.unpaidInvoices > 0,
                      ),
                      _Stat(l.statPaid30d, usd(context, o.paidUsd30d)),
                    ],
                  ),
                  SectionTitle(
                    l.planRequests,
                    trailing: o.pendingRequests > 0
                        ? Badge(label: Text('${o.pendingRequests}'))
                        : null,
                  ),
                  ...switch (requests) {
                    AsyncData(value: final list) when list.isEmpty => [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          l.noPlanRequests,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    AsyncData(value: final list) => [
                      TileGroup(
                        children: [for (final r in list) _RequestTile(r)],
                      ),
                    ],
                    AsyncError(:final error) => [
                      ErrorView(
                        error: error,
                        onRetry: () => ref.invalidate(adminRequestsProvider),
                      ),
                    ],
                    _ => [
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ],
                  },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two figures a row on a phone, three on a tablet, six on a wide screen.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 12.0;
      final columns = box.maxWidth >= 900
          ? 6
          : box.maxWidth >= 520
          ? 3
          : 2;
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: warn ? theme.colorScheme.error : null,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile(this.request);

  final AdminRequest request;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final r = request;
    return ListTile(
      onTap: () => _openCompany(context, r.companyId),
      leading: const Icon(Icons.request_quote_outlined),
      title: Text('${r.companyName} · ${r.workspaceName}'),
      subtitle: Text(
        [
          l.requestChange(
            planLabel(l, r.currentPlan),
            planLabel(l, r.planName),
            l.monthsCount(r.months),
          ),
          if (r.note != null) r.note!,
          '${r.requestedByName} · ${listTime(context, r.createdAt)}',
        ].join('\n'),
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _CompaniesTab extends ConsumerStatefulWidget {
  const _CompaniesTab();

  @override
  ConsumerState<_CompaniesTab> createState() => _CompaniesTabState();
}

class _CompaniesTabState extends ConsumerState<_CompaniesTab> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final companies = ref.watch(adminCompaniesProvider(_query));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: PageWidth(
            max: 960,
            child: TextField(
              controller: _search,
              onChanged: _changed,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l.searchCompanies,
              ),
            ),
          ),
        ),
        Expanded(
          child: AsyncView(
            value: companies,
            onRetry: () => ref.invalidate(adminCompaniesProvider(_query)),
            builder: (list) => list.isEmpty
                ? EmptyState(
                    icon: Icons.business_outlined,
                    title: l.noCompanies,
                  )
                : RefreshIndicator(
                    onRefresh: () =>
                        ref.refresh(adminCompaniesProvider(_query).future),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: [
                        PageWidth(
                          max: 960,
                          child: TileGroup(
                            children: [for (final c in list) _CompanyTile(c)],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _CompanyTile extends StatelessWidget {
  const _CompanyTile(this.company);

  final AdminCompany company;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final c = company;
    final owner = '${c.ownerName} · ${ltr(c.ownerEmail)}';
    return ListTile(
      onTap: () => _openCompany(context, c.id, subtitle: owner),
      leading: Avatar(name: c.name),
      title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(owner, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            [
              countryName(l, c.countryCode),
              for (final w in c.workspaces)
                '${w.name} (${planLabel(l, w.planName)})',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.pendingRequests > 0)
            Tooltip(
              message: l.planRequests,
              child: Badge(
                label: Text('${c.pendingRequests}'),
                child: const Icon(Icons.request_quote_outlined),
              ),
            ),
          if (c.unpaidInvoices > 0) ...[
            const SizedBox(width: 12),
            Tooltip(
              message: l.statUnpaid(c.unpaidInvoices),
              child: Badge(
                label: Text('${c.unpaidInvoices}'),
                backgroundColor: theme.colorScheme.tertiary,
                child: const Icon(Icons.receipt_long_outlined),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _InvoiceFilter {
  all(null),
  issued(InvoiceStatus.issued),
  paid(InvoiceStatus.paid),
  voided(InvoiceStatus.void_);

  const _InvoiceFilter(this.status);

  final InvoiceStatus? status;
}

class _InvoicesTab extends ConsumerStatefulWidget {
  const _InvoicesTab();

  @override
  ConsumerState<_InvoicesTab> createState() => _InvoicesTabState();
}

class _InvoicesTabState extends ConsumerState<_InvoicesTab> {
  _InvoiceFilter _filter = _InvoiceFilter.issued;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final invoices = ref.watch(adminInvoicesProvider(_filter.status));
    String label(_InvoiceFilter f) => switch (f) {
      _InvoiceFilter.all => l.filterAll,
      _InvoiceFilter.issued => l.invoiceDue,
      _InvoiceFilter.paid => l.invoicePaid,
      _InvoiceFilter.voided => l.invoiceVoid,
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: PageWidth(
            max: 960,
            child: Wrap(
              spacing: 8,
              children: [
                for (final f in _InvoiceFilter.values)
                  ChoiceChip(
                    label: Text(label(f)),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: AsyncView(
            value: invoices,
            onRetry: () =>
                ref.invalidate(adminInvoicesProvider(_filter.status)),
            builder: (list) => list.isEmpty
                ? EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: l.noInvoices,
                  )
                : RefreshIndicator(
                    onRefresh: () => ref.refresh(
                      adminInvoicesProvider(_filter.status).future,
                    ),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      children: [
                        PageWidth(
                          max: 960,
                          child: TileGroup(
                            children: [
                              for (final i in list)
                                InvoiceTile(
                                  invoice: i,
                                  showCompany: true,
                                  onTap: () =>
                                      openInvoice(context, i, admin: true),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _PricesTab extends ConsumerWidget {
  const _PricesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final plans = ref.watch(adminPlansProvider);
    final rates = ref.watch(adminRatesProvider);
    final payment = ref.watch(adminPaymentInfoProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    Future<void> refresh() async {
      ref.invalidate(adminPlansProvider);
      ref.invalidate(adminRatesProvider);
      ref.invalidate(adminPaymentInfoProvider);
      await ref.read(adminPlansProvider.future);
    }

    Widget section<T>(AsyncValue<T> value, Widget Function(T) builder) =>
        switch (value) {
          AsyncData(:final value) => builder(value),
          AsyncError(:final error) => ErrorView(error: error, onRetry: refresh),
          _ => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        };

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          PageWidth(
            max: 960,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionTitle(l.plansSection),
                Text(l.plansHint, style: muted),
                const SizedBox(height: 8),
                section(
                  plans,
                  (list) => TileGroup(
                    children: [
                      for (final p in list)
                        ListTile(
                          onTap: () => _editPlan(context, ref, p),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  planLabel(l, p.name),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (!p.offered) ...[
                                const SizedBox(width: 8),
                                Tag(l.notOffered),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            '${planLimits(l, p)} · ${l.workspaceCount(p.workspaces)}',
                          ),
                          trailing: Text(
                            p.isFree
                                ? l.freePrice
                                : p.priceUsd > 0
                                ? '${usd(context, p.priceUsd)} ${l.perMonth}'
                                : l.noPriceYet,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: !p.isFree && p.priceUsd <= 0
                                  ? theme.colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SectionTitle(l.ratesSection),
                Text(l.ratesHint, style: muted),
                const SizedBox(height: 8),
                section(
                  rates,
                  (list) => TileGroup(
                    children: [
                      for (final r in list)
                        ListTile(
                          onTap: () => _setRate(context, ref, r),
                          title: Text(countryName(l, r.countryCode)),
                          subtitle: Text(
                            r.rate == null
                                ? l.noRateYet
                                : l.rateSince(
                                    dateText(context, r.effectiveFrom!),
                                    r.setByName ?? '',
                                  ),
                          ),
                          trailing: Text(
                            r.rate == null
                                ? r.currency
                                : l.rateLine(
                                    money(context, r.rate!, r.currency),
                                  ),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: r.rate == null
                                  ? theme.colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SectionTitle(
                  l.paymentSection,
                  trailing: payment.hasValue
                      ? TextButton(
                          onPressed: () =>
                              _editPayment(context, ref, payment.value!),
                          child: Text(l.edit),
                        )
                      : null,
                ),
                section(
                  payment,
                  (info) => info.isEmpty
                      ? Card(
                          child: ListTile(
                            leading: const Icon(Icons.info_outline),
                            title: Text(l.paymentNotSet),
                            onTap: () => _editPayment(context, ref, info),
                          ),
                        )
                      : PaymentCard(payment: info),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editPlan(
    BuildContext context,
    WidgetRef ref,
    PlanOption plan,
  ) async {
    final l = context.l10n;
    final answer = await askFields(
      context,
      title: l.editPlanTitle(planLabel(l, plan.name)),
      fields: [
        FieldSpec(l.planNameEn, initial: plan.name, maxLength: 50),
        FieldSpec(
          l.maxMembersLabel,
          initial: plan.maxMembers?.toString() ?? '',
          number: true,
          optional: true,
          hint: l.emptyIsUnlimited,
        ),
        FieldSpec(
          l.storageGbLabel,
          initial: plan.storageGb?.toString() ?? '',
          number: true,
          optional: true,
          hint: l.emptyIsUnlimited,
        ),
        if (!plan.isFree)
          FieldSpec(
            l.monthlyPriceUsd,
            initial: plan.priceUsd > 0 ? plan.priceUsd.toString() : '',
            number: true,
          ),
      ],
      toggle: plan.isFree ? null : l.offeredToggle,
      toggleInitial: plan.offered,
    );
    if (answer == null || !context.mounted) return;
    final v = answer.values;
    int? whole(String s) => s.isEmpty ? null : double.parse(s).round();
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .adminUpdatePlan(
            PlanOption(
              id: plan.id,
              name: v[0],
              maxMembers: whole(v[1]),
              storageGb: whole(v[2]),
              priceUsd: plan.isFree ? 0 : double.parse(v[3]),
              priceLocal: 0,
              offered: plan.isFree ? plan.offered : answer.toggle,
            ),
          ),
      done: l.saved,
    );
    if (ok) refreshBilling(ref);
  }

  Future<void> _setRate(
    BuildContext context,
    WidgetRef ref,
    CountryRate rate,
  ) async {
    final l = context.l10n;
    final answer = await askFields(
      context,
      title: l.setRateTitle(countryName(l, rate.countryCode)),
      fields: [
        FieldSpec(
          l.rateLabel(currencyLabel(context, rate.currency)),
          initial: rate.rate?.toString() ?? '',
          number: true,
          hint: l.rateHint,
        ),
      ],
    );
    if (answer == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .adminSetRate(rate.countryCode, double.parse(answer.values.first)),
      done: l.saved,
    );
    if (ok) refreshBilling(ref);
  }

  Future<void> _editPayment(
    BuildContext context,
    WidgetRef ref,
    PaymentInfo info,
  ) async {
    final l = context.l10n;
    final answer = await askFields(
      context,
      title: l.paymentSection,
      fields: [
        FieldSpec(
          l.paymentInstructions,
          initial: info.instructions,
          optional: true,
          maxLength: 2000,
          lines: 6,
          hint: l.paymentInstructionsHint,
        ),
        FieldSpec(
          l.supportPhone,
          initial: info.phone,
          optional: true,
          maxLength: 30,
          ltr: true,
        ),
        FieldSpec(
          l.supportEmail,
          initial: info.email,
          optional: true,
          maxLength: 254,
          ltr: true,
        ),
      ],
    );
    if (answer == null || !context.mounted) return;
    final v = answer.values;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .adminUpdatePaymentInfo(
            PaymentInfo(instructions: v[0], phone: v[1], email: v[2]),
          ),
      done: l.saved,
    );
    if (ok) refreshBilling(ref);
  }
}
