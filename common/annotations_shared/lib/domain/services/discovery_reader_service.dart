import '../../dal/remote/api_adapter.dart';

enum NoteViewMode { original, typed }

final class DiscoveryQuery {
  final String q;
  final String? authorId;
  final String? language;
  final String? tag;
  final String? projectId;
  final int limit;

  const DiscoveryQuery({
    this.q = '',
    this.authorId,
    this.language,
    this.tag,
    this.projectId,
    this.limit = 20,
  });

  Map<String, String> toQueryParams({String? browseToken, String? cursor}) => {
        if (q.trim().isNotEmpty) 'q': q.trim(),
        if (authorId != null && authorId!.isNotEmpty) 'author_id': authorId!,
        if (language != null && language!.isNotEmpty) 'language': language!,
        if (tag != null && tag!.isNotEmpty) 'tag': tag!,
        if (projectId != null && projectId!.isNotEmpty) 'project_id': projectId!,
        if (browseToken != null && browseToken.isNotEmpty) 'browse_token': browseToken,
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      };
}

final class PublicNoteSummary {
  final String id;
  final String title;
  final String authorId;
  final String authorName;
  final String? projectId;
  final List<String> tags;

  const PublicNoteSummary({
    required this.id,
    required this.title,
    required this.authorId,
    required this.authorName,
    this.projectId,
    this.tags = const [],
  });

  factory PublicNoteSummary.fromJson(Map<String, dynamic> j) => PublicNoteSummary(
        id: '${j['note_id'] ?? j['id'] ?? ''}',
        title: '${j['title'] ?? 'Untitled note'}',
        authorId: '${j['author_id'] ?? ''}',
        authorName: '${j['author_name'] ?? ''}',
        projectId: j['project_id'] as String?,
        tags: ((j['tags'] as List?) ?? const []).map((e) => '$e').toList(),
      );
}

final class DiscoveryPage {
  final List<PublicNoteSummary> items;
  final String? nextCursor;
  final String? browseToken;

  const DiscoveryPage({
    required this.items,
    this.nextCursor,
    this.browseToken,
  });

  factory DiscoveryPage.fromJson(Map<String, dynamic> j) => DiscoveryPage(
        items: ((j['items'] as List?) ?? const [])
            .map((e) => PublicNoteSummary.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        nextCursor: j['next_cursor'] as String?,
        browseToken: j['browse_token'] as String?,
      );
}

final class ReaderEmbed {
  final String kind;
  final String refId;
  final bool restricted;
  final Map<String, dynamic>? payload;

  const ReaderEmbed({
    required this.kind,
    required this.refId,
    required this.restricted,
    this.payload,
  });

  factory ReaderEmbed.fromJson(Map<String, dynamic> j) {
    final isRestricted = (j['restricted'] as bool?) ??
        ('${j['visibility'] ?? 'public'}' != 'public');
    return ReaderEmbed(
      kind: '${j['kind'] ?? 'embed'}',
      refId: '${j['ref_id'] ?? j['id'] ?? ''}',
      restricted: isRestricted,
      payload: isRestricted || j['payload'] is! Map
          ? null
          : Map<String, dynamic>.from(j['payload'] as Map),
    );
  }
}

final class ReaderNoteView {
  final String noteId;
  final String title;
  final NoteViewMode activeView;
  final bool hasOriginal;
  final bool hasTyped;
  final bool isTypedStale;
  final List<ReaderEmbed> embeds;
  final Map<String, dynamic> raw;

  const ReaderNoteView({
    required this.noteId,
    required this.title,
    required this.activeView,
    required this.hasOriginal,
    required this.hasTyped,
    required this.isTypedStale,
    required this.embeds,
    required this.raw,
  });

  bool get canSwitchView => hasOriginal && hasTyped;

  static NoteViewMode selectView({
    required NoteViewMode mainView,
    required bool hasOriginal,
    required bool hasTyped,
    NoteViewMode? requestedView,
  }) {
    if (requestedView == NoteViewMode.original && hasOriginal) return NoteViewMode.original;
    if (requestedView == NoteViewMode.typed && hasTyped) return NoteViewMode.typed;
    if (mainView == NoteViewMode.original && hasOriginal) return NoteViewMode.original;
    if (mainView == NoteViewMode.typed && hasTyped) return NoteViewMode.typed;
    if (hasOriginal) return NoteViewMode.original;
    return NoteViewMode.typed;
  }

