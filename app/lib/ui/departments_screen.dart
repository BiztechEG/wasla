import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'widgets.dart';

/// A workspace's departments, for its owners and admins: each a group of
/// projects with the people who manage them.
class DepartmentsScreen extends ConsumerWidget {
  const DepartmentsScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final ws = membership.workspaceId;
    final departments = ref.watch(departmentsProvider(ws));
    final members = {
      for (final m in ref.watch(membersProvider(ws)).value ?? const <Member>[])
        m.userId: m.fullName,
    };

    Future<void> edit([Department? d]) async {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              _DepartmentEditor(membership: membership, existing: d),
        ),
      );
      ref
        ..invalidate(departmentsProvider(ws))
        ..invalidate(projectsProvider(ws));
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.departmentsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('newDepartment'),
        icon: const Icon(LucideIcons.plus),
        label: Text(l.newDepartment),
        onPressed: edit,
      ),
      body: AsyncView(
        value: departments,
        onRetry: () => ref.invalidate(departmentsProvider(ws)),
        builder: (all) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            Text(
              l.departmentsHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (all.isEmpty)
              EmptyState(
                icon: LucideIcons.building2,
                title: l.departmentsEmpty,
                action: EmptyAction(
                  icon: LucideIcons.plus,
                  label: l.newDepartment,
                  onPressed: edit,
                ),
              )
            else
              TileGroup(
                children: [
                  for (final d in all)
                    ListTile(
                      key: Key('department-${d.name}'),
                      leading: const Icon(LucideIcons.building2),
                      title: Text(d.name),
                      subtitle: Text(
                        [
                          l.departmentProjects(d.projectIds.length),
                          if (d.managerIds.isEmpty)
                            l.noDepartmentManager
                          else
                            d.managerIds
                                .map((id) => members[id] ?? '')
                                .where((n) => n.isNotEmpty)
                                .join('، '),
                        ].join(' · '),
                      ),
                      trailing: const Icon(LucideIcons.chevronRightDir),
                      onTap: () => edit(d),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Makes or changes a department: its name, managers and projects.
class _DepartmentEditor extends ConsumerStatefulWidget {
  const _DepartmentEditor({required this.membership, this.existing});

  final Membership membership;
  final Department? existing;

  @override
  ConsumerState<_DepartmentEditor> createState() => _DepartmentEditorState();
}

class _DepartmentEditorState extends ConsumerState<_DepartmentEditor> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final Set<String> _managers = {...?widget.existing?.managerIds};
  late final Set<String> _projects = {...?widget.existing?.projectIds};

  String get _ws => widget.membership.workspaceId;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    final name = _name.text.trim();
    if (name.isEmpty) {
      showMessage(context, l.fieldRequired);
      return;
    }
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .saveDepartment(
            _ws,
            departmentId: widget.existing?.id,
            name: name,
            managerIds: _managers.toList(),
            projectIds: _projects.toList(),
          ),
    );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final l = context.l10n;
    if (!await confirm(
      context,
      message: l.deleteDepartmentConfirm,
      action: l.delete,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).deleteDepartment(widget.existing!.id),
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final members = ref.watch(membersProvider(_ws)).value ?? const <Member>[];
    final projects = [
      for (final p
          in ref.watch(projectsProvider(_ws)).value ?? const <Project>[])
        if (p.status != ProjectStatus.archived) p,
    ];
    final departments = {
      for (final d
          in ref.watch(departmentsProvider(_ws)).value ?? const <Department>[])
        d.id: d.name,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? l.newDepartment : widget.existing!.name,
        ),
        actions: [
          if (widget.existing != null)
            IconButton(
              key: const Key('deleteDepartment'),
              tooltip: l.delete,
              icon: const Icon(LucideIcons.trash2),
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            key: const Key('departmentName'),
            controller: _name,
            maxLength: 80,
            decoration: InputDecoration(labelText: l.departmentName),
          ),
          SectionTitle(l.departmentManagers),
          Text(l.departmentManagersHint),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in members)
                FilterChip(
                  key: Key('manager-${m.userId}'),
                  avatar: Avatar(name: m.fullName, radius: 12),
                  label: Text(m.fullName),
                  selected: _managers.contains(m.userId),
                  onSelected: (on) => setState(
                    () => on
                        ? _managers.add(m.userId)
                        : _managers.remove(m.userId),
                  ),
                ),
            ],
          ),
          SectionTitle(l.departmentProjectsTitle),
          TileGroup(
            children: [
              for (final p in projects)
                CheckboxListTile(
                  key: Key('deptProject-${p.name}'),
                  value: _projects.contains(p.id),
                  onChanged: (on) => setState(
                    () => on ?? false
                        ? _projects.add(p.id)
                        : _projects.remove(p.id),
                  ),
                  secondary: ColorDot(hex: p.color),
                  title: Text(p.name),
                  // Ticking it moves it from the department it is in.
                  subtitle:
                      p.departmentId != null &&
                          p.departmentId != widget.existing?.id &&
                          departments[p.departmentId] != null
                      ? Text(l.inDepartment(departments[p.departmentId]!))
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('saveDepartment'),
            onPressed: _save,
            child: Text(l.save),
          ),
        ],
      ),
    );
  }
}
