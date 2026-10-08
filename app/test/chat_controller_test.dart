import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/state/chat_providers.dart';
import 'package:wasla/state/providers.dart';

import 'fake_api.dart';

const _dock = Project(
  id: 'p1',
  workspaceId: 'ws1',
  name: 'Dock',
  color: '#2F5BD3',
  status: ProjectStatus.active,
  memberCount: 2,
);

/// Adds messages without telling anyone, as if they arrived while offline.
void _arriveQuietly(FakeApi api, String chat, int count, int from) {
  final list = api.chatMessages[chat]!;
  final last = list.isEmpty ? DateTime.utc(2026, 10, 8) : list.first.createdAt;
  for (var i = 0; i < count; i++) {
    list.insert(
      0,
      ChatMessage(
        id: 'q${from + i}',
        senderId: 'u2',
        senderName: 'Mona',
        createdAt: last.add(Duration(seconds: i + 1)),
        body: 'message ${from + i}',
        projectId: 'p1',
      ),
    );
  }
}

void main() {
  test('catching up after a long time offline leaves no hole', () async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..projectsByWorkspace['ws1'] = [_dock];
    final chat = api.addProjectChat('ws1', _dock);
    _arriveQuietly(api, chat, 60, 0);

    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final key = (workspaceId: 'ws1', conversationId: chat, projectId: null);
    container.listen(chatProvider(key), (_, _) {});
    await container.read(authProvider.future);
    var state = await container.read(chatProvider(key).future);
    expect(state.messages, hasLength(50));

    // More arrive than one refresh fetches.
    _arriveQuietly(api, chat, 61, 60);
    final controller = container.read(chatProvider(key).notifier);
    await controller.refresh();
    while (container.read(chatProvider(key)).value!.hasMore) {
      await controller.loadOlder();
    }

    state = container.read(chatProvider(key)).value!;
    final ids = state.messages.map((m) => m.id).toSet();
    expect(ids, hasLength(121));
    expect(ids, containsAll(['q0', 'q59', 'q60', 'q120']));
  });

  test('a chat filtered by project does not mark the rest read', () async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..projectsByWorkspace['ws1'] = [_dock]
      ..membersByWorkspace['ws1'] = [
        const Member(
          userId: 'u2',
          fullName: 'Mona',
          role: WorkspaceRole.member,
        ),
      ];
    final chat = await api.openDirect('ws1', 'u2');
    api
      ..receive(chat, 'u2', 'Mona', 'about lunch')
      ..receive(chat, 'u2', 'Mona', 'about the dock', projectId: 'p1');

    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final filtered = (
      workspaceId: 'ws1',
      conversationId: chat,
      projectId: 'p1',
    );
    container.listen(chatProvider(filtered), (_, _) {});
    await container.read(authProvider.future);
    final state = await container.read(chatProvider(filtered).future);
    expect(state.messages.single.body, 'about the dock');
    await Future<void>.delayed(Duration.zero);
    expect(api.reads[chat]?['me'], isNull);

    final whole = (workspaceId: 'ws1', conversationId: chat, projectId: null);
    container.listen(chatProvider(whole), (_, _) {});
    await container.read(chatProvider(whole).future);
    await Future<void>.delayed(Duration.zero);
    expect(api.reads[chat]?['me'], isNotNull);
  });
}
