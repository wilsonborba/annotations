/// A note on any device (annotations#35): the paper editor on full
/// writers, the simple typed editor for simple typed notes, and reading
/// only for everything else on phones and in the browser. Reading never
/// saves, so a note opens and closes unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/platform_profile.dart';
import '../../../../core/landing_settings.dart';
import '../../../../dal/remote/api_adapter.dart';
import '../../../../domain/models/local_note.dart';
import '../../../../domain/models/note_document.dart';
import '../../../../domain/models/reports_embed_data.dart';
import '../../../../domain/services/discovery_reader_service.dart';
import '../../../../domain/services/reports_embed_source.dart';
import '../../../../domain/services/ink_outline.dart';
import '../../../../domain/services/quiz_card_service.dart';
import '../../../../domain/services/task_card_service.dart';
import '../../../../domain/services/note_views.dart';
import '../../../../dal/local/quill_text_engine.dart';
import '../../components/card_layout.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/paper_controls.dart';
import '../../components/quiz_card_view.dart';
import '../../components/reports_embed_card.dart';
import '../../components/save_state.dart';
import '../../components/scope.dart';
import '../../components/task_card_view.dart';
import '../../components/text_tools.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';
import '../../handlers/attachment_cache.dart';
import '../../handlers/attachment_handler.dart';
import '../../handlers/paper_handler.dart';
import '../../handlers/typed_note_handler.dart';
import '../paper/paper_canvas.dart';
import '../paper/note_embedded_cards_layer.dart';
import '../paper/paper_screen.dart';

class NoteScreen extends StatelessWidget {
  final PaperHandler handler;
  final PlatformProfile profile;
  final StudySourceReference? studySource;
  final bool publicProjection;
  final Future<QuizSummary?> Function(String quizId)? loadQuizCard;
  final Future<TaskSummary?> Function(String taskId)? loadTaskCard;
  final ReportsEmbedSource? reportsSource;
  final String? trustedReportsAccountId;
  final String reportsLanguage;
  final Future<void> Function(
    BuildContext context,
    PaperHandler handler,
    AttachmentHandler attachments,
  )?
  onAddReport;
  final Future<void> Function(
    BuildContext context,
    PaperHandler handler,
    AttachmentHandler attachments,
  )?
  onAddTaskCard;
  final Future<void> Function(
    BuildContext context,
    PaperHandler handler,
    AttachmentHandler attachments,
  )?
  onCreateReport;
  const NoteScreen({
    super.key,
    required this.handler,
    required this.profile,
    this.studySource,
    this.publicProjection = false,
    this.loadQuizCard,
    this.loadTaskCard,
    this.reportsSource,
    this.trustedReportsAccountId,
    this.reportsLanguage = 'en',
    this.onAddReport,
    this.onAddTaskCard,
    this.onCreateReport,
  });

  @override
  Widget build(BuildContext context) {
    final view = switch (noteViewFor(profile, handler.document)) {
      NoteView.paper => PaperScreen(
        handler: handler,
        publicProjection: publicProjection,
        reportsSource: reportsSource,
        trustedReportsAccountId: trustedReportsAccountId,
        reportsLanguage: reportsLanguage,
        onAddReport: onAddReport,
        onAddTaskCard: onAddTaskCard,
        onCreateReport: onCreateReport,
        loadQuizCard: loadQuizCard,
        loadTaskCard: loadTaskCard,
      ),
      NoteView.typed => TypedNoteEditor(paper: handler),
      NoteView.readOnly => NoteReader(
        handler: handler,
        publicProjection: publicProjection,
        reportsSource: reportsSource,
        trustedReportsAccountId: trustedReportsAccountId,
        reportsLanguage: reportsLanguage,
        loadTaskCard: loadTaskCard,
        loadQuizCard: loadQuizCard,
      ),
    };
    final source = studySource;
    if (source == null) return view;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StudySourceLine(source: source),
        Expanded(child: view),
      ],
    );
  }
}

