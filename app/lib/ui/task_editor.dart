import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/api.dart';
import '../data/chat_models.dart';
import '../data/models.dart';
import '../data/task_models.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'files_common.dart';
import 'task_format.dart';
import 'widgets.dart';

/// Whether one manages the department [departmentId] (a project's).
bool managesDepartment(
  WidgetRef ref,
  String workspaceId,
  String? departmentId,
) =>
    departmentId != null &&
    (ref
            .watch(myDepartmentsProvider(workspaceId))
            .value
            ?.containsKey(departmentId) ??
        false);

/// Whether the signed-in user leads the project, manages its department or
/// administers its workspace: they can give tasks to anyone in the project.
bool managesProject(
  WidgetRef ref,
  String workspaceId,
  List<ProjectMember>? members, {
  String? departmentId,
}) {
  final me = ref.watch(authProvider).value;
  final memberships = ref.watch(membershipsProvider).value ?? const [];
  final role = memberships
      .where((m) => m.workspaceId == workspaceId)
      .firstOrNull
      ?.role;
  if (role?.canManage ?? false) return true;
  if (managesDepartment(ref, workspaceId, departmentId)) return true;
  return members?.any((m) => m.userId == me && m.role == ProjectRole.lead) ??
      false;
}

/// Creates a task, or changes one when [existing] is given. Pops with the
/// task's id once saved.
class TaskEditorScreen extends ConsumerStatefulWidget {
  const TaskEditorScreen({
    super.key,
    required this.workspaceId,
    this.projectId,
    this.lockProject = false,
    this.existing,
    this.title,
    this.description,
    this.assigneeIds,
    this.sourceMessageId,
  });

  final String workspaceId;
  final String? projectId;

  /// From a project or a project's chat: the project is given.
  final bool lockProject;
  final TaskDetail? existing;

  /// Filled in from a chat message.
  final String? title;
  final String? description;
  final List<String>? assigneeIds;
  final String? sourceMessageId;

  @override
  ConsumerState<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends ConsumerState<TaskEditorScreen> {
  late final TaskDetail? _existing = widget.existing;
  late final _title = TextEditingController(
    text: _existing?.task.title ?? widget.title ?? '',
  );
  late final _details = TextEditingController(
    text: _existing?.description ?? widget.description ?? '',
  );
  late String? _projectId = _existing?.task.projectId ?? widget.projectId;
  late List<String> _assignees = [
    ...?_existing?.task.assignees.map((a) => a.id),
    if (_existing == null) ...?widget.assigneeIds,
  ];
  bool _assigneesPicked = false;
  late DateTime? _due = _existing?.task.dueAt?.toLocal();
  late final Set<int> _remind = {
    ...(_existing?.remindBefore ?? const [1440, 60]),
  };
  late TaskPriority _priority = _existing?.task.priority ?? TaskPriority.normal;
  late TaskVisibility _visibility =
      _existing?.task.visibility ?? TaskVisibility.private;
  late TaskRepeat? _repeat = _existing?.repeat;
  final _files = <Upload>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _details.dispose();
    super.dispose();
  }