  factory ReaderNoteView.fromJson(
    Map<String, dynamic> j, {
    NoteViewMode? requestedView,
  }) {
    final hasOriginal = (j['has_original'] as bool?) ?? (j['original'] != null);
    final hasTyped = (j['has_typed'] as bool?) ?? (j['typed'] != null);
    final mainView = '${j['main_view'] ?? 'original'}' == 'typed'
        ? NoteViewMode.typed
        : NoteViewMode.original;
    final activeView = selectView(
      mainView: mainView,
      hasOriginal: hasOriginal,
      hasTyped: hasTyped,
      requestedView: requestedView,
    );
    final embeds = ((j['embeds'] as List?) ?? const [])
        .map((e) => ReaderEmbed.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return ReaderNoteView(
      noteId: '${j['note_id'] ?? j['id'] ?? ''}',
      title: '${j['title'] ?? 'Untitled note'}',
      activeView: activeView,
      hasOriginal: hasOriginal,
      hasTyped: hasTyped,
      isTypedStale: (j['typed_stale'] as bool?) ?? false,
      embeds: embeds,
      raw: j,
    );
  }
}

/// Adapters for public discovery (`GET /notes`, authors, projects), public reader,
/// and read-only own synced notes (`GET /me/notes`) (annotations#39).
class DiscoveryReaderAdapter {
  final ApiAdapter api;

  DiscoveryReaderAdapter(this.api);

  Future<DiscoveryPage> listPublicNotes(
    DiscoveryQuery query, {
    String? browseToken,
    String? cursor,
  }) async {
    final json = await api.request(
      '/notes',
      query: query.toQueryParams(browseToken: browseToken, cursor: cursor),
    );
    return DiscoveryPage.fromJson(json);
  }

  Future<ReaderNoteView> getPublicNote(
    String noteId, {
    NoteViewMode? view,
    String? language,
  }) async {
    final json = await api.request(
      '/notes/$noteId',
      query: {
        if (view != null) 'view': view.name,
        if (language != null && language.isNotEmpty) 'language': language,
      },
    );
    return ReaderNoteView.fromJson(json, requestedView: view);
  }

  Future<Map<String, dynamic>> getAuthor(String authorId) =>
      api.request('/authors/$authorId');

  Future<Map<String, dynamic>> getAuthorProjects(
    String authorId, {
    String? cursor,
    int limit = 20,
  }) =>
      api.request(
        '/authors/$authorId/projects',
        query: {
          if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          'limit': '$limit',
        },
      );

  Future<Map<String, dynamic>> getProject(String projectId) =>
      api.request('/projects/$projectId');

  Future<DiscoveryPage> listMySyncedNotes({String? cursor, int limit = 20}) async {
    final json = await api.request(
      '/me/notes',
      query: {
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
        'limit': '$limit',
      },
    );
    return DiscoveryPage.fromJson(json);
  }

  Future<ReaderNoteView> getMySyncedNote(String noteId, {NoteViewMode? view}) async {
    final json = await api.request(
      '/me/notes/$noteId',
      query: {if (view != null) 'view': view.name},
    );
    return ReaderNoteView.fromJson(json, requestedView: view);
  }
}

/// Preserves search, filters, cursor, browse_token, items, and scroll offset
/// across navigation into a note and back (annotations#39 checklist).
class DiscoveryFeedController {
  final DiscoveryReaderAdapter adapter;
  DiscoveryQuery query;
  final List<PublicNoteSummary> items = [];
  final Set<String> _seenIds = {};
  String? browseToken;
  String? nextCursor;
  double scrollOffset = 0;

  DiscoveryFeedController({
    required this.adapter,
    this.query = const DiscoveryQuery(),
  });

  Future<void> refresh(DiscoveryQuery newQuery) async {
    query = newQuery;
    items.clear();
    _seenIds.clear();
    browseToken = null;
    nextCursor = null;
    scrollOffset = 0;
    final page = await adapter.listPublicNotes(query);
    _appendPage(page);
  }

  Future<void> loadMore() async {
    if (nextCursor == null || nextCursor!.isEmpty) return;
    final page = await adapter.listPublicNotes(
      query,
      browseToken: browseToken,
      cursor: nextCursor,
    );
    _appendPage(page);
  }

  void _appendPage(DiscoveryPage page) {
    browseToken = page.browseToken ?? browseToken;
    nextCursor = page.nextCursor;
    for (final item in page.items) {
      if (_seenIds.add(item.id)) {
        items.add(item);
      }
    }
  }
}