/// Reading only: paper notes on the page with zoom and the view lock;
/// typed notes as text. Cards open in their owning service. Nothing is
/// edited or saved.
class NoteReader extends StatefulWidget {
  final PaperHandler handler;
  final bool publicProjection;
  final ReportsEmbedSource? reportsSource;
  final String? trustedReportsAccountId;
  final String reportsLanguage;
  final Future<TaskSummary?> Function(String taskId)? loadTaskCard;
  final Future<QuizSummary?> Function(String quizId)? loadQuizCard;
  const NoteReader({
    super.key,
    required this.handler,
    this.publicProjection = false,
    this.reportsSource,
    this.trustedReportsAccountId,
    this.reportsLanguage = 'en',
    this.loadTaskCard,
    this.loadQuizCard,
  });

  @override
  State<NoteReader> createState() => _NoteReaderState();
}

class _NoteReaderState extends State<NoteReader> {
  late final cards = AttachmentHandler(paper: widget.handler);

  @override
  void dispose() {
    cards.dispose();
    super.dispose();
  }

  /// A tap on a card opens it (the link, or the file with the system).
  void _tap(Offset local, Offset global) {
    final view = widget.handler.view.value;
    final d = widget.handler.document;
    if (view == null || d is! PaperDocument) return;
    final p = view.toPage(local);
    for (final it in d.itemsJson.reversed) {
      if (!isCardKind(it['kind']) || it['kind'] == 'image') continue;
      final r = Rect.fromLTWH(
        (it['x'] as num).toDouble(),
        (it['y'] as num).toDouble(),
        (it['width'] as num).toDouble(),
        (it['height'] as num).toDouble(),
      );
      if (r.contains(p)) {
        if (widget.publicProjection &&
            const {
              'reports_embed',
              'task_card',
              'quiz_card',
            }.contains(it['kind'])) {
          return;
        }
        if (it['restricted'] == true) return;
        cards.open(it['id'] as String);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.handler.document;
    if (document is TypedDocument) {
      return TypedNoteReader(
        document: document,
        files: widget.handler.files,
        title: widget.handler.title,
        onOpen: (url) => cards.launchLink(url),
        publicProjection: widget.publicProjection,
        reportsSource: widget.reportsSource,
        trustedReportsAccountId: widget.trustedReportsAccountId,
        reportsLanguage: widget.reportsLanguage,
        loadTaskCard: widget.loadTaskCard,
        loadQuizCard: widget.loadQuizCard,
        onOpenQuiz: _openQuiz,
      );
    }
    final c = context.colors;
    return Stack(
      fit: StackFit.expand,
      children: [
        PaperCanvas(
          key: const Key('note-reader'),
          handler: widget.handler,
          onTap: _tap,
          onWheel: cards.wheel,
        ),
        if (document is PaperDocument &&
            (widget.publicProjection ||
                widget.reportsSource != null ||
                widget.loadTaskCard != null ||
                widget.loadQuizCard != null))
          ValueListenableBuilder<PaperView?>(
            valueListenable: widget.handler.view,
            builder: (context, view, _) => view == null
                ? const SizedBox.shrink()
                : NoteEmbeddedCardsLayer(
                    key: const Key('reader-embedded-cards'),
                    document: document,
                    view: view,
                    publicProjection: widget.publicProjection,
                    reportsSource: widget.reportsSource,
                    trustedAccountId: widget.trustedReportsAccountId,
                    language: widget.reportsLanguage,
                    loadTask: widget.loadTaskCard,
                    loadQuiz: widget.loadQuizCard,
                  ),
          ),
        Positioned(
          left: 12,
          bottom: 12,
          child: ViewLockButton(handler: widget.handler),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: Container(
            key: const Key('reader-panel'),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(appPanelRadius),
              border: Border.all(color: c.border),
            ),
            child: ListenableBuilder(
              listenable: Listenable.merge([
                widget.handler.view,
                widget.handler,
              ]),
              builder: (context, _) {
                final h = widget.handler;
                return ZoomControls(
                  zoom: h.view.value?.zoom ?? 1,
                  onZoomIn: h.canZoomIn && !h.locked ? h.zoomIn : null,
                  onZoomOut: h.canZoomOut && !h.locked ? h.zoomOut : null,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _openQuiz(String quizId) {
    final normalizedId = quizId.trim();
    if (normalizedId.isEmpty) return;
    final uri = Uri.parse(
      '${LandingSettings.certifications}/v1/quizzes/${Uri.encodeComponent(normalizedId)}',
    );
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

/// The simple typed editor of phones: the title, the paragraph styles, the
/// text formatting, Undo and Redo, and the text.
class TypedNoteEditor extends StatefulWidget {
  final PaperHandler paper;
  const TypedNoteEditor({super.key, required this.paper});

  @override
  State<TypedNoteEditor> createState() => _TypedNoteEditorState();
}

class _TypedNoteEditorState extends State<TypedNoteEditor> {
  late final typed = TypedNoteHandler(paper: widget.paper);
  late final title = TextEditingController(text: widget.paper.title ?? '');
  final _editorFocus = FocusNode();
  final _editorScroll = ScrollController();

  @override
  void dispose() {
    typed.dispose();
    title.dispose();
    _editorFocus.dispose();
    _editorScroll.dispose();
    super.dispose();
  }

  String _styleLabel(BuildContext context, TypedLineStyle s) =>
      context.tr(switch (s) {
        TypedLineStyle.text => 'lineText',
        TypedLineStyle.heading1 => 'lineHeading1',
        TypedLineStyle.heading2 => 'lineHeading2',
        TypedLineStyle.heading3 => 'lineHeading3',
        TypedLineStyle.bullets => 'lineBullets',
        TypedLineStyle.numbers => 'lineNumbers',
      });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final paper = widget.paper;
    return ColoredBox(
      color: c.page,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('typed-title'),
                      controller: title,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: c.text,
                      ),
                      decoration: InputDecoration(
                        hintText: context.tr('noteTitle'),
                        border: InputBorder.none,
                      ),
                      onChanged: paper.rename,
                    ),
                  ),
                  SaveStateIndicator(
                    state: paper.saveState,
                    onRetry: paper.retrySave,
                  ),
                ],
              ),
            ),
            ListenableBuilder(
              listenable: Listenable.merge([typed, paper]),
              builder: (context, _) => Container(
                key: const Key('typed-toolbar'),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(appPanelRadius),
                  border: Border.all(color: c.border),
                ),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    AppMenuButton(
                      key: const Key('typed-line-style'),
                      icon: AppIcons.type,
                      label: _styleLabel(context, typed.lineStyle),
                      entries: [
                        for (final s in TypedLineStyle.values)
                          AppMenuEntry(
                            key: Key('line-${s.name}'),
                            label: _styleLabel(context, s),
                            checked: typed.lineStyle == s,
                            onSelected: () => typed.setLineStyle(s),
                          ),
                      ],
                    ),
                    TextTools(
                      format: typed.format,
                      baseSize: typed.engine.style.fontSize ?? 16,
                      settings: paper.settings,
                      onToggle: typed.toggle,
                      onSize: typed.size,
                      onColor: typed.color,
                      bare: true,
                    ),
                    AppIconButton(
                      key: const Key('typed-undo'),
                      icon: AppIcons.undo,
                      label: context.tr('undo'),
                      onPressed: paper.canUndo ? paper.undo : null,
                    ),
                    AppIconButton(
                      key: const Key('typed-redo'),
                      icon: AppIcons.redo,
                      label: context.tr('redo'),
                      onPressed: paper.canRedo ? paper.redo : null,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: typed,
                builder: (context, _) => QuillEditor.basic(
                  key: const Key('typed-editor'),
                  controller: typed.controller,
                  focusNode: _editorFocus,
                  scrollController: _editorScroll,
                  config: QuillEditorConfig(
                    padding: const EdgeInsets.all(16),
                    placeholder: context.tr('typedPlaceholder'),
                    customStyles: _styles(context),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  DefaultStyles _styles(BuildContext context) {
    final c = context.colors;
    final base = annotationsTextStyle.copyWith(color: c.text);
    final none = const VerticalSpacing(0, 0);
    DefaultTextBlockStyle block(TextStyle s, double top) =>
        DefaultTextBlockStyle(
          s,
          const HorizontalSpacing(0, 0),
          VerticalSpacing(top, 4),
          none,
          null,
        );
    return DefaultStyles(
      paragraph: block(base, 0),
      h1: block(base.copyWith(fontSize: 28, fontWeight: FontWeight.w700), 12),
      h2: block(base.copyWith(fontSize: 22, fontWeight: FontWeight.w700), 10),
      h3: block(base.copyWith(fontSize: 18, fontWeight: FontWeight.w600), 8),
      lists: DefaultListBlockStyle(
        base,
        const HorizontalSpacing(0, 0),
        const VerticalSpacing(0, 4),
        none,
        null,
        null,
      ),
    );
  }
}

class _StudySourceLine extends StatefulWidget {
  const _StudySourceLine({required this.source});

  final StudySourceReference source;

  @override
  State<_StudySourceLine> createState() => _StudySourceLineState();
}

class _StudySourceLineState extends State<_StudySourceLine> {
  ReaderNoteView? _publicSource;
  bool _unavailable = false;
  int _requestGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requestGeneration == 0) _refreshSource();
  }

  @override
  void didUpdateWidget(_StudySourceLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _refreshSource();
  }

  Future<void> _refreshSource() async {
    final generation = ++_requestGeneration;
    final source = widget.source;
    if (_publicSource != null || _unavailable) {
      setState(() {
        _publicSource = null;
        _unavailable = false;
      });
    }
    try {
      final note = await DiscoveryReaderAdapter(
        AppScope.of(context).service.api,
      ).getPublicNote(source.noteId, view: NoteViewMode.typed);
      if (!mounted || generation != _requestGeneration) return;
      if (note.noteId != source.noteId ||
          !note.hasTyped ||
          note.activeView != NoteViewMode.typed ||
          note.activeDocument == null) {
        setState(() => _unavailable = true);
        return;
      }
      setState(() => _publicSource = note);
    } on ApiError catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      if (error.status == 401 || error.status == 403 || error.status == 404) {
        setState(() => _unavailable = true);
      }
    } catch (_) {
      // Keep the saved title and author available when the network is offline.
    }
  }

  void _openSource() {
    final source = widget.source;
    if (_publicSource == null || _unavailable) return;
    context.go('/v1/notes/${Uri.encodeComponent(source.noteId)}?view=typed');
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final colors = Theme.of(context).colorScheme;
    final savedTitle = source.title?.trim();
    final title =
        _publicSource?.title ??
        (savedTitle == null || savedTitle.isEmpty ? source.noteId : savedTitle);
    final author =
        _publicSource?.raw['author_name'] as String? ?? source.authorName;
    final canOpen = _publicSource != null && !_unavailable;
    final displayedSource =
        '${context.tr('studySource')}: ${[title, if (author != null && author.isNotEmpty) author].join(' · ')}';
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                canOpen ? AppIcons.openIn : AppIcons.link,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  displayedSource,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: canOpen ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (_unavailable)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(
                context.tr('studySourceUnavailable'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ),
        ],
      ),
    );
    return canOpen
        ? Semantics(
            button: true,
            label: displayedSource,
            child: InkWell(onTap: _openSource, child: content),
          )
        : content;
  }
}

/// A typed note for reading: headings, paragraphs, lists, tables, figures,
/// handwriting and cards, as they are stored.
class TypedNoteReader extends StatelessWidget {
  final TypedDocument document;
  final AttachmentCache files;
  final String? title;

  /// The author line under the title on the formal page (annotations#40).
  final String? byline;
  final ValueChanged<String>? onOpen;
  final bool publicProjection;
  final ReportsEmbedSource? reportsSource;
  final String? trustedReportsAccountId;
  final String reportsLanguage;
  final Future<TaskSummary?> Function(String taskId)? loadTaskCard;
  final Future<QuizSummary?> Function(String quizId)? loadQuizCard;
  final ValueChanged<String>? onOpenQuiz;
  const TypedNoteReader({
    super.key,
    required this.document,
    required this.files,
    this.title,
    this.byline,
    this.onOpen,
    this.publicProjection = false,
    this.reportsSource,
    this.trustedReportsAccountId,
    this.reportsLanguage = 'en',
    this.loadTaskCard,
    this.loadQuizCard,
    this.onOpenQuiz,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = annotationsTextStyle.copyWith(color: c.text);
    InlineSpan spans(Object? raw, TextStyle style) => TextSpan(
      style: style,
      children: [
        for (final s in (raw as List? ?? const []).cast<Map>())
          TextSpan(text: s['text'] as String? ?? '', style: _inline(s)),
      ],
    );
    final children = <Widget>[
      if (title != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            title!,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: c.text,
            ),
          ),
        ),
      if (byline != null)
        Padding(
          key: const Key('typed-byline'),
          padding: const EdgeInsets.only(bottom: 20),
          child: Text(byline!, style: TextStyle(color: c.textSecondary)),
        ),
    ];
    for (final b in document.blocks) {
      final j = b.toJson();
      switch (j['kind']) {
        case 'heading':
          final level = (j['level'] as int?) ?? 1;
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text.rich(
                spans(
                  j['spans'],
                  base.copyWith(
                    fontSize: switch (level) {
                      1 => 28.0,
                      2 => 22.0,
                      3 => 18.0,
                      _ => 16.0,
                    },
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        case 'paragraph':
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text.rich(spans(j['spans'], base)),
            ),
          );
        case 'list':
          final ordered = j['ordered'] == true;
          final items = (j['items'] as List? ?? const []).cast<Map>();
          for (final (i, it) in items.indexed) {
            children.add(
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(ordered ? '${i + 1}.' : '•', style: base),
                    ),
                    Expanded(child: Text.rich(spans(it['spans'], base))),
                  ],
                ),
              ),
            );
          }
        case 'table':
          // `header` marks the first row as the header row.
          final header = j['header'] == true;
          final rows = (j['rows'] as List? ?? const []).cast<Map>();
          Widget cell(Map cell, bool bold) => Padding(
            padding: const EdgeInsets.all(6),
            child: Text.rich(
              spans(
                cell['spans'],
                bold ? base.copyWith(fontWeight: FontWeight.w600) : base,
              ),
            ),
          );
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder.all(color: c.border),
                  children: [
                    for (final (i, r) in rows.indexed)
                      TableRow(
                        children: [
                          for (final x
                              in (r['cells'] as List? ?? const []).cast<Map>())
                            cell(x, header && i == 0),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        default:
          final kind = j['kind'];
          if (j['restricted'] == true ||
              (publicProjection &&
                  const {
                    'reports_embed',
                    'task_card',
                    'quiz_card',
                  }.contains(kind))) {
            // Keeps the block's place with a lock (annotations#40).
            children.add(
              Container(
                key: Key('locked-${j['id']}'),
                height: 96,
                margin: const EdgeInsets.symmetric(vertical: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.subtle,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: c.border),
                ),
                child: const AppIcon(AppIcons.lock, size: 24),
              ),
            );
          } else {
            if (j['kind'] == 'quiz_card') {
              children.add(
                _TypedQuizCard(
                  key: ValueKey('typed-quiz-${j['id']}'),
                  item: j,
                  load: loadQuizCard,
                  onOpen: onOpenQuiz,
                ),
              );
            } else if (j['kind'] == 'task_card') {
              children.add(
                _TypedTaskCard(
                  key: ValueKey('typed-task-${j['id']}'),
                  item: j,
                  load: loadTaskCard,
                ),
              );
            } else if (j['kind'] == 'reports_embed') {
              children.add(
                _TypedReportsCard(
                  key: ValueKey('typed-reports-${j['id']}'),
                  item: j,
                  source: reportsSource,
                  trustedAccountId: trustedReportsAccountId,
                  language: reportsLanguage,
                ),
              );
            } else {
              children.add(
                _BlockPicture(json: j, files: files, onOpen: onOpen),
              );
            }
          }
      }
    }
    return ColoredBox(
      key: const Key('typed-reader'),
      color: c.page,
      child: ListView(padding: const EdgeInsets.all(16), children: children),
    );
  }

  TextStyle _inline(Map s) => TextStyle(
    fontWeight: s['bold'] == true ? FontWeight.bold : null,
    fontStyle: s['italic'] == true ? FontStyle.italic : null,
    decoration: s['strikethrough'] == true ? TextDecoration.lineThrough : null,
    fontSize: (s['size'] as num?)?.toDouble(),
    color: s['color'] is String
        ? Color(colorArgb(s['color'] as String, 1))
        : null,
  );
}

/// Figures, handwriting and cards of a typed note, drawn as on paper.
class _BlockPicture extends StatelessWidget {
  final Map<String, Object?> json;
  final AttachmentCache files;
  final ValueChanged<String>? onOpen;
  const _BlockPicture({required this.json, required this.files, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth.clamp(1.0, 480.0);
        final kind = json['kind'];
        final Map<String, Object?> item = kind == 'figure'
            ? {'kind': 'image', 'file_id': json['file_id']}
            : json;
        double height;
        if (kind == 'handwriting') {
          final w = (json['width'] as num?)?.toDouble() ?? width;
          final h = (json['height'] as num?)?.toDouble() ?? 80;
          height = h * width / w;
        } else {
          height =
              measureCard(
                item,
                width,
                CardStyle(text: annotationsTextStyle, colors: c),
                files,
              ) ??
              width * 9 / 16;
        }
        return ListenableBuilder(
          listenable: files,
          builder: (context, _) => GestureDetector(
            onTap: json['url'] is String
                ? () => onOpen?.call(json['url'] as String)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: CustomPaint(
                size: Size(width, height),
                painter: _BlockPainter(item, c, files, files.version),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TypedTaskCard extends StatefulWidget {
  const _TypedTaskCard({super.key, required this.item, required this.load});

  final Map<String, Object?> item;
  final Future<TaskSummary?> Function(String taskId)? load;

  @override
  State<_TypedTaskCard> createState() => _TypedTaskCardState();
}

class _TypedTaskCardState extends State<_TypedTaskCard> {
  TaskSummary? _task;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;

  String? get _taskId {
    final raw = widget.item['task_id'];
    return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_TypedTaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item['task_id'] != widget.item['task_id'] ||
        oldWidget.load != widget.load) {
      _task = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final id = _taskId;
    final loader = widget.load;
    final generation = ++_generation;
    if (id == null || loader == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await loader(id);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (result?.taskId == id) {
          _task = result;
        } else {
          _failed = true;
        }
        _loading = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TaskCardView(
      task: _task,
      loading: _loading,
      unavailable: _failed,
      onRetry: _failed ? _load : null,
    ),
  );
}

class _TypedReportsCard extends StatefulWidget {
  const _TypedReportsCard({
    super.key,
    required this.item,
    required this.source,
    required this.trustedAccountId,
    required this.language,
  });

  final Map<String, Object?> item;
  final ReportsEmbedSource? source;
  final String? trustedAccountId;
  final String language;

  @override
  State<_TypedReportsCard> createState() => _TypedReportsCardState();
}

class _TypedReportsCardState extends State<_TypedReportsCard> {
  ReportsEmbedData? _data;
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_TypedReportsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item['id'] != widget.item['id'] ||
        !_sameReportsReference(oldWidget.item, widget.item) ||
        oldWidget.source != widget.source ||
        oldWidget.trustedAccountId != widget.trustedAccountId ||
        oldWidget.language != widget.language) {
      _generation++;
      _data = null;
      _loading = false;
      _load();
    }
  }

  bool _sameReportsReference(
    Map<String, Object?> oldItem,
    Map<String, Object?> newItem,
  ) => const [
    'project_slug',
    'report_slug',
    'dataset_id',
    'report_id',
    'mode',
    'snapshot_id',
    'captured_at',
    'source',
    'restricted',
  ].every((field) => oldItem[field] == newItem[field]);

  Future<void> _load() async {
    final generation = ++_generation;
    final source = widget.source;
    setState(() => _loading = true);
    try {
      final result = source == null
          ? const ReportsEmbedData(
              state: ReportsEmbedState.signInRequired,
              reference: null,
            )
          : await source.loadDocument(
              widget.item,
              trustedAccountId: widget.trustedAccountId,
              language: widget.language,
            );
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = result;
        _loading = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = const ReportsEmbedData(
          state: ReportsEmbedState.unavailable,
          reference: null,
        );
        _loading = false;
      });
    }
  }

  VoidCallback? get _open {
    final value = _data?.openInReportsUrl;
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'reports.asodya.com') {
      return null;
    }
    return () => launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: SizedBox(
      height: 224,
      child: ReportsEmbedCard(
        data: _data,
        loading: _loading,
        snapshot: widget.item['mode'] == 'snapshot',
        onRetry: widget.source == null ? null : _load,
        onOpen: _open,
      ),
    ),
  );
}

class _TypedQuizCard extends StatefulWidget {
  const _TypedQuizCard({
    super.key,
    required this.item,
    required this.load,
    required this.onOpen,
  });

  final Map<String, Object?> item;
  final Future<QuizSummary?> Function(String quizId)? load;
  final ValueChanged<String>? onOpen;

  @override
  State<_TypedQuizCard> createState() => _TypedQuizCardState();
}

class _TypedQuizCardState extends State<_TypedQuizCard> {
  QuizSummary? _quiz;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;

  String? get _quizId {
    final raw = widget.item['quiz_id'];
    if (raw is! String || raw.trim().isEmpty) return null;
    return raw.trim();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_TypedQuizCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item['quiz_id'] != widget.item['quiz_id'] ||
        oldWidget.load != widget.load) {
      _quiz = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final quizId = _quizId;
    final loader = widget.load;
    final generation = ++_generation;
    if (quizId == null || loader == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await loader(quizId);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (result?.quizId == quizId) {
          _quiz = result;
        } else {
          _failed = true;
        }
        _loading = false;
      });
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: QuizCardView(
      quiz: _quiz,
      loading: _loading,
      unavailable: _failed,
      onRetry: _failed ? _load : null,
      onOpen: _quizId == null ? null : () => widget.onOpen?.call(_quizId!),
    ),
  );
}

class _BlockPainter extends CustomPainter {
  _BlockPainter(this.item, this.colors, this.files, this.version);
  final Map<String, Object?> item;
  final AppColors colors;
  final AttachmentCache files;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    if (item['kind'] == 'handwriting') {
      final w = (item['width'] as num?)?.toDouble() ?? size.width;
      canvas.scale(size.width / w);
      for (final raw
          in (item['ink'] as List? ?? const []).cast<Map<String, Object?>>()) {
        final it = DocumentItem.fromJson(raw, family: DocumentFamily.typed);
        final outline = it is StrokeItem ? strokeOutline(it) : null;
        if (outline == null) continue;
        final path = Path();
        for (final piece in outline.pieces) {
          path.addPolygon([for (final v in piece) Offset(v.x, v.y)], true);
        }
        canvas.drawPath(path, Paint()..color = Color(outline.argb));
      }
      return;
    }
    final card = CardLayout(
      item,
      size.width,
      CardStyle(text: annotationsTextStyle, colors: colors),
      files,
    );
    card.paint(canvas, Offset.zero & size);
    card.dispose();
  }

  @override
  bool shouldRepaint(_BlockPainter old) =>
      old.version != version || old.item != item;
}
