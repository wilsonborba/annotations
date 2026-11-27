import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/tracking_manifest.dart';
import '../../../../core/platform_profile.dart';
import '../../../../domain/models/local_note.dart';
import '../../../../dal/remote/api_adapter.dart';
import '../../../../domain/models/note_document.dart';
import '../../../../domain/services/discovery_reader_service.dart';
import '../../../../domain/services/note_autosave.dart';
import '../../../../domain/services/read_only_store.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/landing_image.dart';
import '../../components/qr_share.dart';
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

  void _go(BuildContext context, DiscoveryQuery q) {
    final params = {
      if (q.q.isNotEmpty) 'q': q.q,
      if (q.tag != null) 'tag': q.tag!,
      if (q.authorId != null) 'author': q.authorId!,
      if (q.language != null) 'language': q.language!,
      if (q.projectId != null) 'project': q.projectId!,
    };
    // No filter: the plain address, without an empty "?".
    context.go(
      Uri(
        path: '/v1/menu',
        queryParameters: params.isEmpty ? null : params,
      ).toString(),
    );
  }

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
                deleteIcon: const AppIcon(AppIcons.close, size: 16),
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

Widget _asyncErrorView(
  Object? error, {
  required Key errorKey,
  required VoidCallback retry,
}) {
  if (error case ApiError(status: 404)) {
    return const NotFoundState();
  }
  return _Page(
    children: [
      Center(
        child: LoadError(
          key: errorKey,
          retry: retry,
          reference: error is ApiError ? '$error' : null,
        ),
      ),
    ],
  );
}

/// `/v1/authors/<id>`: the author, their public projects and notes.
class AuthorPage extends StatefulWidget {
  const AuthorPage({super.key, required this.authorId});

  final String authorId;

  @override
  State<AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<AuthorPage> {
  Future<List<Map<String, dynamic>>>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _fetch();
  }

  @override
  void didUpdateWidget(AuthorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authorId != widget.authorId) _load();
  }

  Future<List<Map<String, dynamic>>> _fetch() {
    final adapter = _adapter(context);
    return Future.wait([
      adapter.getAuthor(widget.authorId),
      adapter.getAuthorProjects(widget.authorId),
    ]);
  }

  void _load() => setState(() {
    _data = _fetch();
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _data,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _asyncErrorView(
            snap.error,
            errorKey: const Key('author-error'),
            retry: _load,
          );
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
            NoteFeed(
              key: ValueKey('author-${widget.authorId}'),
              query: DiscoveryQuery(authorId: widget.authorId),
            ),
          ],
        );
      },
    );
  }
}

/// `/v1/projects/<id>`: a public project and its notes.
class ProjectPage extends StatefulWidget {
  const ProjectPage({super.key, required this.projectId});

