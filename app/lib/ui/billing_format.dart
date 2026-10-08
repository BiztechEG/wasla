import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/billing_models.dart';
import '../l10n/app_localizations.dart';
import 'chat_format.dart';
import 'widgets.dart';

/// The plans the platform starts with have names in both languages; a name a
/// platform admin chose shows as written.
String planLabel(AppLocalizations l, String name) => switch (name) {
  'Free' => l.planFree,
  'Basic' => l.planBasic,
  'Business' => l.planBusiness,
  'Enterprise' => l.planEnterprise,
  _ => name,
};

const _arabicCurrency = {
  'EGP': 'ج.م',
  'SAR': 'ر.س',
  'AED': 'د.إ',
  'KWD': 'د.ك',
  'QAR': 'ر.ق',
  'BHD': 'د.ب',
  'OMR': 'ر.ع',
  'USD': r'$',
};

String currencyLabel(BuildContext context, String currency) =>
    Localizations.localeOf(context).languageCode == 'ar'
    ? _arabicCurrency[currency] ?? currency
    : currency;

/// 1,000 ج.م / EGP 1,000 / $20, with western digits and cents only when
/// there are some.
String money(BuildContext context, double amount, String currency) {
  final whole = amount == amount.roundToDouble();
  final n = NumberFormat.decimalPatternDigits(
    locale: 'en',
    decimalDigits: whole ? 0 : 2,
  ).format(amount);
  if (Localizations.localeOf(context).languageCode == 'ar') {
    return '$n ${currencyLabel(context, currency)}';
  }
  return currency == 'USD' ? '\$$n' : '$currency $n';
}

String usd(BuildContext context, double amount) =>
    money(context, amount, 'USD');

/// 12 November 2026
String dateText(BuildContext context, DateTime time) => westernDigits(
  DateFormat(
    'd MMMM yyyy',
    Localizations.localeOf(context).languageCode,
  ).format(time.toLocal()),
);

/// 50 members · 50 GB, or unlimited.
String planLimits(AppLocalizations l, PlanOption plan) => [
  plan.maxMembers == null
      ? l.unlimitedMembers
      : l.memberCount(plan.maxMembers!),
  plan.storageGb == null ? l.unlimitedStorage : l.storageGb(plan.storageGb!),
].join(' · ');

String invoiceStatusLabel(AppLocalizations l, Invoice invoice) =>
    switch (invoice.status) {
      InvoiceStatus.paid => l.invoicePaid,
      InvoiceStatus.void_ => l.invoiceVoid,
      InvoiceStatus.issued =>
        invoice.isOverdue(DateTime.now()) ? l.invoiceOverdue : l.invoiceDue,
    };

class InvoiceStatusTag extends StatelessWidget {
  const InvoiceStatusTag(this.invoice, {super.key});

  final Invoice invoice;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final late = invoice.isOverdue(DateTime.now());
    final color = switch (invoice.status) {
      InvoiceStatus.paid => scheme.primary,
      InvoiceStatus.void_ => scheme.onSurfaceVariant,
      InvoiceStatus.issued => late ? scheme.error : scheme.tertiary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        invoiceStatusLabel(context.l10n, invoice),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A labelled bar for how much of a limit is used.
class UsageBar extends StatelessWidget {
  const UsageBar({
    super.key,
    required this.label,
    required this.used,
    this.limit,
  });

  final String label;
  final double used;

  /// Null for unlimited: the bar is left out.
  final double? limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = limit == null || limit! <= 0
        ? null
        : (used / limit!).clamp(0.0, 1.0);
    final full = share != null && share >= 0.9;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: full
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (share != null) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: share,
              minHeight: 6,
              color: full ? theme.colorScheme.error : null,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ],
    );
  }
}

/// Keeps a page readable on a wide browser window.
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child, this.max = 760});

  final Widget child;
  final double max;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: max),
      child: child,
    ),
  );
}
