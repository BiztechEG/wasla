import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/l10n/app_localizations_ar.dart';
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
    expect(errorText(l, Exception('boom')), l.errorGeneric);
  });
}
