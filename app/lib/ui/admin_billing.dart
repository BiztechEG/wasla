import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/billing_models.dart';
import '../state/billing_providers.dart';
import '../state/providers.dart';
import 'billing_format.dart';
import 'widgets.dart';

// What platform admins do to a company's billing: invoices, payments and
// plans given by hand.

/// Reads a number typed with western or Arabic digits; null if it isn't one.
double? parseNumber(String text) {
  final western = text
      .trim()
      .replaceAllMapped(
        RegExp('[٠-٩]'),
        (m) => '${m[0]!.codeUnitAt(0) - 0x0660}',
      )
      .replaceAllMapped(
        RegExp('[۰-۹]'),
        (m) => '${m[0]!.codeUnitAt(0) - 0x06F0}',
      )
      .replaceAll('٫', '.')
      .replaceAll(RegExp('[,٬ ]'), '');
  return double.tryParse(western);
}

String _plain(double n) =>
    n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toString();

class FieldSpec {
  const FieldSpec(
    this.label, {
    this.initial = '',
    this.number = false,
    this.optional = false,
    this.maxLength = 100,
    this.lines = 1,
    this.ltr = false,
    this.hint,
  });

  final String label;
  final String initial;
  final bool number;
  final bool optional;
  final int maxLength;
  final int lines;

  /// For phone numbers and emails.
  final bool ltr;
  final String? hint;
}

typedef FieldsResult = ({List<String> values, bool toggle});

/// Asks for a few values at once; null when cancelled. Number fields come
/// back with western digits. [toggle] adds a switch under the fields.
Future<FieldsResult?> askFields(
  BuildContext context, {
  required String title,
  required List<FieldSpec> fields,
  String? action,
  String? toggle,
  bool toggleInitial = false,
}) => showDialog<FieldsResult>(
  context: context,
  builder: (_) => _FieldsDialog(
    title: title,
    fields: fields,
    action: action,
    toggle: toggle,
    toggleInitial: toggleInitial,
  ),
);

class _FieldsDialog extends StatefulWidget {
  const _FieldsDialog({
    required this.title,
    required this.fields,
    required this.action,
    required this.toggle,
    required this.toggleInitial,
  });

  final String title;
  final List<FieldSpec> fields;
  final String? action;
  final String? toggle;
  final bool toggleInitial;

  @override
  State<_FieldsDialog> createState() => _FieldsDialogState();
}

class _FieldsDialogState extends State<_FieldsDialog> {
  late final _controllers = [
    for (final f in widget.fields) TextEditingController(text: f.initial),
  ];
  late bool _toggle = widget.toggleInitial;
  final _errors = <int>{};

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = <String>[];
    _errors.clear();
    for (var i = 0; i < widget.fields.length; i++) {
      final f = widget.fields[i];
      final text = _controllers[i].text.trim();
      if (text.isEmpty) {
        if (!f.optional) _errors.add(i);
        values.add('');
        continue;
      }
      if (f.number) {
        final n = parseNumber(text);
        if (n == null || n < 0) {
          _errors.add(i);
          values.add('');
        } else {
          values.add(_plain(n));
        }
      } else {
        values.add(text);
      }
    }
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    Navigator.pop(context, (values: values, toggle: _toggle));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.fields.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: _controllers[i],
                    autofocus: i == 0,
                    minLines: 1,
                    maxLines: widget.fields[i].lines,
                    textDirection:
                        widget.fields[i].ltr || widget.fields[i].number
                        ? TextDirection.ltr
                        : null,
                    keyboardType: widget.fields[i].number
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : widget.fields[i].lines > 1
                        ? TextInputType.multiline
                        : null,
                    inputFormatters: [RuneLimit(widget.fields[i].maxLength)],
                    decoration: InputDecoration(
                      labelText: widget.fields[i].label,
                      helperText: widget.fields[i].hint,
                      helperMaxLines: 3,
                      errorText: _errors.contains(i)
                          ? (widget.fields[i].number
                                ? l.enterNumber
                                : l.requiredField)
                          : null,
                    ),
                  ),
                ),
              if (widget.toggle != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(widget.toggle!),
                  value: _toggle,
                  onChanged: (v) => setState(() => _toggle = v),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(widget.action ?? l.save)),
      ],
    );
  }
}

