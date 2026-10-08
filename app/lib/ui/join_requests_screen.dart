import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'widgets.dart';

/// People asking to join; admins accept or decline each one.
class JoinRequestsScreen extends ConsumerWidget {
  const JoinRequestsScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final ws = membership.workspaceId;
    final requests = ref.watch(joinRequestsProvider(ws));
    final localizations = MaterialLocalizations.of(context);

    Future<void> decide(JoinRequest r, bool accept) async {
      final ok = await runAction(
        context,
        () => ref.read(apiProvider).decideJoinRequest(r.id, accept: accept),
      );
      if (ok && context.mounted) {
        ref.invalidate(joinRequestsProvider(ws));
        ref.invalidate(membersProvider(ws));
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.joinRequests)),
      body: AsyncView(
        value: requests,
        onRetry: () => ref.invalidate(joinRequestsProvider(ws)),
        builder: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(joinRequestsProvider(ws).future),
          child: list.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 80),
                    EmptyState(
                      icon: Icons.how_to_reg_outlined,
                      title: l.noJoinRequests,
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final r = list[i];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Avatar(name: r.fullName),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        r.fullName,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      Text(
                                        '${ltr(r.email ?? '')} · '
                                        '${localizations.formatMediumDate(r.createdAt.toLocal())}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (r.message != null && r.message!.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(r.message!),
                            ],
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: BusyButton(
                                    label: l.accept,
                                    onPressed: () => decide(r, true),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: () => decide(r, false),
                                    child: Text(l.decline),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
