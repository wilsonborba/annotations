import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../domain/models/note_document.dart';
import '../../../../domain/models/reports_embed_data.dart';
import '../../../../domain/services/quiz_card_service.dart';
import '../../../../domain/services/reports_embed_source.dart';
import '../../../../domain/services/task_card_service.dart';
import '../../../../core/landing_settings.dart';
import '../../components/reports_embed_card.dart';
import '../../components/quiz_card_view.dart';
import '../../components/task_card_view.dart';
import '../../handlers/paper_handler.dart';

/// Live projections for Reports and task references in a paper note.
/// The caller must pass a trusted installed account id from its auth scope.
class NoteEmbeddedCardsLayer extends StatefulWidget {
  const NoteEmbeddedCardsLayer({
    super.key,
    required this.document,
    required this.view,
    this.reportsSource,
    this.trustedAccountId,
    this.publicProjection = false,
    this.language = 'en',
    this.loadTask,
    this.loadQuiz,
    this.quizOnly = false,
    this.onSignIn,
  });

  final NoteDocument document;
  final PaperView view;
  final ReportsEmbedSource? reportsSource;
  final String? trustedAccountId;
  final bool publicProjection;
  final String language;
  final Future<TaskSummary?> Function(String taskId)? loadTask;
  final Future<QuizSummary?> Function(String quizId)? loadQuiz;
  final bool quizOnly;
  final VoidCallback? onSignIn;

  @override
  State<NoteEmbeddedCardsLayer> createState() => _NoteEmbeddedCardsLayerState();
}