Future<void> markInvoicePaid(
  BuildContext context,
  WidgetRef ref,
  Invoice invoice,
) async {
  final l = context.l10n;
  final answer = await askFields(
    context,
    title: l.markPaidTitle(invoice.number),
    action: l.markPaid,
    fields: [
      FieldSpec(
        l.paymentReference,
        optional: true,
        maxLength: 200,
        hint: l.markPaidHint,
      ),
    ],
  );
  if (answer == null || !context.mounted) return;
  final navigator = Navigator.of(context);
  final ref0 = answer.values.first;
  final ok = await runAction(
    context,
    () => ref
        .read(apiProvider)
        .adminMarkInvoicePaid(
          invoice.id,
          reference: ref0.isEmpty ? null : ref0,
        ),
    done: l.invoiceMarkedPaid,
  );
  if (!ok) return;
  refreshBilling(ref);
  navigator.pop();
}

Future<void> voidInvoice(
  BuildContext context,
  WidgetRef ref,
  Invoice invoice,
) async {
  final l = context.l10n;
  final yes = await confirm(
    context,
    message: l.voidInvoiceConfirm(invoice.number),
    action: l.voidInvoice,
    destructive: true,
  );
  if (!yes || !context.mounted) return;
  final navigator = Navigator.of(context);
  final ok = await runAction(
    context,
    () => ref.read(apiProvider).adminVoidInvoice(invoice.id),
  );
  if (!ok) return;
  refreshBilling(ref);
  navigator.pop();
}

/// Puts a workspace on a plan without an invoice: a trial, the pilot
/// company, or an agreement paid outside the app.
Future<void> setPlanByHand(
  BuildContext context,
  WidgetRef ref,
  BillingOverview billing,
  WorkspaceBilling workspace,
) async {
  final l = context.l10n;
  final picked = await showDialog<({String plan, DateTime? until})>(
    context: context,
    builder: (_) => _SetPlanDialog(billing: billing, workspace: workspace),
  );
  if (picked == null || !context.mounted) return;
  final ok = await runAction(
    context,
    () => ref
        .read(apiProvider)
        .adminSetWorkspacePlan(workspace.id, picked.plan, until: picked.until),
    done: l.planSet,
  );
  if (ok) refreshBilling(ref);
}

class _SetPlanDialog extends StatefulWidget {
  const _SetPlanDialog({required this.billing, required this.workspace});

  final BillingOverview billing;
  final WorkspaceBilling workspace;

  @override
  State<_SetPlanDialog> createState() => _SetPlanDialogState();
}

class _SetPlanDialogState extends State<_SetPlanDialog> {
  late String _plan = widget.workspace.planId;
  late bool _noEnd = widget.workspace.paidUntil == null;
  late DateTime? _until =
      widget.workspace.paidUntil?.isAfter(DateTime.now()) ?? false
      ? widget.workspace.paidUntil!.toLocal()
      : null;

  bool get _free => _plan == 'free';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final date = await showDatePicker(
      context: context,
      initialDate: _until ?? DateTime(now.year, now.month + 1, now.day),
      firstDate: tomorrow,
      lastDate: DateTime(now.year + 5),
    );
    if (date != null) {
      setState(
        () => _until = DateTime(date.year, date.month, date.day, 23, 59),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final ready = _free || _noEnd || _until != null;
    return AlertDialog(
      title: Text(l.setPlanFor(widget.workspace.name)),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final p in widget.billing.plans)
                ListTile(
                  dense: true,
                  onTap: () => setState(() => _plan = p.id),
                  leading: Icon(
                    p.id == _plan ? LucideIcons.circleDot : LucideIcons.circle,
                    color: p.id == _plan ? scheme.primary : null,
                  ),
                  title: Text(planLabel(l, p.name)),
                  subtitle: Text(planLimits(l, p)),
                ),
              if (!_free) ...[
                const Divider(),
                SwitchListTile(
                  title: Text(l.noEndDate),
                  subtitle: Text(l.noEndDateHint),
                  value: _noEnd,
                  onChanged: (v) => setState(() => _noEnd = v),
                ),
                if (!_noEnd)
                  ListTile(
                    leading: const Icon(LucideIcons.calendar),
                    title: Text(
                      _until == null
                          ? l.pickEndDate
                          : dateText(context, _until!),
                    ),
                    subtitle: _until == null ? null : Text(l.planEndsOn),
                    onTap: _pickDate,
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: ready
              ? () => Navigator.pop(context, (
                  plan: _plan,
                  until: _free || _noEnd ? null : _until,
                ))
              : null,
          child: Text(l.save),
        ),
      ],
    );
  }
}