  Future<void> _save(String? projectId, List<String> people) async {
    final title = _title.text.trim();
    if (projectId == null || title.isEmpty) return;
    final l = context.l10n;
    final api = ref.read(apiProvider);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    String? id;
    final ok = await runAction(context, () async {
      final existing = _existing;
      if (existing == null) {
        id = await api.createTask(
          TaskDraft(
            workspaceId: widget.workspaceId,
            projectId: projectId,
            title: title,
            description: _details.text.trim(),
            assigneeIds: people,
            dueAt: _due,
            priority: _priority,
            visibility: _visibility,
            remindBefore: _remind.toList()..sort(),
            sourceMessageId: widget.sourceMessageId,
          ),
        );
      } else {
        id = existing.task.id;
        await _saveChanges(api, existing, title, people);
      }
      // Repeating needs a due time.
      final repeat = _due == null ? null : _repeat;
      if (repeat != existing?.repeat) await api.setTaskRepeat(id!, repeat);
    });
    // Once the task exists it opens, even when a file fails to attach, so
    // saving again can't make it twice.
    var attached = true;
    if (ok) {
      for (final file in _files) {
        try {
          await api.addTaskAttachment(widget.workspaceId, id!, file);
        } catch (_) {
          attached = false;
        }
      }
    }
    if (!attached) {
      messenger.showSnackBar(SnackBar(content: Text(l.filesNotAttached)));
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    refreshTasks(ref);
    navigator.pop(id);
  }

  /// Applies only what was changed here to the task as it is now, so
  /// someone else's change made meanwhile stays.
  Future<void> _saveChanges(
    WaslaApi api,
    TaskDetail before,
    String title,
    List<String> people,
  ) async {
    final now = await api.task(before.task.id);
    final details = _details.text.trim();
    final remind = _remind.toList()..sort();
    await api.updateTask(
      before.task.id,
      TaskDraft(
        workspaceId: widget.workspaceId,
        projectId: now.task.projectId,
        title: title == before.task.title ? now.task.title : title,
        description: details == (before.description ?? '')
            ? now.description
            : details,
        dueAt: _sameTime(_due, before.task.dueAt) ? now.task.dueAt : _due,
        priority: _priority == before.task.priority
            ? now.task.priority
            : _priority,
        visibility: _visibility == before.task.visibility
            ? now.task.visibility
            : _visibility,
        remindBefore: _sameSet(remind, before.remindBefore)
            ? now.remindBefore
            : remind,
      ),
    );
    if (!_assigneesPicked) return;
    final was = {for (final a in before.task.assignees) a.id};
    final current = {for (final a in now.task.assignees) a.id};
    final wanted = {
      ...current.where((id) => !was.contains(id) || people.contains(id)),
      ...people.where((id) => !was.contains(id)),
    };
    if (!_sameSet(wanted, current)) {
      await api.setTaskAssignees(before.task.id, wanted.toList());
    }
  }

  Future<void> _pickAssignees(List<TaskPerson> people) async {
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssigneeSheet(people: people, selected: _assignees),
    );
    if (picked == null || _sameSet(picked, _assignees)) return;
    setState(() {
      _assignees = picked;
      _assigneesPicked = true;
    });
  }

  Future<void> _pickDue() async {
    final picked = await pickDateTime(context, initial: _due);
    if (picked == null) return;
    setState(() {
      // A first due date gets the usual reminders, unless some are chosen.
      if (_due == null && _remind.isEmpty) _remind.addAll(const [1440, 60]);
      _due = picked;
    });
  }

  Future<void> _pickRepeat() async {
    final l = context.l10n;
    final picked = await showModalBottomSheet<(TaskRepeat?,)>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in <TaskRepeat?>[null, ...TaskRepeat.values])
              ListTile(
                title: Text(repeatLabel(l, r)),
                trailing: r == _repeat ? const Icon(LucideIcons.check) : null,
                onTap: () => Navigator.pop(context, (r,)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                l.repeatHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _repeat = picked.$1);
  }

