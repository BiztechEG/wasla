import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/google.dart';
import '../data/task_models.dart';
import 'settings.dart';

final googleAccountProvider = Provider<GoogleAccount>(
  (ref) => GoogleApiAccount(),
);

/// The calendar event made for a task, and what it showed.
class LinkedEvent {
  const LinkedEvent(this.id, this.stamp);

  final String id;
  final String stamp;
}

class CalendarState {
  const CalendarState({required this.auto, required this.events});

  /// Every task with a due date goes to the calendar on its own.
  final bool auto;

  /// Task id -> its event. Kept on this device.
  final Map<String, LinkedEvent> events;
}

/// A task's place in the calendar: an hour ending at its due time.
CalendarEvent taskEvent(TaskItem task) => CalendarEvent(
  title: task.title,
  details: '${task.projectName} · ${task.workspaceName}\n\nWasla',
  start: task.dueAt!.subtract(const Duration(hours: 1)),
  end: task.dueAt!,
);

bool _belongs(TaskItem t) => t.status.isOpen && t.dueAt != null;

/// Tasks in the person's Google Calendar. Events follow their tasks: they
/// move with the due date and go when the task is done or cancelled.
class CalendarNotifier extends Notifier<CalendarState> {
  static const _autoKey = 'gcal.auto';
  static const _eventsKey = 'gcal.events';

  bool _syncing = false;

  GoogleAccount get _google => ref.read(googleAccountProvider);

  @override
  CalendarState build() {
    final prefs = ref.watch(prefsProvider);
    final raw = prefs.getString(_eventsKey);
    final events = <String, LinkedEvent>{};
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          final e = v as List<dynamic>;
          events[k] = LinkedEvent(e[0] as String, e[1] as String);
        });
      } catch (_) {}
    }
    return CalendarState(
      auto: prefs.getBool(_autoKey) ?? false,
      events: events,
    );
  }

  Future<void> _save(CalendarState next) async {
    state = next;
    final prefs = ref.read(prefsProvider);
    await prefs.setBool(_autoKey, next.auto);
    await prefs.setString(
      _eventsKey,
      jsonEncode({
        for (final e in next.events.entries) e.key: [e.value.id, e.value.stamp],
      }),
    );
  }

  Future<void> _put(TaskItem task) async {
    final event = taskEvent(task);
    final id = await _google.putEvent(
      event,
      eventId: state.events[task.id]?.id,
    );
    await _save(
      CalendarState(
        auto: state.auto,
        events: {...state.events, task.id: LinkedEvent(id, event.stamp)},
      ),
    );
  }

  Future<void> _drop(String taskId) async {
    final linked = state.events[taskId];
    if (linked == null) return;
    await _google.deleteEvent(linked.id);
    await _save(
      CalendarState(
        auto: state.auto,
        events: {...state.events}..remove(taskId),
      ),
    );
  }

  /// Adds one task (asks for access the first time).
  Future<void> add(TaskItem task) async {
    if (!await _google.connect([calendarScope])) {
      throw const GoogleNotConnected();
    }
    await _put(task);
  }

  Future<void> remove(String taskId) => _drop(taskId);

  /// Turning it on asks for access and adds the tasks at once.
  Future<bool> setAuto(bool on, List<TaskItem> tasks) async {
    if (on && !await _google.connect([calendarScope])) return false;
    await _save(CalendarState(auto: on, events: state.events));
    if (on) await sync(tasks);
    return true;
  }

  /// Brings the calendar in line with [tasks] (the person's own), quietly:
  /// without access nothing happens.
  Future<void> sync(List<TaskItem> tasks) async {
    if (_syncing || (!state.auto && state.events.isEmpty)) return;
    if (!await _google.hasAccess([calendarScope])) return;
    _syncing = true;
    try {
      for (final task in tasks) {
        final linked = state.events[task.id];
        if (_belongs(task)) {
          if (linked == null && !state.auto) continue;
          if (linked?.stamp == taskEvent(task).stamp) continue;
          await _put(task);
        } else if (linked != null) {
          await _drop(task.id);
        }
      }
    } catch (_) {
      // Next time, then.
    } finally {
      _syncing = false;
    }
  }

  /// Forgets the calendar on this device; events already made stay.
  Future<void> forget() => _save(const CalendarState(auto: false, events: {}));
}

final calendarProvider = NotifierProvider<CalendarNotifier, CalendarState>(
  CalendarNotifier.new,
);
