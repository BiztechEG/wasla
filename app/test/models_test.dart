import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wasla/data/chat_models.dart';
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
}
