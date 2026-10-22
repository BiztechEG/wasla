import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'inbox.dart';
import 'start_screen.dart';
import 'widgets.dart';

/// The link people open to join with a code: the web app, which keeps the
/// code until they have signed in.
String? joinLink(String code) {
  final site = siteLink();
  if (site == null) return null;
  final base = site.endsWith('/') ? site.substring(0, site.length - 1) : site;
  return '$base/app/?join=$code';
}

/// A join code from the address the web app was opened with (?join=CODE),
/// kept on the device until someone signed in can use it.
class PendingJoinCode extends Notifier<String?> {
  static const key = 'pending_join';

  @override
  String? build() => ref.watch(prefsProvider).getString(key);

  Future<void> clear() async {
    state = null;
    await ref.read(prefsProvider).remove(key);
  }
}

final pendingJoinCodeProvider = NotifierProvider<PendingJoinCode, String?>(
  PendingJoinCode.new,
);

/// Offers to join with the code from the link the app was opened with, once
/// someone is signed in and named.
class JoinFromLink extends ConsumerStatefulWidget {
  const JoinFromLink({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<JoinFromLink> createState() => _JoinFromLinkState();
}

class _JoinFromLinkState extends ConsumerState<JoinFromLink> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final code = ref.read(pendingJoinCodeProvider);
      if (code == null || !mounted) return;
      await ref.read(pendingJoinCodeProvider.notifier).clear();
      if (mounted) await showJoinByCode(context, ref, code: code);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Asks for a join code (unless given), shows where it leads, then joins or
/// sends a request to join.
Future<void> showJoinByCode(
  BuildContext context,
  WidgetRef ref, {
  String? code,
}) async {
  final l = context.l10n;
  final result = await showDialog<_Joined>(
    context: context,
    builder: (_) => _JoinByCodeDialog(initial: code),
  );
  if (result == null || !context.mounted) return;
  if (result.open) {
    await openWorkspace(context, ref, result.workspace.workspaceId);
  } else {
    ref.invalidate(myJoinRequestsProvider);
    showMessage(context, l.requestSent(result.workspace.workspaceName));
  }
}

class _Joined {
  const _Joined(this.workspace, {required this.open});

  final CodeWorkspace workspace;

  /// In the workspace now; otherwise a request was sent.
  final bool open;
}

class _JoinByCodeDialog extends ConsumerStatefulWidget {
  const _JoinByCodeDialog({this.initial});

  final String? initial;

  @override
  ConsumerState<_JoinByCodeDialog> createState() => _JoinByCodeDialogState();
}

class _JoinByCodeDialogState extends ConsumerState<_JoinByCodeDialog> {
  late final _code = TextEditingController(text: widget.initial ?? '');
  final _message = TextEditingController();
  CodeWorkspace? _found;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _look());
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(context.l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _look() => _run(() async {
    final found = await ref.read(apiProvider).workspaceByCode(_code.text);
    if (!mounted) return;
    setState(() {
      _found = found;
      _error = found == null ? context.l10n.errorCodeInvalid : null;
    });
  });

  Future<void> _join(CodeWorkspace w) => _run(() async {
    final message = _message.text.trim();
    final joined = await ref
        .read(apiProvider)
        .joinWithCode(_code.text, message: message.isEmpty ? null : message);
    if (mounted) Navigator.pop(context, _Joined(w, open: joined));
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final w = _found;

    final Widget body;
    final Widget? action;
    if (w == null) {
      body = TextField(
        key: const Key('joinCode'),
        controller: _code,
        autofocus: widget.initial == null,
        textDirection: TextDirection.ltr,
        textCapitalization: TextCapitalization.characters,
        inputFormatters: [LengthLimitingTextInputFormatter(20)],
        decoration: InputDecoration(
          labelText: l.joinCodeLabel,
          hintText: 'ABCD-EFGH',
          errorText: _error,
          errorMaxLines: 2,
        ),
        onSubmitted: (_) => _look(),
      );
      action = FilledButton(
        onPressed: _busy ? null : _look,
        child: Text(l.continueAction),
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(name: w.workspaceName),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w.workspaceName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      w.companyName,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            w.member
                ? l.errorAlreadyMember
                : w.requested
                ? l.joinCodeRequested
                : w.autoJoin
                ? l.joinCodeJoins
                : l.joinCodeAsks,
          ),
          if (!w.member && !w.requested && !w.autoJoin) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _message,
              inputFormatters: messageLimit,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(labelText: l.joinMessageLabel),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      );
      action = w.member
          ? FilledButton(
              onPressed: () => Navigator.pop(context, _Joined(w, open: true)),
              child: Text(l.openWorkspace),
            )
          : w.requested
          ? null
          : FilledButton(
              key: const Key('joinWithCode'),
              onPressed: _busy ? null : () => _join(w),
              child: Text(w.autoJoin ? l.joinNow : l.requestToJoin),
            );
    }

    return AlertDialog(
      title: Text(l.haveJoinCode),
      content: SingleChildScrollView(child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        ?action,
      ],
    );
  }
}

/// For admins: the workspace's join code, to share, renew or turn off, and
/// whether people with it join without approval.
class JoinLinkScreen extends ConsumerStatefulWidget {
  const JoinLinkScreen({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<JoinLinkScreen> createState() => _JoinLinkScreenState();
}

class _JoinLinkScreenState extends ConsumerState<JoinLinkScreen> {
  late Future<JoinCode?> _load = _api.joinCode(_ws);
  JoinCode? _code;

  String get _ws => widget.membership.workspaceId;
  WaslaApi get _api => ref.read(apiProvider);

  Future<void> _set({required bool enabled, bool? auto, bool renew = false}) =>
      runAction(context, () async {
        final code = await _api.setJoinCode(
          _ws,
          enabled: enabled,
          autoJoin: auto ?? _code?.autoJoin ?? false,
          renew: renew,
        );
        if (!mounted) return;
        setState(() {
          _load = Future.value(code);
        });
      });

  String _shareText(JoinCode code) {
    final l = context.l10n;
    final link = joinLink(code.code);
    return [
      l.joinLinkShare(widget.membership.workspaceName, code.shown),
      if (link != null) l.joinLinkShareLink(link),
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l.joinLinkTitle)),
      body: FutureBuilder<JoinCode?>(
        future: _load,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorView(
              error: snap.error!,
              onRetry: () => setState(() {
                _load = _api.joinCode(_ws);
              }),
            );
          }
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final code = _code = snap.data;
          final link = code == null ? null : joinLink(code.code);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                l.joinLinkIntro,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              if (code == null)
                FilledButton.icon(
                  key: const Key('joinLinkOn'),
                  icon: const Icon(LucideIcons.link, size: 18),
                  label: Text(l.joinLinkTurnOn),
                  onPressed: () => _set(enabled: true),
                )
              else ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l.joinCodeLabel,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          code.shown,
                          key: const Key('joinCodeShown'),
                          textAlign: TextAlign.center,
                          textDirection: TextDirection.ltr,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 4,
                            color: scheme.primary,
                          ),
                        ),
                        if (link != null) ...[
                          const SizedBox(height: 4),
                          Center(
                            child: LtrLine(
                              link,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          key: const Key('shareJoinLink'),
                          icon: const Icon(
                            LucideIcons.sendHorizontalDir,
                            size: 18,
                          ),
                          label: Text(l.share),
                          onPressed: () =>
                              shareText(context, ref, _shareText(code)),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          icon: const Icon(LucideIcons.copy, size: 18),
                          label: Text(l.copy),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: link ?? code.shown),
                            );
                            if (context.mounted) showMessage(context, l.copied);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TileGroup(
                  children: [
                    SwitchListTile(
                      key: const Key('joinLinkAuto'),
                      secondary: const Icon(LucideIcons.zap),
                      title: Text(l.joinLinkAuto),
                      subtitle: Text(l.joinLinkAutoHint),
                      value: code.autoJoin,
                      onChanged: (on) => _set(enabled: true, auto: on),
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.refreshCw),
                      title: Text(l.joinLinkRenew),
                      onTap: () async {
                        if (await confirm(
                          context,
                          message: l.joinLinkRenewConfirm,
                          action: l.joinLinkRenew,
                        )) {
                          await _set(enabled: true, renew: true);
                        }
                      },
                    ),
                    ListTile(
                      leading: Icon(LucideIcons.unlink, color: scheme.error),
                      title: Text(
                        l.joinLinkOff,
                        style: TextStyle(color: scheme.error),
                      ),
                      onTap: () => _set(enabled: false),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