class _NoteEmbeddedCardsLayerState extends State<NoteEmbeddedCardsLayer> {
  final _reports = <String, ReportsEmbedData>{};
  final _tasks = <String, TaskSummary>{};
  final _quizzes = <String, QuizSummary>{};
  final _quizFailures = <String>{};
  final _loading = <String>{};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void didUpdateWidget(NoteEmbeddedCardsLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.document, widget.document) ||
        old.reportsSource != widget.reportsSource ||
        old.trustedAccountId != widget.trustedAccountId ||
        old.publicProjection != widget.publicProjection ||
        old.language != widget.language ||
        old.loadTask != widget.loadTask ||
        old.loadQuiz != widget.loadQuiz ||
        old.quizOnly != widget.quizOnly) {
      _reports.clear();
      _tasks.clear();
      _quizzes.clear();
      _quizFailures.clear();
      _loading.clear();
      _loadAll();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  List<Map<String, dynamic>> get _items => widget.document is PaperDocument
      ? (widget.document.toJson()['items'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where((item) => !widget.quizOnly || item['kind'] == 'quiz_card')
            .toList(growable: false)
      : const [];

  void _loadAll() {
    final seq = ++_generation;
    for (final item in _items) {
      final id = item['id'];
      if (id is! String || id.isEmpty) continue;
      if (item['kind'] == 'reports_embed') {
        _loadReport(item, id, seq);
      } else if (item['kind'] == 'task_card') {
        _loadTask(item, id, seq);
      } else if (item['kind'] == 'quiz_card') {
        _loadQuiz(item, id, seq);
      }
    }
  }

  Future<void> _loadQuiz(Map<String, dynamic> item, String id, int seq) async {
    if (widget.publicProjection) return;
    final quizId = item['quiz_id'];
    final load = widget.loadQuiz;
    if (quizId is! String || quizId.trim().isEmpty || load == null) {
      if (mounted && seq == _generation) {
        setState(() => _quizFailures.add(id));
      }
      return;
    }
    setState(() => _loading.add(id));
    try {
      final result = await load(quizId);
      if (!mounted || seq != _generation) return;
      if (result == null || result.quizId != quizId) {
        setState(() => _quizFailures.add(id));
      } else {
        setState(() {
          _quizzes[id] = result;
          _quizFailures.remove(id);
        });
      }
    } on Object {
      if (!mounted || seq != _generation) return;
      setState(() => _quizFailures.add(id));
    } finally {
      if (mounted && seq == _generation) setState(() => _loading.remove(id));
    }
  }

  Future<void> _loadReport(
    Map<String, dynamic> item,
    String id,
    int seq,
  ) async {
    final source = widget.reportsSource;
    if (source == null) {
      final state = widget.publicProjection
          ? ReportsEmbedState.restricted
          : ReportsEmbedState.signInRequired;
      if (mounted && seq == _generation) {
        setState(
          () => _reports[id] = ReportsEmbedData(state: state, reference: null),
        );
      }
      return;
    }
    setState(() => _loading.add(id));
    try {
      final result = await source.loadDocument(
        item,
        trustedAccountId: widget.trustedAccountId,
        language: widget.language,
        publicProjection: widget.publicProjection,
      );
      if (!mounted || seq != _generation) return;
      setState(() => _reports[id] = result);
    } on Object {
      if (!mounted || seq != _generation) return;
      setState(
        () => _reports[id] = ReportsEmbedData(
          state: ReportsEmbedState.unavailable,
          reference: null,
        ),
      );
    } finally {
      if (mounted && seq == _generation) setState(() => _loading.remove(id));
    }
  }

  Future<void> _loadTask(Map<String, dynamic> item, String id, int seq) async {
    if (widget.publicProjection) return;
    final taskId = item['task_id'];
    final load = widget.loadTask;
    if (taskId is! String || taskId.isEmpty || load == null) return;
    setState(() => _loading.add(id));
    try {
      final result = await load(taskId);
      if (!mounted || seq != _generation) return;
      if (result != null) setState(() => _tasks[id] = result);
    } on Object {
      // A failed refresh leaves any already permitted saved details visible.
    } finally {
      if (mounted && seq == _generation) setState(() => _loading.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final item in items)
          if (item['id'] is String)
            if (_bounds(item) case final Rect rect)
              if (item['kind'] == 'reports_embed')
                Positioned.fromRect(
                  rect: widget.view.rectToScreen(rect),
                  child: ReportsEmbedCard(
                    data: _reports[item['id']],
                    loading: _loading.contains(item['id']),
                    snapshot: item['mode'] == 'snapshot',
                    onRetry: widget.publicProjection
                        ? null
                        : () => _loadReport(
                            item,
                            item['id'] as String,
                            _generation,
                          ),
                    onSignIn: widget.onSignIn,
                    onOpen: _openReports(_reports[item['id']]),
                  ),
                )
              else if (item['kind'] == 'task_card')
                Positioned(
                  left: widget.view.toScreen(Offset(rect.left, rect.top)).dx,
                  top: widget.view.toScreen(Offset(rect.left, rect.top)).dy,
                  width: rect.width * widget.view.zoom,
                  child: TaskCardView(
                    task: _tasks[item['id']],
                    loading: _loading.contains(item['id']),
                    restricted: widget.publicProjection,
                    unavailable:
                        !widget.publicProjection &&
                        !_loading.contains(item['id']) &&
                        _tasks[item['id']] == null,
                    onRetry: widget.publicProjection || widget.loadTask == null
                        ? null
                        : () => _loadTask(
                            item,
                            item['id'] as String,
                            _generation,
                          ),
                  ),
                )
              else if (item['kind'] == 'quiz_card')
                Positioned(
                  left: widget.view.toScreen(Offset(rect.left, rect.top)).dx,
                  top: widget.view.toScreen(Offset(rect.left, rect.top)).dy,
                  width: rect.width * widget.view.zoom,
                  child: QuizCardView(
                    quiz: _quizzes[item['id']],
                    loading: _loading.contains(item['id']),
                    restricted: widget.publicProjection,
                    unavailable:
                        !widget.publicProjection &&
                        !_loading.contains(item['id']) &&
                        (_quizFailures.contains(item['id']) ||
                            _quizzes[item['id']] == null),
                    onRetry: widget.publicProjection || widget.loadQuiz == null
                        ? null
                        : () => _loadQuiz(
                            item,
                            item['id'] as String,
                            _generation,
                          ),
                    onOpen:
                        item['quiz_id'] is String &&
                            (item['quiz_id'] as String).trim().isNotEmpty
                        ? () {
                            final uri = Uri.parse(
                              '${LandingSettings.certifications}/v1/quizzes/${Uri.encodeComponent((item['quiz_id'] as String).trim())}',
                            );
                            launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        : null,
                  ),
                ),
      ],
    );
  }

  Rect? _bounds(Map<String, dynamic> item) {
    final x = item['x'], y = item['y'], w = item['width'], h = item['height'];
    if ([x, y, w, h].any((value) => value is! num)) return null;
    final rect = Rect.fromLTWH(
      (x as num).toDouble(),
      (y as num).toDouble(),
      (w as num).toDouble(),
      (h as num).toDouble(),
    );
    return rect.isFinite && rect.width > 0 && rect.height > 0 ? rect : null;
  }

  VoidCallback? _openReports(ReportsEmbedData? data) {
    final value = data?.openInReportsUrl;
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'reports.asodya.com') {
      return null;
    }
    return () => launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