  Future<void> _attach() async {
    final files = await pickUploads(context, ref);
    if (files.isNotEmpty && mounted) setState(() => _files.addAll(files));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final me = ref.watch(authProvider).value ?? '';
    final ws = widget.workspaceId;
    final projects = [
      for (final p
          in ref.watch(projectsProvider(ws)).value ?? const <Project>[])
        if (p.status == ProjectStatus.active) p,
    ];
    // With a single project to choose from, it is chosen.
    final projectId =
        _projectId ?? (projects.length == 1 ? projects.single.id : null);
    final members = projectId == null
        ? null
        : ref.watch(projectMembersProvider(projectId)).value;
    final existing = _existing;
    final manager =
        existing?.canAssign ??
        managesProject(
          ref,
          ws,
          members,
          departmentId: projects
              .where((p) => p.id == projectId)
              .firstOrNull
              ?.departmentId,
        );
    final names = {
      for (final a in existing?.task.assignees ?? const <TaskPerson>[])
        a.id: a.name,
      for (final m in members ?? const <ProjectMember>[]) m.userId: m.fullName,
    };
    // Someone who doesn't lead the project makes tasks only for themselves,
    // and leaves an existing task's people as they are.
    final people = _assignees.isNotEmpty && (manager || existing != null)
        ? _assignees
        : [me];
    // The project's members, and anyone on the task who has since left it.
    final choices = [
      for (final m in members ?? const <ProjectMember>[])
        TaskPerson(id: m.userId, name: m.fullName),
      for (final id in _assignees)
        if (!(members?.any((m) => m.userId == id) ?? false))
          TaskPerson(id: id, name: names[id] ?? '…'),
    ];
    final canSave =
        !_saving && projectId != null && _title.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? l.newTask : l.editTask),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: FilledButton(
              onPressed: canSave ? () => _save(projectId, people) : null,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Text(_existing == null ? l.create : l.save),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _title,
            autofocus: _existing == null && widget.title == null,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: const [RuneLimit(200)],
            decoration: InputDecoration(labelText: l.taskTitleLabel),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _details,
            minLines: 2,
            maxLines: 6,
            inputFormatters: const [RuneLimit(4000)],
            decoration: InputDecoration(labelText: l.taskDetailsLabel),
          ),
          const SizedBox(height: 12),
          if (_existing == null && !widget.lockProject)
            DropdownButtonFormField<String>(
              initialValue: projects.any((p) => p.id == projectId)
                  ? projectId
                  : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: l.projectLabel),
              hint: Text(l.pickProject),
              items: [
                for (final p in projects)
                  DropdownMenuItem(
                    value: p.id,
                    child: Row(
                      children: [
                        ColorDot(hex: p.color),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (id) => setState(() {
                _projectId = id;
                // People from the old project may not be in the new one.
                _assignees = [];
              }),
            ),
          if (_existing == null && !widget.lockProject)
            const SizedBox(height: 12),
          TileGroup(
            children: [
              ListTile(
                leading: const Icon(LucideIcons.user),
                title: Text(l.assigneesLabel),
                subtitle: Text(
                  joinNames(context, [
                    for (final id in people)
                      id == me ? l.you : names[id] ?? '…',
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: manager
                    ? const Icon(LucideIcons.chevronRightDir)
                    : null,
                onTap: manager && members != null
                    ? () => _pickAssignees(choices)
                    : null,
              ),
              ListTile(
                leading: const Icon(LucideIcons.calendar),
                title: Text(l.dueLabel),
                subtitle: Text(
                  _due == null ? l.setDue : dueFull(context, _due!),
                ),
                trailing: _due == null
                    ? null
                    : IconButton(
                        tooltip: l.clearDue,
                        icon: const Icon(LucideIcons.x),
                        onPressed: () => setState(() {
                          _due = null;
                          _repeat = null;
                        }),
                      ),
                onTap: _pickDue,
              ),
              if (_due != null)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 12),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.bell,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final (minutes, label) in [
                              (1440, l.remindDayBefore),
                              (60, l.remindHourBefore),
                            ])
                              FilterChip(
                                label: Text(label),
                                selected: _remind.contains(minutes),
                                onSelected: (on) => setState(
                                  () => on
                                      ? _remind.add(minutes)
                                      : _remind.remove(minutes),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ListTile(
                key: const Key('repeatTile'),
                leading: const Icon(LucideIcons.repeat),
                title: Text(l.repeatLabel),
                subtitle: Text(
                  _due == null ? l.repeatNeedsDue : repeatLabel(l, _repeat),
                ),
                enabled: _due != null,
                trailing: _due == null
                    ? null
                    : const Icon(LucideIcons.chevronDown),
                onTap: _due == null ? null : _pickRepeat,
              ),
            ],
          ),
          if (!manager && existing == null && members != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                l.onlyYourself,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          SectionTitle(l.priorityLabel),
          SegmentedButton<TaskPriority>(
            showSelectedIcon: false,
            segments: [
              for (final p in TaskPriority.values)
                ButtonSegment(value: p, label: Text(priorityLabel(l, p))),
            ],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              title: Text(l.publicTask),
              subtitle: Text(
                _visibility == TaskVisibility.public
                    ? l.publicTaskHint
                    : l.privateTaskHint,
              ),
              value: _visibility == TaskVisibility.public,
              onChanged: (on) => setState(
                () => _visibility = on
                    ? TaskVisibility.public
                    : TaskVisibility.private,
              ),
            ),
          ),
          if (_existing == null) ...[
            SectionTitle(l.attachments),
            for (final f in _files)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(LucideIcons.file),
                title: Text(f.name, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: l.remove,
                  icon: const Icon(LucideIcons.x),
                  onPressed: () => setState(() => _files.remove(f)),
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _attach,
                icon: const Icon(LucideIcons.paperclip),
                label: Text(l.attach),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AssigneeSheet extends StatefulWidget {
  const _AssigneeSheet({required this.people, required this.selected});

  final List<TaskPerson> people;
  final List<String> selected;

  @override
  State<_AssigneeSheet> createState() => _AssigneeSheetState();
}

class _AssigneeSheetState extends State<_AssigneeSheet> {
  late final _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.pickAssignees,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, [
                      for (final p in widget.people)
                        if (_picked.contains(p.id)) p.id,
                    ]),
                    child: Text(l.save),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final p in widget.people)
                    CheckboxListTile(
                      value: _picked.contains(p.id),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _picked.add(p.id)
                            : _picked.remove(p.id),
                      ),
                      secondary: Avatar(name: p.name),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _sameTime(DateTime? a, DateTime? b) =>
    a == null || b == null ? a == b : a.isAtSameMomentAs(b);

bool _sameSet<T>(Iterable<T> a, Iterable<T> b) {
  final x = a.toSet();
  final y = b.toSet();
  return x.length == y.length && x.containsAll(y);
}
