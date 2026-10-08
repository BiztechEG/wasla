import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wasla/data/billing_models.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/l10n/app_localizations_ar.dart';
import 'package:wasla/ui/admin_billing.dart';
import 'package:wasla/ui/widgets.dart';

void main() {
  test('reads a membership row with its workspace, plan and company', () {
    final m = Membership.fromJson({
      'role': 'admin',
      'workspaces': {
        'id': 'ws1',
        'name': 'Engineering',
        'company_id': 'c1',
        'discoverable': true,
        'plans': {'name': 'Free', 'max_members': 10},
        'companies': {'name': 'Al Nour', 'owner_id': 'me'},
      },
    }, me: 'me');

    expect(m.workspaceName, 'Engineering');
    expect(m.role, WorkspaceRole.admin);
    expect(m.role.canManage, isTrue);
    expect(m.maxMembers, 10);
    expect(m.isCompanyOwner, isTrue);
    expect(m.discoverable, isTrue);
  });

  test('reads the embedded member count of a project', () {
    final p = Project.fromJson({
      'id': 'p1',
      'workspace_id': 'ws1',
      'name': 'Warehouse',
      'color': '#2F5BD3',
      'status': 'archived',
      'project_members': [
        {'count': 4},
      ],
    });

    expect(p.memberCount, 4);
    expect(p.status, ProjectStatus.archived);
  });

  test('database errors become messages people can act on', () {
    final l = AppLocalizationsAr();

    expect(
      errorText(
        l,
        const PostgrestException(message: 'seat_limit_reached', code: 'P0001'),
      ),
      l.errorSeatLimit,
    );
    expect(
      errorText(
        l,
        const PostgrestException(message: 'last_owner', code: 'P0001'),
      ),
      l.errorLastOwner,
    );
    expect(
      errorText(
        l,
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      ),
      l.errorNotAllowed,
    );
    expect(
      errorText(l, AuthException('Token has expired', code: 'otp_expired')),
      l.errorWrongCode,
    );
    expect(
      errorText(
        l,
        const PostgrestException(message: 'too_many_requests', code: 'P0001'),
      ),
      l.errorTooMany,
    );
    expect(
      errorText(
        l,
        const PostgrestException(message: 'check constraint', code: '23514'),
      ),
      l.errorTooLong,
    );
    expect(
      errorText(
        l,
        const StorageException(
          'new row violates row-level security policy',
          statusCode: '403',
        ),
      ),
      l.errorUploadRefused,
    );
    expect(errorText(l, Exception('boom')), l.errorGeneric);
  });

  test('only a private chat can show its other person as gone', () {
    final project = Conversation.fromJson({
      'id': 'c1',
      'kind': 'project',
      'project_id': 'p1',
      'project_name': 'Dock',
      'other_active': false,
    });
    final direct = Conversation.fromJson({
      'id': 'c2',
      'kind': 'direct',
      'other_id': 'u2',
      'other_name': 'Mona',
      'other_active': false,
    });
    expect(project.otherActive, isTrue);
    expect(direct.otherActive, isFalse);
  });

  test('a search hit carries the chat it is in', () {
    final hit = MessageHit.fromJson({
      'message_id': 'm1',
      'conversation_id': 'c1',
      'created_at': '2026-10-08T09:00:00.123456+00:00',
      'sender_name': 'Mona',
      'body': 'تقرير',
      'kind': 'project',
      'project_id': 'p1',
      'project_name': 'Dock',
      'project_color': '#2F5BD3',
    });
    expect(hit.conversationId, 'c1');
    expect(hit.chat.isProject, isTrue);
    expect(hit.chat.title, 'Dock');
  });

  test('Arabic names get one initial without the article', () {
    expect(initials('الإدارة الهندسية'), 'إ');
    expect(initials('خالد العتيبي'), 'خ');
    expect(initials('Ahmed Hassan'), 'AH');
    expect(initials('  '), '');
  });

  test('reads a company\'s billing page, with amounts as text or numbers', () {
    final b = BillingOverview.fromJson({
      'company': {
        'id': 'c1',
        'name': 'Al Nour',
        'country_code': 'EG',
        'currency': 'EGP',
        'rate': '50.0000',
      },
      'plans': [
        {
          'id': 'basic',
          'name': 'Basic',
          'max_members': 50,
          'storage_gb': 50,
          'price_usd': 20,
          'price_local': '1000.00',
          'offered': true,
        },
        {
          'id': 'enterprise',
          'name': 'Enterprise',
          'max_members': null,
          'storage_gb': null,
          'price_usd': 0,
          'price_local': 0,
          'offered': false,
        },
      ],
      'workspaces': [
        {
          'id': 'ws1',
          'name': 'HQ',
          'plan_id': 'basic',
          'plan_name': 'Basic',
          'max_members': 50,
          'storage_gb': 50,
          'paid_until': '2026-12-01T10:00:00+00:00',
          'members': 3,
          'storage_bytes': 1024,
          'request': {
            'id': 'r1',
            'plan_id': 'enterprise',
            'months': 12,
            'status': 'invoiced',
            'created_at': '2026-10-08T10:00:00+00:00',
          },
        },
      ],
      'invoices': [
        {
          'id': 'i1',
          'number': 'WSL-2026-00001',
          'company_id': 'c1',
          'company_name': 'Al Nour',
          'status': 'void',
          'months': 3,
          'currency': 'EGP',
          'rate': 50,
          'subtotal_usd': 240,
          'discount_pct': '10.00',
          'total_usd': 216,
          'total_local': 10800,
          'note': null,
          'issued_at': '2026-10-08T10:00:00+00:00',
          'due_at': '2026-10-22T10:00:00+00:00',
          'paid_at': null,
          'payment_ref': null,
          'lines': [
            {
              'workspace_id': null,
              'workspace_name': 'Old branch',
              'plan_id': 'basic',
              'plan_name': 'Basic',
              'members': 3,
              'unit_usd': 20,
              'amount_usd': 60,
              'amount_local': 3000,
            },
          ],
        },
      ],
      'payment': {'instructions': '', 'phone': '', 'email': ''},
    });

    expect(b.company.rate, 50);
    expect(b.plans.first.priceLocal, 1000);
    expect(b.plan('enterprise')!.maxMembers, isNull);
    expect(b.plan('enterprise')!.offered, isFalse);
    expect(b.workspaces.single.request!.status, RequestStatus.invoiced);
    expect(b.workspaces.single.paidUntil, DateTime.utc(2026, 12, 1, 10));
    final invoice = b.invoices.single;
    expect(invoice.status, InvoiceStatus.void_);
    expect(invoice.discountPct, 10);
    expect(invoice.isOverdue(DateTime.utc(2027)), isFalse);
    expect(invoice.lines.single.workspaceId, isNull);
    expect(b.payment.isEmpty, isTrue);
  });

  test('an invoice item sends a price only when one was agreed', () {
    expect(const InvoiceItem(workspaceId: 'ws1', planId: 'basic').toJson(), {
      'workspace_id': 'ws1',
      'plan_id': 'basic',
    });
    expect(
      const InvoiceItem(
        workspaceId: 'ws1',
        planId: 'enterprise',
        priceUsd: 400,
      ).toJson()['price_usd'],
      400,
    );
    expect(InvoiceStatus.void_.wire, 'void');
  });

  test('numbers typed with Arabic digits are read', () {
    expect(parseNumber('٥٢٫٥'), 52.5);
    expect(parseNumber('۱۲'), 12);
    expect(parseNumber(' 1,250.75 '), 1250.75);
    expect(parseNumber('abc'), isNull);
    expect(parseNumber(''), isNull);
  });
}
