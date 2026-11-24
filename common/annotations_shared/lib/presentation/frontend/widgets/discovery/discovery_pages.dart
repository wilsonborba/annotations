import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../dal/remote/api_adapter.dart';
import '../../../../domain/models/note_document.dart';
import '../../../../domain/services/discovery_reader_service.dart';
import '../../../../domain/services/note_autosave.dart';
import '../../../../domain/services/read_only_store.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/landing_image.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/tokens.dart';
import '../../handlers/paper_handler.dart';
import '../landing/landing_blocks.dart' show isPhone;
import '../typed/note_screen.dart';

/// Public browsing, author and project pages and the reader (annotations#40,
/// F1, B5): `/v1/menu`, `/v1/authors/<id>`, `/v1/projects/<id>` and
/// `/v1/notes/<id>?view=original|typed`.

DiscoveryReaderAdapter _adapter(BuildContext context) =>
    DiscoveryReaderAdapter(AppScope.of(context).service.api);

String _date(int seconds) => seconds <= 0
    ? ''
    : DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
      ).toIso8601String().split('T').first;

/// The page column with the reading gutters.
class _Page extends StatelessWidget {
  const _Page({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: isPhone(context) ? 20 : 48,
      vertical: 32,
    ),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// One search, filters for tag, author, language and public project, and
/// the results (scope 1). The filters live in the address, so a link keeps
/// them and Back restores them.
class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.query});

  final DiscoveryQuery query;

  void _go(BuildContext context, DiscoveryQuery q) => context.go(
    Uri(
      path: '/v1/menu',
      queryParameters: {
        if (q.q.isNotEmpty) 'q': q.q,
        if (q.tag != null) 'tag': q.tag!,
        if (q.authorId != null) 'author': q.authorId!,
        if (q.language != null) 'language': q.language!,
        if (q.projectId != null) 'project': q.projectId!,
      },
    ).toString(),
  );

  DiscoveryQuery _with({
    String? q,
    String? tag,
    String? authorId,
    String? language,
    String? projectId,
  }) => DiscoveryQuery(
    q: q ?? query.q,
    tag: tag == '' ? null : tag ?? query.tag,
    authorId: authorId == '' ? null : authorId ?? query.authorId,
    language: language == '' ? null : language ?? query.language,
    projectId: projectId == '' ? null : projectId ?? query.projectId,
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final filters = [
      if (query.tag != null) ('filterTag', '#${query.tag}', _with(tag: '')),
      if (query.authorId != null)
        ('filterAuthor', query.authorId!, _with(authorId: '')),
      if (query.projectId != null)
        ('filterProject', query.projectId!, _with(projectId: '')),
    ];
    return _Page(
      children: [
        Text(context.tr('browse'), style: text.headlineMedium),
        const SizedBox(height: 16),
        _SearchField(
          initial: query.q,
          onSubmit: (v) => _go(context, _with(q: v.trim())),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            MenuAnchor(
              menuChildren: [
                for (final (code, label) in [
                  ('', 'allLanguages'),
                  ('en', 'English'),
                  ('pt-BR', 'Português'),
                  ('th', 'ไทย'),
                ])
                  MenuItemButton(
                    key: Key('language-${code.isEmpty ? 'all' : code}'),
                    onPressed: () => _go(context, _with(language: code)),
                    child: Text(code.isEmpty ? context.tr(label) : label),
                  ),
              ],
              builder: (context, controller, _) => AppButton(
                key: const Key('filter-language'),
                label: query.language ?? context.tr('allLanguages'),
                icon: AppIcons.translate,
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
            for (final (kind, value, cleared) in filters)
              InputChip(
                key: Key('active-$kind'),
                label: Text('${context.tr(kind)}: $value'),
                onDeleted: () => _go(context, cleared),
                deleteButtonTooltipMessage: context.tr('clearFilter'),
              ),
          ],
        ),
        const SizedBox(height: 24),
        NoteFeed(
          key: ValueKey(query.toQueryParams().toString()),
          query: query,
          onTag: (tag) => _go(context, _with(tag: tag)),
        ),
      ],
    );
  }
}

/// The result list of a query, with Show more, S03 when empty and Retry on
/// a failed load.
class NoteFeed extends StatefulWidget {
  const NoteFeed({super.key, required this.query, this.onTag});

  final DiscoveryQuery query;
  final ValueChanged<String>? onTag;

  @override
  State<NoteFeed> createState() => _NoteFeedState();
}

