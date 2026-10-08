import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../theme.dart';
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

    return Scaffold(
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              heroTag: 'newProject',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => NewProjectSheet(workspaceId: ws),
              ),
              icon: const Icon(Icons.add),
              label: Text(l.newProject),
            )
          : null,
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                for (final (status, label) in [
                  (ProjectStatus.active, l.filterActive),
                  (ProjectStatus.archived, l.filterArchived),
                  (ProjectStatus.closed, l.filterClosed),
                ])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _filter == status,
                      onSelected: (_) => setState(() => _filter = status),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncView(
              value: projects,
              onRetry: () => ref.invalidate(projectsProvider(ws)),
              builder: (all) {
                final shown = all.where((p) => p.status == _filter).toList();
                return RefreshIndicator(
                  onRefresh: () => ref.refresh(projectsProvider(ws).future),
                  child: shown.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 60),
                            EmptyState(
                              icon: Icons.folder_open_outlined,
                              title: l.projectsEmpty,
                              body: _filter != ProjectStatus.active
                                  ? null
                                  : canManage
                                  ? l.projectsEmptyAdmin
                                  : l.projectsEmptyMember,
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) =>
                              _ProjectCard(project: shown[i]),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final color = WaslaColors.project(project.color, theme.brightness);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ProjectScreen(project: project),
          ),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: color.withValues(alpha: 0.14),
                        child: Icon(Icons.folder_outlined, color: color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              project.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              l.memberCount(project.memberCount),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
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
                                      ? const Color(0xFF0F1419)
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
