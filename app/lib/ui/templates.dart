import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../data/task_models.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'widgets.dart';

final taskTemplatesProvider = FutureProvider.autoDispose
    .family<List<TaskTemplate>, String>(
      (ref, workspaceId) => ref.watch(apiProvider).taskTemplates(workspaceId),
    );

/// Picks a template and adds its tasks to [project].
Future<void> addFromTemplate(
  BuildContext context,
  WidgetRef ref,
  Project project,
) async {
  final l = context.l10n;
  final template = await showModalBottomSheet<TaskTemplate>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TemplatesSheet(workspaceId: project.workspaceId),
  );
  if (template == null || !context.mounted) return;
  if (!await confirm(
    context,
    message: l.applyTemplateConfirm(template.items.length, template.name),
    action: l.add,
  )) {
    return;
  }
  if (!context.mounted) return;
  final now = DateTime.now();
  var added = 0;
  final ok = await runAction(context, () async {
    added = await ref
        .read(apiProvider)
        .applyTaskTemplate(
          template.id,
          project.id,
          // Due dates count from today at the end of the working day.
          start: DateTime(now.year, now.month, now.day, 17),
        );
  });
  if (!ok || !context.mounted) return;
  refreshTasks(ref);
  showMessage(context, l.templateApplied(added));
}

/// Saves [tasks] (the project's open ones) as a template.
Future<void> saveAsTemplate(
  BuildContext context,
  WidgetRef ref,
  Project project,
  List<TaskItem> tasks,
) async {
  final l = context.l10n;
  final open = [
    for (final t in tasks)
      if (t.status.isOpen) t,
  ];
  if (open.isEmpty) {
    showMessage(context, l.noOpenTasksToSave);
    return;
  }
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(initial: project.name, count: open.length),
  );
  if (name == null || name.isEmpty || !context.mounted) return;
  final today = DateUtils.dateOnly(DateTime.now());
  final items = [
    for (final t in open.take(50))
      TemplateItem(
        title: t.title,
        priority: t.priority,
        dueInDays: t.dueAt == null
            ? null
            : DateUtils.dateOnly(t.dueAt!.toLocal())
                  .difference(today)
                  .inDays
                  .clamp(0, 999),
      ),
  ];
  final ok = await runAction(
    context,
    () => ref
        .read(apiProvider)
        .saveTaskTemplate(project.workspaceId, name, items),
    done: l.templateSaved,
  );
  if (ok) ref.invalidate(taskTemplatesProvider(project.workspaceId));
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial, required this.count});

  final String initial;
  final int count;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(l.saveAsTemplate),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('templateName'),
            controller: _name,
            autofocus: true,
            inputFormatters: const [RuneLimit(100)],
            decoration: InputDecoration(labelText: l.templateName),
          ),
          const SizedBox(height: 8),
          Text(l.templateTaskCount(widget.count)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _name.text.trim()),
          child: Text(l.save),
        ),
      ],
    );
  }
}

class _TemplatesSheet extends ConsumerWidget {
  const _TemplatesSheet({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final templates = ref.watch(taskTemplatesProvider(workspaceId));
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l.templatesTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: AsyncView(
                value: templates,
                onRetry: () =>
                    ref.invalidate(taskTemplatesProvider(workspaceId)),
                builder: (all) => all.isEmpty
                    ? EmptyState(
                        icon: LucideIcons.copy,
                        title: l.templatesEmpty,
                        body: l.templatesEmptyHint,
                      )
                    : ListView(
                        children: [
                          for (final t in all)
                            ListTile(
                              leading: const Icon(LucideIcons.copy),
                              title: Text(t.name),
                              subtitle: Text(
                                [
                                  l.templateTaskCount(t.items.length),
                                  for (final i in t.items.take(3)) i.title,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: t.canDelete
                                  ? IconButton(
                                      tooltip: l.deleteTemplate,
                                      icon: const Icon(LucideIcons.trash2),
                                      onPressed: () async {
                                        if (!await confirm(
                                              context,
                                              message: l.confirmDeleteTemplate,
                                              action: l.delete,
                                              destructive: true,
                                            ) ||
                                            !context.mounted) {
                                          return;
                                        }
                                        if (await runAction(
                                          context,
                                          () => ref
                                              .read(apiProvider)
                                              .deleteTaskTemplate(t.id),
                                        )) {
                                          ref.invalidate(
                                            taskTemplatesProvider(workspaceId),
                                          );
                                        }
                                      },
                                    )
                                  : null,
                              onTap: () => Navigator.pop(context, t),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The two template actions above a project's tasks.
class TemplateActions extends ConsumerWidget {
  const TemplateActions({
    super.key,
    required this.project,
    required this.tasks,
    required this.canSave,
  });

  final Project project;
  final List<TaskItem> tasks;
  final bool canSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('fromTemplate'),
            onPressed: () => addFromTemplate(context, ref, project),
            icon: const Icon(LucideIcons.copy, size: 18),
            label: Text(l.fromTemplate),
          ),
          if (canSave)
            TextButton.icon(
              key: const Key('saveTemplate'),
              onPressed: () => saveAsTemplate(context, ref, project, tasks),
              icon: const Icon(LucideIcons.bookmarkPlus, size: 18),
              label: Text(l.saveAsTemplate),
            ),
        ],
      ),
    );
  }
}
