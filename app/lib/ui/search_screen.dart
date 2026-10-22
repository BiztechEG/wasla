import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../data/models.dart';
import '../state/providers.dart';
import 'widgets.dart';

/// Finds discoverable workspaces by name and sends join requests.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  Future<List<WorkspaceHit>>? _results;
  final _requested = <String>{};

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final q = text.trim();
      setState(() {
        _results = q.length < 2
            ? null
            : ref.read(apiProvider).searchWorkspaces(q);
      });
    });
  }

  Future<void> _ask(WorkspaceHit hit) async {
    final l = context.l10n;
    final message = await showDialog<String>(
      context: context,
      builder: (context) => _JoinDialog(workspace: hit.name),
    );
    if (message == null || !mounted) return;
    try {
      await ref
          .read(apiProvider)
          .requestToJoin(hit.id, message: message.isEmpty ? null : message);
      if (!mounted) return;
      showMessage(context, l.requestSent(hit.name));
      setState(() => _requested.add(hit.id));
    } on PostgrestException catch (e) {
      if (!mounted) return;
      // A request is already waiting: treat it as sent.
      if (e.code == '23505') {
        setState(() => _requested.add(hit.id));
      } else {
        showMessage(context, errorText(l, e));
      }
    } catch (e) {
      if (mounted) showMessage(context, errorText(l, e));
    }
    if (mounted) ref.invalidate(myJoinRequestsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final mine = {
      for (final m in ref.watch(membershipsProvider).value ?? <Membership>[])
        m.workspaceId,
    };
    final pending = {
      ..._requested,
      for (final r
          in ref.watch(myJoinRequestsProvider).value ?? <MyJoinRequest>[])
        r.workspaceId,
    };

    return Scaffold(
      appBar: AppBar(title: Text(l.searchTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const Key('search'),
              controller: _query,
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: l.searchHint,
                prefixIcon: const Icon(LucideIcons.search),
              ),
            ),
          ),
          Expanded(
            child: _results == null
                ? EmptyState(icon: LucideIcons.search, title: l.searchMinChars)
                : FutureBuilder<List<WorkspaceHit>>(
                    future: _results,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return ErrorView(
                          error: snap.error!,
                          onRetry: () => _onChanged(_query.text),
                        );
                      }
                      if (!snap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final hits = snap.data!;
                      if (hits.isEmpty) {
                        return EmptyState(
                          icon: LucideIcons.searchX,
                          title: l.noResults,
                        );
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: hits.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final hit = hits[i];
                          final Widget trailing;
                          if (mine.contains(hit.id)) {
                            trailing = Tag(l.alreadyMember, strong: true);
                          } else if (pending.contains(hit.id)) {
                            trailing = Tag(l.requested);
                          } else {
                            trailing = FilledButton.tonal(
                              onPressed: () => _ask(hit),
                              child: Text(l.requestToJoin),
                            );
                          }
                          return Card(
                            child: ListTile(
                              leading: Avatar(name: hit.name),
                              title: Text(
                                hit.name,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              trailing: trailing,
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _JoinDialog extends StatefulWidget {
  const _JoinDialog({required this.workspace});

  final String workspace;

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  final _message = TextEditingController();

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(widget.workspace),
      content: TextField(
        controller: _message,
        inputFormatters: messageLimit,
        maxLines: 3,
        minLines: 1,
        decoration: InputDecoration(labelText: l.joinMessageLabel),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _message.text.trim()),
          child: Text(l.send),
        ),
      ],
    );
  }
}
