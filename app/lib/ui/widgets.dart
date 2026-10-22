import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/google.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import '../theme.dart';

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// Keeps text within [max] characters as the database counts them (code
/// points, so an emoji made of several counts as several), cutting only
/// between whole characters.
class RuneLimit extends TextInputFormatter {
  const RuneLimit(this.max);

  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= max) return newValue;
    final kept = StringBuffer();
    var count = 0;
    for (final c in newValue.text.characters) {
      count += c.runes.length;
      if (count > max) break;
      kept.write(c);
    }
    final text = kept.toString();
    final selection = newValue.selection;
    return TextEditingValue(
      text: text,
      selection: selection.isValid
          ? selection.copyWith(
              baseOffset: selection.baseOffset.clamp(0, text.length),
              extentOffset: selection.extentOffset.clamp(0, text.length),
            )
          : selection,
    );
  }
}

/// Same limits as the database, so people never hit them as an error.
const nameLimit = [RuneLimit(100)];
const messageLimit = [RuneLimit(500)];

/// Names in a list, with the comma the language uses.
String joinNames(BuildContext context, Iterable<String> names) => names.join(
  Localizations.localeOf(context).languageCode == 'ar' ? '، ' : ', ',
);

/// Keeps an email or phone number reading left to right inside Arabic text.
String ltr(String text) => '\u2066$text\u2069';

/// One line of left-to-right text (an email, a phone number). When it is too
/// long it keeps its beginning and trails off at its own end.
class LtrLine extends StatelessWidget {
  const LtrLine(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: style,
    textDirection: TextDirection.ltr,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

String roleLabel(AppLocalizations l, WorkspaceRole role) => switch (role) {
  WorkspaceRole.owner => l.roleOwner,
  WorkspaceRole.admin => l.roleAdmin,
  WorkspaceRole.member => l.roleMember,
};

/// Turns backend errors into something a person can act on.
String errorText(AppLocalizations l, Object error) {
  if (error is GoogleNotConnected) return l.googleNotConnected;
  if (error is AuthException) {
    if (error is AuthRetryableFetchException) return l.errorNetwork;
    if (error.code == 'over_email_send_rate_limit' ||
        error.statusCode == '429') {
      return l.errorTooManyCodes;
    }
    if (error.code == 'otp_expired' || error.statusCode == '403') {
      return l.errorWrongCode;
    }
    return l.errorGeneric;
  }
  if (error is PostgrestException) {
    final m = error.message;
    if (m.contains('attendance_off')) return l.errorAttendanceOff;
    if (m.contains('already_checked_in')) return l.errorAlreadyCheckedIn;
    if (m.contains('not_checked_in')) return l.errorNotCheckedIn;
    if (m.contains('selfie_required')) return l.errorSelfieRequired;
    if (m.contains('outside_not_allowed')) return l.errorOutsideNotAllowed;
    if (m.contains('attendance_reason_required')) return l.errorOutsideReason;
    if (m.contains('location_required')) return l.errorLocationRequired;
    if (m.contains('invalid_hours')) return l.errorInvalidHours;
    if (m.contains('future_time')) return l.errorFutureTime;
    if (m.contains('too_old')) return l.errorTooOld;
    if (m.contains('workers_limit')) return l.errorWorkersLimit;
    if (m.contains('fix_pending')) return l.errorFixPending;
    if (m.contains('fix_note_required')) return l.errorFixNote;
    if (m.contains('fix_needs_check_in')) return l.errorFixNeedsCheckIn;
    if (m.contains('already_reviewed')) return l.errorAlreadyReviewed;
    if (m.contains('seat_limit_reached')) return l.errorSeatLimit;
    if (m.contains('last_owner')) return l.errorLastOwner;
    if (m.contains('name_mismatch')) return l.errorNameMismatch;
    if (m.contains('invite_invalid')) return l.errorInviteInvalid;
    if (m.contains('invite_not_for_you')) return l.errorInviteNotForYou;
    if (m.contains('already_member')) return l.errorAlreadyMember;
    if (m.contains('code_invalid')) return l.errorCodeInvalid;
    if (m.contains('too_many_assignees')) return l.errorTooManyAssignees;
    if (m.contains('too_many_reminders')) return l.errorTooManyReminders;
    if (m.contains('too_many_')) return l.errorTooMany;
    if (m.contains('project_closed')) return l.errorProjectClosed;
    if (m.contains('reason_required')) return l.errorReasonRequired;
    if (m.contains('invalid_assignee')) return l.errorInvalidAssignee;
    if (m.contains('invalid_reminder')) return l.errorInvalidReminder;
    if (m.contains('invalid_plan')) return l.errorInvalidPlan;
    if (m.contains('invalid_price')) return l.errorInvalidPrice;
    if (m.contains('invalid_rate')) return l.errorInvalidRate;
    if (m.contains('invalid_status')) return l.errorInvoiceChanged;
    if (m.contains('invalid_date')) return l.errorInvalidDate;
    if (m.contains('invalid_items') ||
        m.contains('invalid_months') ||
        m.contains('invalid_discount')) {
      return l.errorInvalidInvoice;
    }
    if (m == 'not_found') return l.errorTaskGone;
    if (m.contains('invalid_project')) return l.errorInvalidProject;
    if (m.contains('conversation_closed')) return l.errorChatClosed;
    if (m.contains('storage_full')) return l.errorStorageFull;
    if (m.contains('file_too_large')) return l.fileTooLarge;
    if (m.contains('not_allowed') ||
        m.contains('not_company_owner') ||
        error.code == '42501') {
      return l.errorNotAllowed;
    }
    if (error.code == '23505') return l.errorDuplicate;
    if (error.code == '23514') return l.errorTooLong;
    return l.errorGeneric;
  }
  if (error is StorageException) {
    if (error.statusCode == '413') return l.fileTooLarge;
    // The upload rules: the plan's storage, or today's upload allowance.
    if (error.statusCode == '403' || error.statusCode == '400') {
      return l.errorUploadRefused;
    }
  }
  final text = error.toString();
  if (error is TimeoutException ||
      text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('Failed host lookup')) {
    return l.errorNetwork;
  }
  return l.errorGeneric;
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Runs a change, shows what went wrong if it fails, and returns whether it
/// worked.
Future<bool> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? done,
}) async {
  final l = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    if (done != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(done)));
    }
    return true;
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(errorText(l, e))));
    return false;
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String message,
  required String action,
  bool destructive = false,
}) async {
  final l = context.l10n;
  final scheme = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: destructive
              ? TextButton.styleFrom(foregroundColor: scheme.error)
              : null,
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks for one line of text; returns null when cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? action,
  int maxLength = 100,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PromptDialog(
    title: title,
    label: label,
    initial: initial,
    action: action,
    maxLength: maxLength,
  ),
);

