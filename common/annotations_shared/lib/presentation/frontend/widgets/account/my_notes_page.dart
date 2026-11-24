import 'package:flutter/material.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../domain/services/account_service.dart';
import '../../../../domain/services/my_notes_service.dart';
import '../../components/account_menu.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/tokens.dart';
import '../landing/landing_blocks.dart' show isPhone;

/// `/v1/me/notes`: the signed-in user's synced notes, read only in the
/// browser (F2 point 4: the browser gains no private-note editing).
class MyNotesPage extends StatefulWidget {
  const MyNotesPage({super.key});

  @override
  State<MyNotesPage> createState() => _MyNotesPageState();
}

class _MyNotesPageState extends State<MyNotesPage> {
  Future<List<MyNoteSummary>>? _notes;
  AccountService? _account;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = AppScope.of(context).account;
    if (account != _account) {
      _account?.removeListener(_changed);
      _account = account?..addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    _account?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_account?.signedIn == true && _notes == null) _load();
    if (_account?.signedIn != true && _notes != null) {
      setState(() {
        _notes = null;
      });
    }
  }

  void _load() {
    final service = AppScope.of(context).myNotes;
    if (service == null) return;
    final notes = service.list();
    // A refused call: the session is dead. Signed out once, no loop.
    notes.then(
      (_) {},
      onError: (Object e) {
        if (e is MyNotesError && e.refused) _account?.expire();
      },
    );
    setState(() {
      _notes = notes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isPhone(context) ? 20 : 48,
        vertical: 40,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.tr('myNotes'), style: text.headlineMedium),
              const SizedBox(height: 8),
              Text(
                context.tr('myNotesLead'),
                style: text.bodyLarge!.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: 32),
              if (account == null || account.status == AccountStatus.checking)
                const SizedBox(key: Key('my-notes-checking'), height: 40)
              else if (!account.signedIn)
                _SignedOut()
              else
                FutureBuilder<List<MyNoteSummary>>(
                  future: _notes,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return track(
                        'account.notes.retry',
                        LoadError(
                          key: const Key('my-notes-error'),
                          retry: _load,
                        ),
                      );
                    }
                    if (!snap.hasData) {
                      return const Center(
                        key: Key('my-notes-loading'),
                        child: CircularProgressIndicator(),
                      );
                    }
                    final notes = snap.data!;
                    if (notes.isEmpty) {
                      return Text(
                        context.tr('myNotesEmpty'),
                        key: const Key('my-notes-empty'),
                        style: text.bodyLarge,
                      );
                    }
                    return Column(
                      key: const Key('my-notes-list'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final note in notes) _NoteRow(note)],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignedOut extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(
    key: const Key('my-notes-signed-out'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        context.tr('myNotesSignedOut'),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 16),
      track(
        'account.notes.sign_in',
        AppButton.primary(
          key: const Key('my-notes-sign-in'),
          label: context.tr('signIn'),
          onPressed: () =>
              signInOrOpen(context, returnTo: AccountService.myNotesPath),
        ),
      ),
    ],
  );
}

class _NoteRow extends StatelessWidget {
  const _NoteRow(this.note);

  final MyNoteSummary note;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    final date = note.updatedAt.toIso8601String().split('T').first;
    return Container(
      key: Key('my-note-${note.id}'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  note.title.isEmpty ? context.tr('untitledNote') : note.title,
                  style: text.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  date,
                  style: text.bodySmall!.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: note.published ? c.selection : c.subtle,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: note.published ? c.selectionOutline : c.border,
              ),
            ),
            child: Text(
              context.tr(note.published ? 'notePublished' : 'notePrivate'),
              style: text.labelMedium!.copyWith(
                color: note.published ? c.onSelection : c.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
