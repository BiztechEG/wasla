import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/billing_models.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/task_models.dart';

import 'fake_api.dart';
import 'harness.dart';

const _plans = [
  PlanOption(
    id: 'free',
    name: 'Free',
    maxMembers: 10,
    storageGb: 5,
    priceUsd: 0,
    priceLocal: 0,
  ),
  PlanOption(
    id: 'basic',
    name: 'Basic',
    maxMembers: 50,
    storageGb: 50,
    priceUsd: 20,
    priceLocal: 1000,
  ),
  PlanOption(
    id: 'business',
    name: 'Business',
    maxMembers: 250,
    storageGb: 500,
    priceUsd: 60,
    priceLocal: 3000,
  ),
  PlanOption(id: 'enterprise', name: 'Enterprise', priceUsd: 0, priceLocal: 0),
];

final _invoice = Invoice(
  id: 'inv1',
  number: 'WSL-2026-00001',
  companyId: 'c1',
  companyName: 'Al Nour',
  status: InvoiceStatus.issued,
  months: 3,
  currency: 'EGP',
  rate: 50,
  subtotalUsd: 180,
  discountPct: 0,
  totalUsd: 180,
  totalLocal: 9000,
  issuedAt: DateTime.now().subtract(const Duration(days: 2)),
  dueAt: DateTime.now().add(const Duration(days: 12)),
  lines: const [
    InvoiceLine(
      workspaceId: 'ws2',
      workspaceName: 'Site',
      planId: 'business',
      planName: 'Business',
      members: 60,
      unitUsd: 60,
      amountUsd: 180,
      amountLocal: 9000,
    ),
  ],
);

/// Al Nour, an Egyptian company: Engineering on the free plan and Site on
/// Business, with an invoice waiting for payment.
BillingOverview _page({PlanRequest? request}) => BillingOverview(
  company: const BillingCompany(
    id: 'c1',
    name: 'Al Nour',
    countryCode: 'EG',
    currency: 'EGP',
    rate: 50,
  ),
  plans: _plans,
  workspaces: [
    WorkspaceBilling(
      id: 'ws1',
      name: 'Engineering',
      planId: 'free',
      planName: 'Free',
      maxMembers: 10,
      storageGb: 5,
      members: 4,
      storageBytes: 300 * 1024 * 1024,
      request: request,
    ),
    WorkspaceBilling(
      id: 'ws2',
      name: 'Site',
      planId: 'business',
      planName: 'Business',
      maxMembers: 250,
      storageGb: 500,
      paidUntil: DateTime.now().add(const Duration(days: 40)),
      members: 60,
      storageBytes: 5 * 1024 * 1024 * 1024 ~/ 2,
    ),
  ],
  invoices: [_invoice],
  payment: const PaymentInfo(
    instructions: 'Transfer to National Bank account 123',
    phone: '+20 100 000 0000',
    email: 'billing@example.com',
  ),
);

FakeApi _owner() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
  )
  ..billingPages['c1'] = _page();

/// Salma runs the platform; Al Nour asked for Business for Engineering.
FakeApi _admin() {
  final api = FakeApi(signedInAs: 'me', name: 'Salma')
    ..memberships.add(
      FakeApi.membership('ws9', 'Wasla team', WorkspaceRole.owner),
    )
    ..platformAdmin = true
    ..billingPages['c1'] = _page(
      request: PlanRequest(
        id: 'r1',
        planId: 'business',
        months: 3,
        status: RequestStatus.pending,
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      ),
    )
    ..adminFigures = const AdminOverview(
      companies: 12,
      workspaces: 19,
      paidWorkspaces: 7,
      members: 240,
      pendingRequests: 1,
      unpaidInvoices: 1,
      unpaidUsd: 180,
      paidUsd30d: 960,
    )
    ..adminRequestList.add(
      AdminRequest(
        id: 'r1',
        companyId: 'c1',
        companyName: 'Al Nour',
        workspaceId: 'ws1',
        workspaceName: 'Engineering',
        currentPlan: 'Free',
        planId: 'business',
        planName: 'Business',
        months: 3,
        note: 'Before the new branch opens',
        requestedByName: 'Amr',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      ),
    )
    ..adminCompanyList.add(
      AdminCompany(
        id: 'c1',
        name: 'Al Nour',
        countryCode: 'EG',
        ownerName: 'Amr',
        ownerEmail: 'amr@example.com',
        createdAt: DateTime(2026, 10, 1),
        pendingRequests: 1,
        unpaidInvoices: 1,
        workspaces: const [
          AdminWorkspace(
            id: 'ws1',
            name: 'Engineering',
            planId: 'free',
            planName: 'Free',
            members: 4,
          ),
        ],
      ),
    )
    ..adminInvoiceList.add(_invoice)
    ..adminPlanList.addAll([
      for (final p in _plans)
        PlanOption(
          id: p.id,
          name: p.name,
          maxMembers: p.maxMembers,
          storageGb: p.storageGb,
          priceUsd: p.priceUsd,
          priceLocal: p.priceUsd,
          workspaces: 3,
        ),
    ])
    ..adminRateList.addAll([
      CountryRate(
        countryCode: 'EG',
        currency: 'EGP',
        rate: 50,
        effectiveFrom: DateTime(2026, 10, 1),
        setByName: 'Salma',
      ),
      const CountryRate(countryCode: 'SA', currency: 'SAR'),
    ]);
  return api;
}

