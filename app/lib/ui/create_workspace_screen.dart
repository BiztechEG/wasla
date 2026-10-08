import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import 'start_screen.dart';
import 'widgets.dart';

/// Countries offered at launch: Egypt and the Gulf.
const launchCountries = ['EG', 'SA', 'AE', 'KW', 'QA', 'BH', 'OM'];

String countryName(AppLocalizations l, String code) => switch (code) {
  'EG' => l.countryEG,
  'SA' => l.countrySA,
  'AE' => l.countryAE,
  'KW' => l.countryKW,
  'QA' => l.countryQA,
  'BH' => l.countryBH,
  'OM' => l.countryOM,
  _ => code,
};

/// A new company with its first workspace; the creator becomes the owner.
class CreateWorkspaceScreen extends ConsumerStatefulWidget {
  const CreateWorkspaceScreen({super.key});

  @override
  ConsumerState<CreateWorkspaceScreen> createState() =>
      _CreateWorkspaceScreenState();
}

class _CreateWorkspaceScreenState extends ConsumerState<CreateWorkspaceScreen> {
  final _company = TextEditingController();
  final _workspace = TextEditingController();
  final _form = GlobalKey<FormState>();
  String _country = 'EG';

  @override
  void dispose() {
    _company.dispose();
    _workspace.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    String? workspaceId;
    final ok = await runAction(context, () async {
      workspaceId = await ref
          .read(apiProvider)
          .createCompanyWorkspace(
            companyName: _company.text.trim(),
            countryCode: _country,
            workspaceName: _workspace.text.trim(),
          );
    });
    if (ok && mounted) await openWorkspace(context, ref, workspaceId!);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    String? required(String? v) =>
        (v?.trim().isEmpty ?? true) ? l.fieldRequired : null;

    return Scaffold(
      appBar: AppBar(title: Text(l.newWorkspaceTitle)),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const Key('companyName'),
              controller: _company,
              autofocus: true,
              inputFormatters: nameLimit,
              decoration: InputDecoration(labelText: l.companyNameLabel),
              validator: required,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('workspaceName'),
              controller: _workspace,
              inputFormatters: nameLimit,
              decoration: InputDecoration(
                labelText: l.workspaceNameLabel,
                hintText: l.workspaceNameHint,
              ),
              validator: required,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _country,
              decoration: InputDecoration(labelText: l.countryLabel),
              items: [
                for (final code in launchCountries)
                  DropdownMenuItem(
                    value: code,
                    child: Text(countryName(l, code)),
                  ),
              ],
              onChanged: (v) => setState(() => _country = v ?? _country),
            ),
            const SizedBox(height: 24),
            BusyButton(label: l.create, onPressed: _create),
          ],
        ),
      ),
    );
  }
}