  final String projectId;

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  Future<({Map<String, dynamic> project, String authorName})>? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data ??= _fetch();
  }

  @override
  void didUpdateWidget(ProjectPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) _load();
  }

  Future<({Map<String, dynamic> project, String authorName})> _fetch() async {
    final adapter = _adapter(context);
    final project = await adapter.getProject(widget.projectId);
    var authorName = '${project['author_name'] ?? ''}'.trim();
    final authorId = '${project['author_id'] ?? ''}'.trim();
    if (authorName.isEmpty && authorId.isNotEmpty) {
      try {
        final author = await adapter.getAuthor(authorId);
        authorName = '${author['name'] ?? ''}'.trim();
      } catch (_) {
        // Keep the project page readable with the localized fallback label
        // when the secondary author lookup cannot resolve a public name.
      }
    }
    return (project: project, authorName: authorName);
  }

  void _load() => setState(() {
    _data = _fetch();
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final c = context.colors;
    return FutureBuilder<({Map<String, dynamic> project, String authorName})>(
      future: _data,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _asyncErrorView(
            snap.error,
            errorKey: const Key('project-error'),
            retry: _load,
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snap.data!;
        final p = data.project;
        final authorId = '${p['author_id'] ?? ''}'.trim();
        final authorDisplay = data.authorName.isNotEmpty
            ? data.authorName
            : context.tr('unknownAuthor');
        final authorLabel = '${context.tr('noteBy')} $authorDisplay';
        return _Page(
          children: [
            Text(
              '${p['name'] ?? ''}',
              key: const Key('project-name'),
              style: text.headlineMedium,
            ),
            const SizedBox(height: 8),
            if (authorId.isNotEmpty)
              InkWell(
                key: const Key('project-author'),
                onTap: () => context.go('/v1/authors/$authorId'),
                child: Text(
                  authorLabel,
                  style: text.bodyLarge!.copyWith(color: c.link),
                ),
              )
            else
              Text(
                authorLabel,
                key: const Key('project-author'),
                style: text.bodyLarge,
              ),
            Text('${p['note_count'] ?? 0} ${context.tr('noteCount')}'),
            const SizedBox(height: 24),
            NoteFeed(
              key: ValueKey('project-${widget.projectId}'),
              query: DiscoveryQuery(projectId: widget.projectId),
            ),
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
    _note ??= _fetch();
  }

  @override
  void didUpdateWidget(ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteId != widget.noteId || oldWidget.view != widget.view) {
      _load();
    }
  }

  Future<ReaderNoteView> _fetch() => _adapter(
    context,
  ).getPublicNote(widget.noteId, view: widget.view).then(_open);

  Future<void> _startHandwrittenStudy(ReaderNoteView note) async {
    final context = this.context;
    final workspace = AppScope.of(context).workspace;
    if (workspace == null ||
        workspace.profile != PlatformProfile.fullWriter ||
        !note.hasTyped) {
      return;
    }
    final raw = note.raw;
    try {
      final studyId = await workspace.createHandwrittenStudy(
        StudySourceReference(
          noteId: note.noteId,
          title: note.title,
          authorId: raw['author_id'] as String?,
          authorName: raw['author_name'] as String?,
        ),
      );
      if (!context.mounted) return;
      context.go('/v1/write/$studyId');
    } catch (_) {
      if (context.mounted) {
        showAppToast(context, context.tr('studySourceCreateFailed'));
      }
    }
  }

  void _load() {
    _paper?.dispose();
    _paper = null;
    setState(() {
      _note = _fetch();
    });
  }

  ReaderNoteView _open(ReaderNoteView note) {
    if (!mounted) return note;
    _paper?.dispose();
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
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return _asyncErrorView(
            snap.error,
            errorKey: const Key('reader-error'),
            retry: _load,
          );
        }
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
        final readerUri = publicAppUri(
          pathSegments: ['v1', 'notes', note.noteId],
          queryParameters: {'view': note.activeView.name},
        );
        final height = MediaQuery.sizeOf(context).height * .8;
        return _Page(
          children: [
            Text(
              note.title,
              key: const Key('reader-title'),
              style: text.headlineMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                QrShareControl(
                  key: const Key('reader-qr-share'),
                  url: readerUri,
                  caption: note.title,
                  labelKey: 'qrNote',
                ),
                track(
                  'reader.link.copy',
                  AppButton(
                    label: context.tr('copy'),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: readerUri.toString()),
                      );
                      if (context.mounted) {
                        showAppToast(context, context.tr('copied'));
                      }
                    },
                  ),
                ),
                track(
                  'reader.link.open',
                  AppButton(
                    label: context.tr('openNote'),
                    onPressed: () => launchUrl(
                      readerUri,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ),
              ],
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
            if (AppScope.of(context).workspace?.profile ==
                    PlatformProfile.fullWriter &&
                note.hasTyped) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: AppButton(
                  key: const Key('reader-start-handwritten-study'),
                  label: context.tr('startHandwrittenStudy'),
                  onPressed: () => _startHandwrittenStudy(note),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (note.canSwitchView)
              Align(
                alignment: Alignment.centerLeft,
                child: track(
                  'reader.view.switch',
                  SegmentedButton<NoteViewMode>(
                    key: const Key('reader-switch'),
                    showSelectedIcon: false,
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
                      // The formal page lines up with the title above it.
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: NoteReader(
                          key: const Key('reader-typed'),
                          handler: paper,
                          publicProjection: true,
                        ),
                      ),
                    )
                  : NoteReader(
                      key: const Key('reader-original'),
                      handler: paper,
                      publicProjection: true,
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
  void didUpdateWidget(_SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial &&
        _controller.text != widget.initial) {
      _controller.value = TextEditingValue(
        text: widget.initial,
        selection: TextSelection.collapsed(offset: widget.initial.length),
      );
    }
  }

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
        prefixIcon: const Padding(
          padding: EdgeInsets.all(12),
          child: AppIcon(AppIcons.search, size: 18),
        ),
      ),
      onSubmitted: widget.onSubmit,
    ),
    controller: _controller,
  );
}
