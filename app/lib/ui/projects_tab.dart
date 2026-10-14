import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../data/task_models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'modern.dart';
import 'project_screen.dart';
import 'widgets.dart';

class ProjectsTab extends ConsumerStatefulWidget {
  const ProjectsTab({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends ConsumerState<ProjectsTab> {
  ProjectStatus _filter = ProjectStatus.active;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final ws = widget.membership.workspaceId;
    final canManage = widget.membership.role.canManage;
    final projects = ref.watch(projectsProvider(ws));

    return FabScaffold(
      fab: canManage
          ? WaslaFab(
              icon: LucideIcons.plus,
              tooltip: l.newProject,
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => NewProjectSheet(workspaceId: ws),
              ),
            )
          : null,
      body: AsyncView(
        value: projects,
        onRetry: () => ref.invalidate(projectsProvider(ws)),
        builder: (all) {
          final shown = all.where((p) => p.status == _filter).toList();
          return RefreshIndicator(
            onRefresh: () {
              ref.invalidate(projectProgressProvider(ws));
              return ref.refresh(projectsProvider(ws).future);
            },
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                4,
                16,
                navClearance(context) + 80,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (status, label) in [
                        (ProjectStatus.active, l.filterActive),
                        (ProjectStatus.archived, l.filterArchived),
                        (ProjectStatus.closed, l.filterClosed),
                      ])
                        FilterPill(
                          label: label,
                          selected: _filter == status,
                          onTap: () => setState(() => _filter = status),
                        ),
                    ],
                  ),
                ),
                if (shown.isEmpty) ...[
                  const SizedBox(height: 40),
                  EmptyState(
                    icon: LucideIcons.folderOpen,
                    title: l.projectsEmpty,
                    body: _filter != ProjectStatus.active
                        ? null
                        : canManage
                        ? l.projectsEmptyAdmin
                        : l.projectsEmptyMember,
                  ),
                ],
                for (final p in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ProjectCard(project: p),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ProjectCard extends ConsumerWidget {
  const _ProjectCard({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = WaslaColors.project(project.color, theme.brightness);
    final progress =
        ref
            .watch(projectProgressProvider(project.workspaceId))
            .value?[project.id] ??
        const ProjectProgress();
    final unread =
        (ref.watch(conversationsProvider(project.workspaceId)).value ??
                const [])
            .where((c) => c.isProject && c.projectId == project.id)
            .fold(0, (sum, c) => sum + c.unread);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontSize: 13,
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ProjectScreen(project: project),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ProjectAvatar(
                    name: project.name,
                    hex: project.color,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        Text(l.memberCount(project.memberCount), style: muted),
                      ],
                    ),
                  ),
                  if (unread > 0)
                    _Pill(
                      icon: LucideIcons.messageCircle,
                      text: l.newMessagesCount(unread),
                      color: scheme.primary,
                      background: scheme.primaryContainer,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      progress.total == 0
                          ? l.noTasksYet
                          : l.tasksDoneOf(progress.done, progress.total),
                      style: muted,
                    ),
                  ),
                  if (progress.total > 0)
                    Text(
                      '${(progress.fraction * 100).round()}%',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress.fraction,
                  minHeight: 6,
                  color: color,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              if (progress.late > 0) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _Pill(
                    text: l.lateTasks(progress.late),
                    color: scheme.error,
                    background: scheme.errorContainer,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small rounded label on a project card.
class _Pill extends StatelessWidget {
  const _Pill({
    this.icon,
    required this.text,
    required this.color,
    required this.background,
  });

  final IconData? icon;
  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class NewProjectSheet extends ConsumerStatefulWidget {
  const NewProjectSheet({super.key, required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends ConsumerState<NewProjectSheet> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  String _color = WaslaColors.projectColors.first;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .createProject(
            widget.workspaceId,
            name: _name.text.trim(),
            color: _color,
          ),
    );
    if (ok && mounted) {
      ref.invalidate(projectsProvider(widget.workspaceId));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.newProject,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('projectName'),
                controller: _name,
                inputFormatters: nameLimit,
                autofocus: true,
                decoration: InputDecoration(labelText: l.projectNameLabel),
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? l.fieldRequired : null,
                onFieldSubmitted: (_) => _create(),
              ),
              const SizedBox(height: 16),
              Text(l.projectColorLabel, style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final hex in WaslaColors.projectColors)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 12),
                      child: InkResponse(
                        onTap: () => setState(() => _color = hex),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: WaslaColors.project(hex, theme.brightness),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _color == hex
                                  ? theme.colorScheme.onSurface
                                  : Colors.transparent,
                              width: 3,
                            ),
                          ),
                          child: _color == hex
                              ? Icon(
                                  Icons.check,
                                  color: theme.brightness == Brightness.dark
                                      ? Colors.black
                                      : Colors.white,
                                )
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              BusyButton(label: l.create, onPressed: _create),
            ],
          ),
        ),
      ),
    );
  }
}
