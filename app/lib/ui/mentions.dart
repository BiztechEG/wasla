// @mentions: suggesting people while typing, finding who a message names,
// and drawing the names in it.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'widgets.dart';

/// Someone who can be mentioned in a chat; [id] null for "@everyone".
class MentionCandidate {
  const MentionCandidate({required this.id, required this.name});

  final String? id;
  final String name;

  bool get everyone => id == null;
}

/// The words that mention everyone in a project's chat, in both languages.
const everyoneWords = ['الكل', 'all'];

/// Letters folded so "احمد" finds "أحمد" and "Sara" finds "sara".
String _fold(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[أإآ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي');

/// The "@..." being typed just before the cursor, if any: where its "@" is
/// and what follows it.
({int start, String query})? mentionQuery(TextEditingValue value) {
  final sel = value.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final before = value.text.substring(0, sel.baseOffset);
  final at = before.lastIndexOf('@');
  if (at < 0) return null;
  if (at > 0 && !RegExp(r'\s').hasMatch(before[at - 1])) return null;
  final query = before.substring(at + 1);
  // A space after a name ends it (as after picking someone).
  if (query.length > 25 ||
      query.contains('\n') ||
      query.startsWith(' ') ||
      query.endsWith(' ')) {
    return null;
  }
  return (start: at, query: query);
}

/// Candidates whose name (or any word of it) starts with [query].
List<MentionCandidate> matchMentions(List<MentionCandidate> all, String query) {
  final q = _fold(query.trim());
  if (q.isEmpty) return all;
  return [
    for (final c in all)
      if (_fold(c.name).startsWith(q) ||
          _fold(c.name).split(' ').any((w) => w.startsWith(q)) ||
          (c.everyone && everyoneWords.any((w) => _fold(w).startsWith(q))))
        c,
  ];
}

/// [value] with the "@..." at [start] replaced by "@name ".
TextEditingValue applyMention(TextEditingValue value, int start, String name) {
  final end = value.selection.baseOffset;
  final insert = '@$name ';
  final text = value.text.replaceRange(start, end, insert);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: start + insert.length),
  );
}

RegExp _named(String name) =>
    RegExp('@${RegExp.escape(name)}(?![\\p{L}\\p{N}])', unicode: true);

/// Where each of [items] (by its name) is mentioned in [text], in order;
/// where two overlap the longer wins ("@Ali Hassan" over "@Ali").
List<(int start, int end, T item)> _find<T>(
  String text,
  Iterable<T> items,
  String Function(T) nameOf,
) {
  final found = <(int, int, T)>[
    for (final item in items)
      for (final m in _named(nameOf(item)).allMatches(text))
        (m.start, m.end, item),
  ];
  found.sort(
    (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : b.$2.compareTo(a.$2),
  );
  final kept = <(int, int, T)>[];
  var at = 0;
  for (final f in found) {
    if (f.$1 < at) continue;
    kept.add(f);
    at = f.$2;
  }
  return kept;
}

/// The people [text] mentions among [candidates]; "@everyone" means all of
/// them.
List<String> mentionedIds(String text, List<MentionCandidate> candidates) {
  final people = [
    for (final c in candidates)
      if (!c.everyone) c,
  ];
  final found = _find(text, people, (c) => c.name);
  if (candidates.any((c) => c.everyone) &&
      everyoneWords.any((w) => _named(w).hasMatch(text))) {
    return [for (final c in people) c.id!];
  }
  return {for (final (_, _, c) in found) c.id!}.toList();
}

/// A name a message mentions, to draw it; [id] null for "@everyone".
class MentionTarget {
  const MentionTarget({required this.name, this.id, this.me = false});

  final String name;
  final String? id;

  /// It is the signed-in user (or everyone, them included).
  final bool me;
}

/// The names a message with [mentions] (user ids) draws, from [names]
/// (user id to name).
List<MentionTarget> mentionTargets(
  List<String> mentions,
  Map<String, String> names,
  String? me,
) => [
  if (mentions.isNotEmpty)
    for (final w in everyoneWords)
      MentionTarget(name: w, me: mentions.contains(me)),
  for (final id in mentions)
    if (names[id] case final name? when name.isNotEmpty)
      MentionTarget(name: name, id: id, me: id == me),
];

/// [text] in spans, with the mentions in it drawn and (for people)
/// tappable. The recognizers are added to [recognizers], for the caller to
/// dispose.
List<InlineSpan> mentionSpans(
  BuildContext context,
  String text,
  List<MentionTarget> targets, {
  required List<GestureRecognizer> recognizers,
  required void Function(MentionTarget) onTap,
}) {
  final found = _find(text, targets, (t) => t.name);
  if (found.isEmpty) return [TextSpan(text: text)];
  final theme = Theme.of(context);
  final link = theme.colorScheme.primary;
  final spans = <InlineSpan>[];
  var at = 0;
  for (final (start, end, t) in found) {
    if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
    TapGestureRecognizer? tap;
    if (t.id != null) {
      tap = TapGestureRecognizer()..onTap = () => onTap(t);
      recognizers.add(tap);
    }
    spans.add(
      TextSpan(
        text: text.substring(start, end),
        recognizer: tap,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: t.me ? null : link,
          backgroundColor: t.me
              ? WaslaMentionColors.of(theme.brightness)
              : null,
        ),
      ),
    );
    at = end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return spans;
}

/// The warm tint behind a mention of oneself.
abstract final class WaslaMentionColors {
  static Color of(Brightness b) =>
      b == Brightness.dark ? const Color(0x66F0A35E) : const Color(0x59F0A35E);
}

/// The list of people to mention, over the message field.
class MentionSuggestions extends StatelessWidget {
  const MentionSuggestions({
    super.key,
    required this.choices,
    required this.memberCount,
    required this.onPick,
  });

  final List<MentionCandidate> choices;
  final int memberCount;
  final void Function(MentionCandidate) onPick;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 4,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 232),
          child: ListView(
            key: const Key('mentionSuggestions'),
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final c in choices)
                ListTile(
                  key: Key('mention-${c.id ?? 'everyone'}'),
                  dense: true,
                  leading: c.everyone
                      ? CircleAvatar(
                          radius: 16,
                          backgroundColor: theme.colorScheme.primaryContainer,
                          child: Text(
                            '@',
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : Avatar(name: c.name, radius: 16),
                  title: Text(
                    c.everyone ? '@${l.mentionEveryone}' : c.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: c.everyone
                      ? Text(l.memberCount(memberCount))
                      : null,
                  onTap: () => onPick(c),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