/// Owns its text field's controller, so the field outlives the dialog's
/// closing animation.
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.action,
    required this.maxLength,
  });

  final String title;
  final String label;
  final String initial;
  final String? action;
  final int maxLength;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        inputFormatters: [RuneLimit(widget.maxLength)],
        decoration: InputDecoration(labelText: widget.label),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(widget.action ?? l.save)),
      ],
    );
  }
}

/// Shows loading, error (with retry) or the data of an async value.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.onRetry,
    required this.builder,
  });

  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) {
    // A failed refresh keeps showing what was loaded before.
    return value.when(
      skipError: true,
      data: builder,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorView(error: error, onRetry: onRetry),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(errorText(l, error), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: Text(l.retry)),
          ],
        ),
      ),
    );
  }
}

/// Wasla's logo: the one set from the admin dashboard, or the built-in mark
/// while it loads, when none is set or when it cannot be fetched.
class BrandLogo extends ConsumerWidget {
  const BrandLogo({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(logoUrlProvider).value;
    final radius = BorderRadius.circular(size * 0.28);
    final fallback = BuiltInLogo(size: size);
    if (url == null) return fallback;
    return ClipRRect(
      borderRadius: radius,
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.contain,
        semanticLabel: context.l10n.appName,
        frameBuilder: (_, child, frame, sync) =>
            frame == null && !sync ? fallback : child,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// The mark that ships with the app.
class BuiltInLogo extends StatelessWidget {
  const BuiltInLogo({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        Icons.forum_outlined,
        color: scheme.onPrimary,
        size: size / 2,
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
  });

  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(icon, size: 30, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(
                body!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 20, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One letter for Arabic names (two Arabic letters join into a word, and
/// "ال" says nothing), two for Latin ones.
String initials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w.startsWith('ال') && w.length > 2 ? w.substring(2) : w)
      .toList();
  if (words.isEmpty) return '';
  final first = words.first.characters.first;
  if (RegExp(r'[\u0600-\u06FF]').hasMatch(first)) return first;
  return words.take(2).map((w) => w.characters.first.toUpperCase()).join();
}

/// Initials in a circle, colored by name so people are easy to tell apart.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.radius = 20});

  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final hex = WaslaColors
        .projectColors[name.hashCode.abs() % WaslaColors.projectColors.length];
    final color = WaslaColors.project(hex, brightness);
    final text = initials(name);
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: 0.16),
      child: Text(
        text.isEmpty ? '؟' : text,
        style: TextStyle(
          color: WaslaColors.onTint(color, brightness),
          fontWeight: FontWeight.w600,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}

/// How many unread items, in an accent pill.
class CountPill extends StatelessWidget {
  const CountPill({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

class ColorDot extends StatelessWidget {
  const ColorDot({super.key, required this.hex, this.size = 12});

  final String hex;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: WaslaColors.project(hex, Theme.of(context).brightness),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// A small rounded label such as a role.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.strong = false});

  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: strong
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: strong ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A white card holding a column of list tiles separated by thin lines.
class TileGroup extends StatelessWidget {
  const TileGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// A button that shows a spinner while its action runs.
class BusyButton extends StatefulWidget {
  const BusyButton({super.key, required this.label, required this.onPressed});

  final String label;
  final Future<void> Function()? onPressed;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: widget.onPressed == null || _busy ? null : _run,
      child: _busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : Text(widget.label),
    );
  }
}

/// A person in a list: name and contact on one line each, never wrapping,
/// with their role as a small tag under the name.
class PersonTile extends StatelessWidget {
  const PersonTile({
    super.key,
    required this.name,
    this.avatarName,
    this.contact,
    this.tag,
    this.strongTag = true,
    this.trailing,
    this.onTap,
  });

  final String name;
  final String? avatarName;
  final String? contact;
  final String? tag;
  final bool strongTag;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasContact = contact != null && contact!.isNotEmpty;
    return ListTile(
      leading: Avatar(name: avatarName ?? name),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: tag == null && !hasContact
          ? null
          : Row(
              children: [
                if (tag != null) ...[
                  Tag(tag!, strong: strongTag),
                  const SizedBox(width: 6),
                ],
                if (hasContact) Flexible(child: LtrLine(contact!)),
              ],
            ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
