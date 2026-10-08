import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'widgets.dart';

/// Email sign-in with a one-time code. New emails get an account on the way.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();
  String? _sentTo;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  Future<void> _sendCode() async {
    if (!_form.currentState!.validate()) return;
    await _send(_email.text.trim().toLowerCase());
  }

  Future<void> _send(String email) async {
    final resend = _sentTo != null;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).sendEmailCode(email),
      done: resend ? context.l10n.codeResent : null,
    );
    if (ok && mounted) {
      setState(() {
        _sentTo = email;
        _code.clear();
      });
    }
  }

  Future<void> _verify() async {
    if (!_form.currentState!.validate()) return;
    await runAction(
      context,
      () => ref.read(apiProvider).verifyEmailCode(_sentTo!, _code.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final sent = _sentTo != null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Logo(),
                    const SizedBox(height: 16),
                    Text(
                      l.appName,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l.tagline,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 36),
                    if (!sent) ...[
                      TextFormField(
                        key: const Key('email'),
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          labelText: l.emailLabel,
                          prefixIcon: const Icon(Icons.mail_outline),
                        ),
                        validator: (v) =>
                            _emailPattern.hasMatch(v?.trim() ?? '')
                            ? null
                            : l.invalidEmail,
                        onFieldSubmitted: (_) => _sendCode(),
                      ),
                      const SizedBox(height: 16),
                      BusyButton(label: l.sendCode, onPressed: _sendCode),
                    ] else ...[
                      Text(
                        l.codeSentTo(ltr(_sentTo!)),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('code'),
                        controller: _code,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.ltr,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(10),
                        ],
                        style: theme.textTheme.headlineSmall?.copyWith(
                          letterSpacing: 8,
                        ),
                        decoration: InputDecoration(labelText: l.codeLabel),
                        validator: (v) =>
                            (v?.trim().length ?? 0) >= 6 ? null : l.invalidCode,
                        onFieldSubmitted: (_) => _verify(),
                      ),
                      const SizedBox(height: 16),
                      BusyButton(label: l.signIn, onPressed: _verify),
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          TextButton(
                            onPressed: () => setState(() => _sentTo = null),
                            child: Text(l.changeEmail),
                          ),
                          TextButton(
                            onPressed: () => _send(_sentTo!),
                            child: Text(l.resendCode),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(Icons.forum_outlined, color: scheme.onPrimary, size: 36),
      ),
    );
  }
}