class _NoteFeedState extends State<NoteFeed> {
  DiscoveryFeedController? _feed;
  Future<void>? _loading;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_feed != null) return;
    _feed = DiscoveryFeedController(adapter: _adapter(context));
    _load();
  }

  void _load() => setState(() {
    _loading = _feed!.refresh(widget.query);
  });

  void _more() => setState(() {
    _loading = _feed!.loadMore();
  });

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _loading,
    builder: (context, snap) {
      final feed = _feed!;
      final waiting = snap.connectionState != ConnectionState.done;
      if (snap.hasError && feed.items.isEmpty) {
        return LoadError(
          key: const Key('feed-error'),
          retry: _load,
          reference: snap.error is ApiError ? '${snap.error}' : null,
        );
      }
      if (waiting && feed.items.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (feed.items.isEmpty) {
        return Column(
          key: const Key('feed-empty'),
          children: [
            const StatePicture('S03'),
            Text(context.tr('empty'), key: const Key('no-results')),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final note in feed.items)
            NoteResult(note: note, onTag: widget.onTag),
          if (feed.nextCursor != null) ...[
            const SizedBox(height: 16),
            Center(
              child: track(
                'discovery.more',
                AppButton(
                  key: const Key('feed-more'),
                  label: context.tr('loadMore'),
                  onPressed: waiting ? null : _more,
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

/// One result: title, summary, author, language, tags, date and views.
class NoteResult extends StatelessWidget {
  const NoteResult({super.key, required this.note, this.onTag});

  final PublicNoteSummary note;
  final ValueChanged<String>? onTag;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    return Container(
      key: Key('result-${note.id}'),
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => context.go('/v1/notes/${note.id}'),
            child: Text(
              note.title,
              style: text.titleLarge!.copyWith(color: c.link),
            ),
          ),
          if (note.summary != null && note.summary!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(note.summary!, style: text.bodyLarge),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InkWell(
                key: Key('author-${note.id}'),
                onTap: () => context.go('/v1/authors/${note.authorId}'),
                child: Text(
                  note.authorName,
                  style: text.bodyMedium!.copyWith(color: c.link),
                ),
              ),
              if (note.language.isNotEmpty)
                Text(note.language, style: text.bodySmall),
              if (note.publishedAt > 0)
                Text(_date(note.publishedAt), style: text.bodySmall),
              for (final view in note.views)
                Text(
                  context.tr(view == 'typed' ? 'viewTyped' : 'viewOriginal'),
                  key: Key('view-${note.id}-$view'),
                  style: text.labelMedium!.copyWith(color: c.textSecondary),
                ),
              for (final tag in note.tags)
                ActionChip(
                  key: Key('tag-${note.id}-$tag'),
                  label: Text('#$tag'),
                  onPressed: onTag == null ? null : () => onTag!(tag),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `/v1/authors/<id>`: the author, their public projects and notes.
class AuthorPage extends StatelessWidget {
  const AuthorPage({super.key, required this.authorId});

  final String authorId;

  @override
  Widget build(BuildContext context) {
    final adapter = _adapter(context);
    final text = Theme.of(context).textTheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: Future.wait([
        adapter.getAuthor(authorId),
        adapter.getAuthorProjects(authorId),
      ]),
      builder: (context, snap) {
        if (snap.error case ApiError(status: 404)) {
          return const NotFoundState();
        }
        if (snap.hasError) {
          return const _Page(children: [NotFoundState()]);
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final [author, projects] = snap.data!;
        final items = ((projects['items'] as List?) ?? const [])
            .cast<Map>()
            .toList();
        return _Page(
          children: [
            Text(
              '${author['name'] ?? ''}',
              key: const Key('author-name'),
              style: text.headlineMedium,
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(context.tr('projectsOf'), style: text.titleLarge),
              for (final p in items)
                ListTile(
                  key: Key('project-${p['project_id']}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('${p['name'] ?? ''}'),
                  subtitle: Text(
                    '${p['note_count'] ?? 0} ${context.tr('noteCount')}',
                  ),
                  onTap: () => context.go('/v1/projects/${p['project_id']}'),
                ),
            ],
            const SizedBox(height: 24),
            Text(context.tr('notesOf'), style: text.titleLarge),
            NoteFeed(query: DiscoveryQuery(authorId: authorId)),
          ],
        );
      },
    );
  }
}

/// `/v1/projects/<id>`: a public project and its notes.
class ProjectPage extends StatelessWidget {
  const ProjectPage({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    return FutureBuilder<Map<String, dynamic>>(
      future: _adapter(context).getProject(projectId),
      builder: (context, snap) {
        if (snap.hasError) return const NotFoundState();
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final p = snap.data!;
        return _Page(
          children: [
            Text(
              '${p['name'] ?? ''}',
              key: const Key('project-name'),
              style: text.headlineMedium,
            ),
            const SizedBox(height: 8),
            InkWell(
              key: const Key('project-author'),
              onTap: () => context.go('/v1/authors/${p['author_id']}'),
              child: Text(
                '${context.tr('noteBy')} ${p['author_name'] ?? ''}',
                style: text.bodyLarge!.copyWith(color: c.link),
              ),
            ),
            Text('${p['note_count'] ?? 0} ${context.tr('noteCount')}'),
            const SizedBox(height: 24),
            NoteFeed(query: DiscoveryQuery(projectId: projectId)),
          ],
        );
      },
    );
  }
}

/// `/v1/notes/<id>?view=original|typed` (scope 3): Original keeps the paper
/// geometry with zoom; Typed is a formal page with the title, author line
/// and reading width. The switch shows only when both views are published.
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.noteId, this.view});

  final String noteId;
  final NoteViewMode? view;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  Future<ReaderNoteView>? _note;
  PaperHandler? _paper;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _note ??= _adapter(
      context,
    ).getPublicNote(widget.noteId, view: widget.view).then(_open);
  }

  ReaderNoteView _open(ReaderNoteView note) {
    final doc = note.activeDocument;
    if (doc != null) {
      final schema = DocumentSchema(
        note.activeView == NoteViewMode.typed ? 'note-typed' : 'note-original',
        1,
      );
      _paper = PaperHandler(
        noteId: note.noteId,
        document: NoteDocument.fromJson(
          readablePublicDocument(doc),
          schema: schema,
        ),
        autosave: NoteAutosave(const ReadOnlyNoteStore()),
      );
    }
    return note;
  }

  @override
  void dispose() {
    _paper?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    return FutureBuilder<ReaderNoteView>(
      future: _note,
      builder: (context, snap) {
        if (snap.hasError) return const NotFoundState();
        final note = snap.data;
        final paper = _paper;
        if (note == null || paper == null) {
          return const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final raw = note.raw;
        final typed = note.activeView == NoteViewMode.typed;
        final height = MediaQuery.sizeOf(context).height * .8;
        return _Page(
          children: [
            Text(
              note.title,
              key: const Key('reader-title'),
              style: text.headlineMedium,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                InkWell(
                  key: const Key('reader-author'),
                  onTap: () => context.go('/v1/authors/${raw['author_id']}'),
                  child: Text(
                    '${context.tr('noteBy')} ${raw['author_name'] ?? ''}',
                    style: text.bodyLarge!.copyWith(color: c.link),
                  ),
                ),
                Text(
                  _date((raw['published_at'] as num?)?.toInt() ?? 0),
                  style: text.bodySmall,
                ),
                Text('${raw['language'] ?? ''}', style: text.bodySmall),
              ],
            ),
            const SizedBox(height: 16),
            if (note.canSwitchView)
              Align(
                alignment: Alignment.centerLeft,
                child: track(
                  'reader.view.switch',
                  SegmentedButton<NoteViewMode>(
                    key: const Key('reader-switch'),
                    segments: [
                      ButtonSegment(
                        value: NoteViewMode.original,
                        label: Text(context.tr('viewOriginal')),
                      ),
                      ButtonSegment(
                        value: NoteViewMode.typed,
                        label: Text(context.tr('viewTyped')),
                      ),
                    ],
                    selected: {note.activeView},
                    onSelectionChanged: (v) => context.go(
                      '/v1/notes/${widget.noteId}?view=${v.first.name}',
                    ),
                  ),
                ),
              ),
            if (typed && note.isTypedStale) ...[
              const SizedBox(height: 12),
              Text(
                context.tr('typedStale'),
                key: const Key('reader-stale'),
                style: text.bodyMedium!.copyWith(color: c.textSecondary),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: height < 480 ? 480 : height,
              child: typed
                  ? Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: NoteReader(
                          key: const Key('reader-typed'),
                          handler: paper,
                        ),
                      ),
                    )
                  : NoteReader(
                      key: const Key('reader-original'),
                      handler: paper,
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// The one search of browsing; the field keeps its own controller.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.initial, required this.onSubmit});

  final String initial;
  final ValueChanged<String> onSubmit;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => track(
    'catalog.search.input',
    TextField(
      key: const Key('catalog-search'),
      controller: _controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: context.tr('search'),
        prefixIcon: const Icon(Icons.search),
      ),
      onSubmitted: widget.onSubmit,
    ),
    controller: _controller,
  );
}