/// A new invoice for some of a company's workspaces. Workspaces with a plan
/// request start ticked with what was asked for.
class InvoiceComposer extends ConsumerStatefulWidget {
  const InvoiceComposer({super.key, required this.billing});

  final BillingOverview billing;

  @override
  ConsumerState<InvoiceComposer> createState() => _InvoiceComposerState();
}

class _Line {
  _Line({required this.on, required this.plan});

  bool on;
  String plan;
  final price = TextEditingController();
}

class _InvoiceComposerState extends ConsumerState<InvoiceComposer> {
  static const _monthChoices = [1, 3, 6, 12];

  late final List<PlanOption> _plans = widget.billing.plans
      .where((p) => !p.isFree)
      .toList();
  late final Map<String, _Line> _lines = {
    for (final w in widget.billing.workspaces)
      w.id: _Line(
        on: w.request?.status == RequestStatus.pending,
        plan: _startPlan(w),
      ),
  };
  late int _months =
      widget.billing.workspaces
          .map((w) => w.request)
          .whereType<PlanRequest>()
          .where((r) => r.status == RequestStatus.pending)
          .firstOrNull
          ?.months ??
      1;
  final _discount = TextEditingController();
  final _dueDays = TextEditingController(text: '14');
  final _note = TextEditingController();
  String? _error;

  /// Applies a change to the form; an earlier complaint no longer applies.
  void _edit([VoidCallback? change]) => setState(() {
    change?.call();
    _error = null;
  });

  String _startPlan(WorkspaceBilling w) {
    final candidates = [
      if (w.request?.status == RequestStatus.pending) w.request!.planId,
      w.planId,
    ];
    for (final id in candidates) {
      if (_plans.any((p) => p.id == id)) return id;
    }
    return _plans.first.id;
  }

  @override
  void dispose() {
    for (final line in _lines.values) {
      line.price.dispose();
    }
    _discount.dispose();
    _dueDays.dispose();
    _note.dispose();
    super.dispose();
  }

  PlanOption _plan(String id) => _plans.firstWhere((p) => p.id == id);

  /// The month price for a line: what was typed, else the plan's.
  double? _unit(_Line line) {
    final typed = line.price.text.trim();
    if (typed.isEmpty) return _plan(line.plan).priceUsd;
    return parseNumber(typed);
  }

  double get _discountPct => parseNumber(_discount.text) ?? 0;

  double get _subtotal {
    var sum = 0.0;
    for (final line in _lines.values.where((l) => l.on)) {
      sum += (_unit(line) ?? 0) * _months;
    }
    return sum;
  }

  double get _total =>
      (_subtotal * (1 - _discountPct.clamp(0, 100) / 100) * 100).round() / 100;

