import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'inbox.dart';
import 'widgets.dart';

/// People asking to join; admins accept or decline each one.
class JoinRequestsScreen extends ConsumerWidget {
  const JoinRequestsScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final ws = membership.workspaceId;
    final requests = ref.watch(joinRequestsProvider(ws));

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
                      icon: LucideIcons.userCheck,
                      title: l.noJoinRequests,
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) =>
                      JoinRequestCard(workspaceId: ws, request: list[i]),
                ),
        ),
      ),
    );
  }
}

/// Someone asking to join: who, when, their message, and the answer.
class JoinRequestCard extends ConsumerWidget {
  const JoinRequestCard({
    super.key,
    required this.workspaceId,
    required this.request,
  });

  final String workspaceId;
  final JoinRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final r = request;
    final faint = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Future<void> answer(bool accept) => answerJoinRequest(
      context,
      ref,
      workspaceId: workspaceId,
      requestId: r.id,
      accept: accept,
    );

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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.fullName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (r.email != null) LtrLine(r.email!, style: faint),
                      Text(
                        MaterialLocalizations.of(context)
                            .formatMediumDate(r.createdAt.toLocal()),
                        style: faint,
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
            AnswerButtons(
              onAccept: () => answer(true),
              onDecline: () => answer(false),
            ),
          ],
        ),
      ),
    );
  }
}
