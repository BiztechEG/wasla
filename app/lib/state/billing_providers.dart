import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/billing_models.dart';
import 'providers.dart';
import 'task_providers.dart';

/// Whether the signed-in user runs the platform; false when signed out.
final platformAdminProvider = FutureProvider<bool>((ref) async {
  final api = ref.watch(apiProvider);
  if (await ref.watch(authProvider.future) == null) return false;
  return api.isPlatformAdmin();
});

/// A company's subscription page. Billing news (an invoice, a plan turned
/// on) arrives as notifications, so those reload it.
final billingProvider = FutureProvider.autoDispose
    .family<BillingOverview, String>((ref, companyId) async {
      final api = ref.watch(apiProvider);
      refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
      await ref.watch(authProvider.future);
      return api.billing(companyId);
    });

final adminOverviewProvider = FutureProvider.autoDispose<AdminOverview>((
  ref,
) async {
  final api = ref.watch(apiProvider);
  refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
  await ref.watch(authProvider.future);
  return api.adminOverview();
});

final adminRequestsProvider = FutureProvider.autoDispose<List<AdminRequest>>((
  ref,
) async {
  final api = ref.watch(apiProvider);
  refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
  await ref.watch(authProvider.future);
  return api.adminRequests();
});

/// Companies matching a search; an empty search lists them all.
final adminCompaniesProvider = FutureProvider.autoDispose
    .family<List<AdminCompany>, String>((ref, search) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.adminCompanies(search: search.trim().isEmpty ? null : search);
    });

/// Invoices with one status, or all of them for null.
final adminInvoicesProvider = FutureProvider.autoDispose
    .family<List<Invoice>, InvoiceStatus?>((ref, status) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.adminInvoices(status: status);
    });

final adminPlansProvider = FutureProvider.autoDispose<List<PlanOption>>((
  ref,
) async {
  final api = ref.watch(apiProvider);
  await ref.watch(authProvider.future);
  return api.adminPlans();
});

final adminRatesProvider = FutureProvider.autoDispose<List<CountryRate>>((
  ref,
) async {
  final api = ref.watch(apiProvider);
  await ref.watch(authProvider.future);
  return api.adminRates();
});

final adminPaymentInfoProvider = FutureProvider.autoDispose<PaymentInfo>((
  ref,
) async {
  final api = ref.watch(apiProvider);
  await ref.watch(authProvider.future);
  return api.adminPaymentInfo();
});

/// After a billing change here: every page that may show it reloads.
void refreshBilling(WidgetRef ref) {
  ref.invalidate(billingProvider);
  ref.invalidate(adminOverviewProvider);
  ref.invalidate(adminRequestsProvider);
  ref.invalidate(adminCompaniesProvider);
  ref.invalidate(adminInvoicesProvider);
  ref.invalidate(adminPlansProvider);
  ref.invalidate(adminRatesProvider);
  ref.invalidate(adminPaymentInfoProvider);
  // Plans and seats show in the workspace switcher and the More tab.
  ref.invalidate(membershipsProvider);
}