Future<void> _tapText(WidgetTester tester, String text) async {
  if (find.text(text).evaluate().isEmpty) {
    // Further down a list, not built yet.
    await tester.scrollUntilVisible(
      find.text(text),
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(find.text(text).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> _openBilling(WidgetTester tester) async {
  await tester.tap(find.byTooltip('المزيد'));
  await tester.pumpAndSettle();
  await _tapText(tester, 'الاشتراك والفواتير');
}

Future<void> _openAdmin(WidgetTester tester) async {
  await tester.tap(find.byTooltip('المزيد'));
  await tester.pumpAndSettle();
  await _tapText(tester, 'إدارة المنصة');
}

void main() {
  testWidgets('an owner sees each workspace\'s plan and use', (tester) async {
    await startApp(tester, _owner());
    await _openBilling(tester);

    expect(find.text('فاتورة بانتظار الدفع'), findsOneWidget);
    expect(find.text('المجانية'), findsOneWidget);
    expect(find.text('الأعمال'), findsOneWidget);
    expect(find.text('الأعضاء: 4 من 10'), findsOneWidget);
    expect(find.text('الأعضاء: 60 من 250'), findsOneWidget);
    expect(find.text('التخزين: 300 ميجا من 5 جيجابايت'), findsOneWidget);
    expect(find.text('التخزين: 2.5 جيجابايت من 500 جيجابايت'), findsOneWidget);
    expect(find.textContaining('مدفوعة حتى'), findsOneWidget);
    expect(find.text('على الخطة المجانية'), findsOneWidget);
  });

  testWidgets('an owner asks for a plan, then cancels the request', (
    tester,
  ) async {
    final api = _owner();
    await startApp(tester, api);
    await _openBilling(tester);

    await _tapText(tester, 'ترقية الخطة');
    expect(find.text('اختر خطة لمساحة Engineering'), findsOneWidget);
    // Local prices a month, and a plan without a price yet.
    expect(find.text('1,000 ج.م'), findsWidgets);
    expect(find.text('3,000 ج.م'), findsOneWidget);
    expect(find.text('السعر في الفاتورة'), findsOneWidget);

    await tester.tap(find.text('الأعمال').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 أشهر'));
    await tester.pumpAndSettle();
    expect(find.text('9,000 ج.م'), findsWidgets);

    await tester.enterText(find.byType(TextField), 'From next month');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _tapText(tester, 'إرسال الطلب');

    expect(api.billingCalls, ['request ws1 business 3 From next month']);
    expect(
      find.text('طلبت خطة الأعمال لمدة 3 أشهر، والفاتورة قيد الإعداد.'),
      findsOneWidget,
    );
    expect(find.text('تعديل الطلب'), findsOneWidget);

    await _tapText(tester, 'إلغاء الطلب');
    expect(find.text('هل تريد إلغاء طلب الخطة؟'), findsOneWidget);
    await _tapText(tester, 'إلغاء الطلب');
    expect(api.billingCalls.last, 'cancel r-ws1');
    expect(find.text('ترقية الخطة'), findsOneWidget);
  });

  testWidgets('plans too small for the workspace cannot be picked', (
    tester,
  ) async {
    final api = _owner();
    await startApp(tester, api);
    await _openBilling(tester);

    await _tapText(tester, 'تجديد أو تغيير');
    expect(find.text('لا تكفي أعضاءك الحاليين (60)'), findsOneWidget);
    await tester.tap(find.text('لا تكفي أعضاءك الحاليين (60)'));
    await tester.pumpAndSettle();
    // Still on Business, its current plan: a month is 3,000.
    await _tapText(tester, 'إرسال الطلب');
    expect(api.billingCalls, ['request ws2 business 1 -']);
  });

  testWidgets('an owner reads an invoice and how to pay it', (tester) async {
    await startApp(tester, _owner());
    await _openBilling(tester);
    await _tapText(tester, 'WSL-2026-00001');

    expect(find.text('Site'), findsOneWidget);
    expect(find.text('9,000 ج.م'), findsWidgets);
    expect(find.text('1 دولار = 50 ج.م'), findsOneWidget);
    expect(find.text('3 أشهر'), findsOneWidget);
    expect(find.text('Transfer to National Bank account 123'), findsOneWidget);
    expect(find.text('+20 100 000 0000'), findsOneWidget);
    expect(find.text('تسجيل الدفع'), findsNothing);
  });

  testWidgets('billing notifications open the subscription page', (
    tester,
  ) async {
    final api = _owner()
      ..notificationList.add(
        AppNotification(
          id: 'n1',
          kind: NotificationKind.planEnding,
          workspaceId: 'ws1',
          workspaceName: 'Engineering',
          detail: 'Business',
          createdAt: DateTime.now(),
        ),
      );
    await startApp(tester, api);
    await tester.tap(find.byTooltip('الإشعارات'));
    await tester.pumpAndSettle();

    expect(
      find.text('تنتهي خطة الأعمال خلال أسبوع، جدّد الاشتراك للاستمرار'),
      findsOneWidget,
    );
    await _tapText(
      tester,
      'تنتهي خطة الأعمال خلال أسبوع، جدّد الاشتراك للاستمرار',
    );
    expect(find.text('الاشتراك والفواتير'), findsOneWidget);
    expect(find.text('Site'), findsOneWidget);
  });

  testWidgets('only platform admins see the admin dashboard', (tester) async {
    await startApp(tester, _owner());
    await tester.tap(find.byTooltip('المزيد'));
    await tester.pumpAndSettle();
    expect(find.text('إدارة المنصة'), findsNothing);
  });

  testWidgets('a platform admin changes the app logo', (tester) async {
    final api = _admin();
    await startApp(
      tester,
      api,
      picker: FakePicker(
        Upload(bytes: Uint8List(10), name: 'new-logo.png', mime: 'image/png'),
      ),
    );
    await _openAdmin(tester);

    expect(find.text('استخدام الشعار الأصلي'), findsNothing);
    await _tapText(tester, 'تغيير الشعار');
    expect(api.logo, 'new-logo.png');
    expect(find.text('تم حفظ الشعار'), findsOneWidget);

    await _tapText(tester, 'استخدام الشعار الأصلي');
    expect(api.logo, isNull);
  });

  testWidgets('a logo must be a PNG, JPEG or WebP image', (tester) async {
    final api = _admin();
    await startApp(
      tester,
      api,
      picker: FakePicker(
        Upload(bytes: Uint8List(10), name: 'logo.gif', mime: 'image/gif'),
      ),
    );
    await _openAdmin(tester);
    await _tapText(tester, 'تغيير الشعار');
    expect(api.logo, isNull);
    expect(find.text('اختر صورة PNG أو JPG أو WebP'), findsOneWidget);
  });

  testWidgets('a platform admin invoices a plan request', (tester) async {
    final api = _admin();
    await startApp(tester, api);
    await _openAdmin(tester);

    expect(find.text('12'), findsOneWidget);
    expect(find.text('960 \$'), findsOneWidget);
    expect(find.text('Al Nour · Engineering'), findsOneWidget);
    expect(find.textContaining('من المجانية إلى الأعمال · 3 أشهر'), findsOne);

    await _tapText(tester, 'Al Nour · Engineering');
    await _tapText(tester, 'فاتورة جديدة');

    // The request's workspace starts ticked, on what was asked for.
    final ticked = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, 'Engineering'),
    );
    expect(ticked.value, isTrue);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Site'),
          )
          .value,
      isFalse,
    );
    expect(find.text('180 \$'), findsWidgets);
    expect(find.text('9,000 ج.م'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'نسبة الخصم %'),
      '10',
    );
    await tester.pumpAndSettle();
    expect(find.text('162 \$'), findsOneWidget);
    expect(find.text('8,100 ج.م'), findsOneWidget);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _tapText(tester, 'إصدار الفاتورة');
    expect(api.billingCalls, ['invoice c1 ws1:business:- 3 10.0 14']);
  });

  testWidgets('an invoice needs a price for every plan on it', (tester) async {
    final api = _admin();
    await startApp(tester, api);
    await _openAdmin(tester);
    await _tapText(tester, 'Al Nour · Engineering');
    await _tapText(tester, 'فاتورة جديدة');

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Site'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الأعمال').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('المؤسسات').last);
    await tester.pumpAndSettle();
    expect(find.text('حدّد سعراً لهذه الخطة أولاً'), findsOneWidget);

    await _tapText(tester, 'إصدار الفاتورة');
    expect(api.billingCalls, isEmpty);

    // An agreed price fixes it.
    await tester.enterText(
      find.widgetWithText(TextField, 'سعر خاص (\$)').last,
      '٤٠٠',
    );
    await tester.pumpAndSettle();
    expect(find.text('حدّد سعراً لهذه الخطة أولاً'), findsNothing);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await _tapText(tester, 'إصدار الفاتورة');
    expect(api.billingCalls, [
      'invoice c1 ws1:business:-,ws2:enterprise:400.0 3 0.0 14',
    ]);
  });

  testWidgets('a platform admin records a payment', (tester) async {
    final api = _admin();
    await startApp(tester, api);
    await _openAdmin(tester);
    await _tapText(tester, 'الفواتير');

    await _tapText(tester, 'Al Nour · WSL-2026-00001');
    await _tapText(tester, 'تسجيل الدفع');
    expect(find.text('تسجيل دفع الفاتورة WSL-2026-00001'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'مرجع الدفع'),
      'TRX-55',
    );
    await tester.tap(find.widgetWithText(TextButton, 'تسجيل الدفع'));
    await tester.pumpAndSettle();

    expect(api.billingCalls, ['paid inv1 TRX-55']);
    // Back on the invoice list.
    expect(find.text('Al Nour · WSL-2026-00001'), findsOneWidget);
  });

  testWidgets('a platform admin cancels an invoice', (tester) async {
    final api = _admin();
    await startApp(tester, api);
    await _openAdmin(tester);
    await _tapText(tester, 'الفواتير');
    await _tapText(tester, 'Al Nour · WSL-2026-00001');

    await _tapText(tester, 'إلغاء الفاتورة');
    expect(find.textContaining('هل تريد إلغاء الفاتورة'), findsOneWidget);
    await _tapText(tester, 'إلغاء الفاتورة');
    expect(api.billingCalls, ['void inv1']);
  });

  testWidgets('the pilot company gets a plan with no end', (tester) async {
    final api = _admin();
    await startApp(tester, api);
    await _openAdmin(tester);
    await _tapText(tester, 'الشركات');
    expect(find.textContaining('مصر · Engineering (المجانية)'), findsOneWidget);

    await _tapText(tester, 'Al Nour');
    await tester.tap(find.text('تعيين الخطة').first);
    await tester.pumpAndSettle();
    expect(find.text('خطة Engineering'), findsOneWidget);
    await tester.tap(find.text('المؤسسات').last);
    await tester.pumpAndSettle();
    expect(find.text('بدون تاريخ انتهاء'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'حفظ'));
    await tester.pumpAndSettle();

    expect(api.billingCalls, ['set ws1 enterprise forever']);
  });

  testWidgets('a platform admin sets prices and rates', (tester) async {
    final api = _admin();
    await startApp(tester, api);
    await _openAdmin(tester);
    await _tapText(tester, 'الأسعار');

    expect(find.text('20 \$ شهرياً'), findsOneWidget);
    expect(find.text('لم يُحدَّد السعر'), findsOneWidget);
    expect(find.text('1 دولار = 50 ج.م'), findsOneWidget);
    expect(find.text('لم يُحدَّد سعر بعد، فتظهر الأسعار بالدولار'), findsOne);

    // Arabic digits are fine.
    await _tapText(tester, 'مصر');
    await tester.enterText(find.byType(TextField), '٥٢٫٥');
    await tester.tap(find.widgetWithText(TextButton, 'حفظ'));
    await tester.pumpAndSettle();
    expect(api.billingCalls, ['rate EG 52.5']);

    await _tapText(tester, 'الأساسية');
    await tester.enterText(
      find.widgetWithText(TextField, 'السعر الشهري (دولار)'),
      '25',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'سعر العامل الإضافي (دولار شهرياً)'),
      '2',
    );
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'حفظ'));
    await tester.pumpAndSettle();
    expect(api.billingCalls.sublist(api.billingCalls.length - 2), [
      'plan basic Basic 50 50 25.0 false',
      'workers basic null 2.0',
    ]);
    // Let the "saved" message clear off the bottom of the page.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await _tapText(tester, 'أضف طريقة دفع الشركات');
    await tester.enterText(
      find.widgetWithText(TextField, 'تعليمات الدفع'),
      'Bank account 123',
    );
    await tester.tap(find.widgetWithText(TextButton, 'حفظ'));
    await tester.pumpAndSettle();
    expect(api.billingCalls.last, 'payment Bank account 123  ');
    expect(find.text('Bank account 123'), findsOneWidget);
  });

  testWidgets('billing pages fit on a small phone', (tester) async {
    smallPhone(tester);
    final api = _admin();
    await startApp(tester, api);
    await _openAdmin(tester);
    expect(tester.takeException(), isNull);
    await _tapText(tester, 'Al Nour · Engineering');
    expect(tester.takeException(), isNull);
    await _tapText(tester, 'فاتورة جديدة');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await _tapText(tester, 'WSL-2026-00001');
    expect(tester.takeException(), isNull);
  });
}