  Future<void> _issue() async {
    final l = context.l10n;
    final chosen = _lines.entries.where((e) => e.value.on).toList();
    String? error;
    if (chosen.isEmpty) {
      error = l.pickWorkspaces;
    } else if (chosen.any((e) => (_unit(e.value) ?? 0) <= 0)) {
      error = l.setPriceFirst;
    } else if (_discountPct < 0 || _discountPct > 100) {
      error = l.invalidDiscount;
    }
    final due = parseNumber(_dueDays.text)?.round();
    if (error == null && (due == null || due < 0 || due > 365)) {
      error = l.invalidDueDays;
    }
    setState(() => _error = error);
    if (error != null) return;

    final navigator = Navigator.of(context);
    final note = _note.text.trim();
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .adminCreateInvoice(
            widget.billing.company.id,
            [
              for (final e in chosen)
                InvoiceItem(
                  workspaceId: e.key,
                  planId: e.value.plan,
                  priceUsd: e.value.price.text.trim().isEmpty
                      ? null
                      : _unit(e.value),
                ),
            ],
            months: _months,
            discountPct: _discountPct,
            note: note.isEmpty ? null : note,
            dueDays: due!,
          ),
      done: l.invoiceIssued,
    );
    if (!ok) return;
    refreshBilling(ref);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final company = widget.billing.company;
    final local = company.currency != 'USD';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.newInvoice),
            Text(
              company.name,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          PageWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionTitle(l.invoiceWorkspaces),
                for (final w in widget.billing.workspaces)
                  _lineCard(context, w, _lines[w.id]!),
                SectionTitle(l.invoiceTerms),
                Text(l.forHowLong, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final m in _monthChoices)
                      ChoiceChip(
                        label: Text(l.monthsCount(m)),
                        selected: _months == m,
                        onSelected: (_) => _edit(() => _months = m),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _discount,
                        textDirection: TextDirection.ltr,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [LengthLimitingTextInputFormatter(6)],
                        decoration: InputDecoration(
                          labelText: l.discountPct,
                          hintText: '0',
                        ),
                        onChanged: (_) => _edit(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _dueDays,
                        textDirection: TextDirection.ltr,
                        keyboardType: TextInputType.number,
                        inputFormatters: [LengthLimitingTextInputFormatter(3)],
                        decoration: InputDecoration(labelText: l.dueInDays),
                        onChanged: (_) => _edit(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _note,
                  minLines: 1,
                  maxLines: 3,
                  inputFormatters: messageLimit,
                  decoration: InputDecoration(labelText: l.invoiceNote),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _total2(context, l.subtotal, usd(context, _subtotal)),
                        if (_discountPct > 0)
                          _total2(
                            context,
                            l.discount,
                            '${_plain(_discountPct)}%',
                          ),
                        _total2(context, l.totalUsd, usd(context, _total)),
                        if (local) ...[
                          _total2(
                            context,
                            l.exchangeRate,
                            l.rateLine(
                              money(context, company.rate, company.currency),
                            ),
                          ),
                          _total2(
                            context,
                            l.amountDue,
                            money(
                              context,
                              (_total * company.rate * 100).round() / 100,
                              company.currency,
                            ),
                            strong: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                BusyButton(label: l.issueInvoice, onPressed: _issue),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineCard(BuildContext context, WorkspaceBilling w, _Line line) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final request = w.request?.status == RequestStatus.pending
        ? w.request
        : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          CheckboxListTile(
            value: line.on,
            onChanged: (v) => _edit(() => line.on = v ?? false),
            title: Text(
              w.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              [
                l.memberCount(w.members),
                l.currentPlan(planLabel(l, w.planName)),
                if (request != null)
                  l.requestedPlan(
                    planLabel(
                      l,
                      widget.billing.plan(request.planId)?.name ??
                          request.planId,
                    ),
                    l.monthsCount(request.months),
                  ),
              ].join(' · '),
            ),
          ),
          if (line.on)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: line.plan,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: l.planLabel),
                      items: [
                        for (final p in _plans)
                          DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              planLabel(l, p.name),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => _edit(() => line.plan = v!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: line.price,
                      textDirection: TextDirection.ltr,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [LengthLimitingTextInputFormatter(9)],
                      decoration: InputDecoration(
                        labelText: l.specialPrice,
                        hintText: _plain(_plan(line.plan).priceUsd),
                        helperText: l.priceOverrideHint,
                        helperMaxLines: 2,
                      ),
                      onChanged: (_) => _edit(),
                    ),
                  ),
                ],
              ),
            ),
          if (line.on && (_unit(line) ?? 0) <= 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                l.setPriceFirst,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _total2(
    BuildContext context,
    String label,
    String value, {
    bool strong = false,
  }) {
    final theme = Theme.of(context);
    final style = strong
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}
