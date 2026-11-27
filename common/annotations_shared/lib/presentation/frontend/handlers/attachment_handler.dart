/// Files and links on the paper (annotations#34, B9).
///
/// Adding: the file picker, paste and drag and drop give files and links.
/// A file is first copied into the local store; while it copies, a job
/// shows its name at the place where the card will be, and only a finished
/// copy becomes a card (never "ready" before the file is available). A
/// failed copy offers Retry or Cancel. Adding a file to a local note never
/// uploads it: the store has no network code.
///
/// Placing: the card goes to the first free place at or below the drop or
/// pointer position on the grid; it never covers or pushes a block (B9.2).
///
/// Actions: pictures and files Open, Save a copy, Replace and Remove; links
/// Open, Copy link, Edit link and Remove. Remove changes only the note: the
/// original file on the computer is never touched. Replace keeps the place
/// and the size, and a failure keeps the original.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/note_limits.dart';
import '../../../domain/models/local_note.dart';
import '../../../domain/models/note_document.dart';
import '../../../domain/services/card_content.dart';
import '../../../domain/services/editor_rules.dart';
import '../../../domain/services/note_history.dart';
import '../../../domain/services/object_selection.dart';
import '../components/card_layout.dart';
import '../components/tokens.dart';
import 'paper_handler.dart';

/// A file to add: a path on this device, or bytes (web, paste).
@immutable
final class AttachmentSource {
  const AttachmentSource.path(String this.path, {required this.name})
    : bytes = null;
  const AttachmentSource.bytes(Uint8List this.bytes, {required this.name})
    : path = null;
  final String? path;
  final Uint8List? bytes;
  final String name;
  String get type => mediaTypeFor(name);
}

enum AttachmentJobState { copying, failed }

/// A file that is being copied, or whose copy failed.
final class AttachmentJob {
  AttachmentJob._(this.source, this.at, this.replacing);
  final AttachmentSource source;

  /// Where the card goes, in page units.
  final Offset at;

  /// The item that the file replaces, or null for a new card.
  final String? replacing;
  AttachmentJobState state = AttachmentJobState.copying;
  bool cancelled = false;
}

/// What a link card knows from the server (annotations_api#28): title,
/// site name, description. Null when there is no preview.
typedef LinkPreviewSource = Future<Map<String, Object?>?> Function(String url);

class AttachmentHandler extends ChangeNotifier {
  AttachmentHandler({
    required this.paper,
    this.preview,
    String Function()? newId,
    this.pickFiles,
    this.saveLocation,
    this.launch,
  }) : newId = newId ?? _randomId;

  final PaperHandler paper;

  /// Link previews from the server for cloud notes; null keeps links local.
  final LinkPreviewSource? preview;
  final String Function() newId;

  /// The file picker and the save dialog; the defaults are the system ones.
  final Future<List<fs.XFile>> Function()? pickFiles;
  final Future<String?> Function(String suggestedName)? saveLocation;

  /// Opens a link or a file with the system; the default is url_launcher.
  final Future<bool> Function(Uri uri)? launch;

  final jobs = ValueNotifier<List<AttachmentJob>>(const []);

  static String _randomId() {
    final r = math.Random.secure();
    return [
      for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16),
    ].map((h) => h.padLeft(2, '0')).join();
  }

  CardStyle get _style =>
      CardStyle(text: paper.textStyle, colors: AppColors.light);

  /// Where a new card goes without a drop point: the last pointer position
  /// on the page, or near the top left of the visible page.
  Offset defaultPlace([Offset? at]) {
    if (at != null) return at;
    final v = paper.view.value;
    return v == null
        ? const Offset(24, 24)
        : v.visiblePage.topLeft + const Offset(24, 24);
  }

  // Adding ---------------------------------------------------------------

  /// Opens the file picker and adds the chosen files at [at].
  Future<void> pick({Offset? at}) async {
    if (!paper.editingEnabled) return;
    final files = await (pickFiles ?? fs.openFiles)();
    if (!paper.editingEnabled) return;
    var place = defaultPlace(at);
    for (final f in files) {
      add(AttachmentSource.path(f.path, name: f.name), place);
      place += const Offset(0, 16);
    }
  }

  /// Copies [source] into the store and adds its card at [at]. The job
  /// shows until the card is there or the user cancels.
  void add(AttachmentSource source, Offset at, {String? replacing}) {
    if (!paper.editingEnabled) return;
    final job = AttachmentJob._(source, at, replacing);
    jobs.value = [...jobs.value, job];
    unawaited(_run(job));
  }

  Future<void> _run(AttachmentJob job) async {
    final store = paper.autosave.files;
    LocalAttachment? stored;
    try {
      final s = job.source;
      stored = s.path != null
          ? await store.importFile(s.path!, type: s.type)
          : await store.importBytes(s.bytes!, name: s.name, type: s.type);
      if (job.cancelled || !paper.editingEnabled) {
        await store.discardAttachment(stored.id);
        return;
      }
      paper.files.remember(stored);
      final item = await _itemFor(stored);
      if (!paper.editingEnabled) {
        await store.discardAttachment(stored.id);
        return;
      }
      final placed = job.replacing == null
          ? _placeNew(item, job.at)
          : _replace(job.replacing!, item);
      if (!placed) {
        await store.discardAttachment(stored.id);
        _fail(job);
        return;
      }
      _finish(job);
    } on Object {
      if (stored != null) await store.discardAttachment(stored.id);
      if (!job.cancelled) _fail(job);
    }
  }

  void _fail(AttachmentJob job) {
    job.state = AttachmentJobState.failed;
    jobs.value = [...jobs.value];
    notifyListeners();
  }

  void _finish(AttachmentJob job) {
    jobs.value = [
      for (final j in jobs.value)
        if (!identical(j, job)) j,
    ];
    notifyListeners();
  }

  /// Copies the file of a failed job again.
  void retry(AttachmentJob job) {
    if (!paper.editingEnabled) return;
    job.state = AttachmentJobState.copying;
    job.cancelled = false;
    jobs.value = [...jobs.value];
    unawaited(_run(job));
  }

  /// Drops a job: a copy that is still running is discarded when it ends.
  void cancel(AttachmentJob job) {
    job.cancelled = true;
    _finish(job);
  }

  /// The card JSON of a stored file, without its place.
  Future<Map<String, Object?>> _itemFor(LocalAttachment file) async {
    final kind = cardKindFor(file.type);
    final id = newId();
    final store = paper.autosave.files;
    switch (kind) {
      case 'image':
        var (w, h) = (320.0, 240.0);
        final bytes = await store.readAttachment(file.id);
        if (bytes != null) {
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          w = frame.image.width.toDouble();
          h = frame.image.height.toDouble();
          frame.image.dispose();
          codec.dispose();
        }
        final width = _gridWidth(math.min(w, 400));
        return {
          'id': id,
          'kind': 'image',
          'width': width,
          'height': _round(width * h / math.max(w, 1)),
          'file_id': file.id,
        };
      case 'pdf_preview':
        final bytes = await store.readAttachment(file.id);
        final info = bytes == null ? null : pdfInfo(bytes);
        final width = _gridWidth(240);
        final ratio = info == null ? 842 / 595 : info.height / info.width;
        return {
          'id': id,
          'kind': 'pdf_preview',
          'width': width,
          'height': _round(width * ratio),
          'file_id': file.id,
        };
      case 'csv_table':
        return {
          'id': id,
          'kind': 'csv_table',
          'width': _gridWidth(480),
          'height': 240,
          'file_id': file.id,
        };
      default:
        final item = <String, Object?>{
          'id': id,
          'kind': 'file_card',
          'width': _gridWidth(320),
          'file_id': file.id,
        };
        item['height'] = _measure(item);
        return item;
    }
  }

  /// A width on the grid that fits the page.
  int _gridWidth(num width) {
    final page = EditorGrid.floor(paper.pageWidth);
    return math.max(EditorGrid.cell, math.min(EditorGrid.round(width), page));
  }

  num _round(num v) => (v * 100).round() / 100;

  /// Places an already-prepared structured card using the same snapping,
  /// free-space search, overlap validation and history path as imported
  /// attachments. The caller must have completed any required owner-scoped
  /// creation before invoking this method.
  bool addStructuredCard(Map<String, Object?> item, {Offset? at}) {
    if (!paper.editingEnabled ||
        item['id'] is! String ||
        item['kind'] is! String ||
        item['width'] is! num ||
        item['height'] is! num) {
      return false;
    }
    final normalized = {...item, 'width': _gridWidth(item['width'] as num)};
    return _placeNew(normalized, defaultPlace(at));
  }

  num _measure(Map<String, Object?> item) =>
      measureCard(
        item,
        (item['width'] as num).toDouble(),
        _style,
        paper.files,
      ) ??
      (item['height'] as num? ?? 80);

  /// Adds [item] at the first free grid place at or below [at]. False when
  /// no place is found in a long stretch of the page.
  bool _placeNew(Map<String, Object?> item, Offset at) {
    final width = item['width'] as num;
    final x = EditorGrid.floor(
      at.dx.clamp(0, math.max(0, paper.pageWidth - width)),
    );
    final y0 = EditorGrid.floor(math.max(0, at.dy));
    final document = paper.document;
    for (var step = 0; step < 2000; step++) {
      final y = y0 + step * EditorGrid.cell;
      final candidate = {...item, 'x': x, 'y': y};
      // A free cell around a new card, so cards do not touch (a probe
      // only: the card itself keeps its size).
      const gap = EditorGrid.cell;
      final room = {
        ...item,
        'x': math.max(0, x - gap),
        'y': math.max(0, y - gap),
        'width': math.min(
          (item['width'] as num) + 2 * gap,
          EditorGrid.floor(paper.pageWidth),
        ),
        'height': (item['height'] as num) + 2 * gap,
      };
      final probe = paper.session.rules.check(document, {
        'op': 'add',
        'item': room,
      });
      final d = probe.accepted
          ? paper.session.rules.check(document, {
              'op': 'add',
              'item': candidate,
            })
          : probe;
      if (d.accepted) {
        final decision = paper.apply(
          HistoryCommand(CommandKind.card),
          (rules, doc) => rules.check(doc, {'op': 'add', 'item': candidate}),
        );
        if (decision.accepted) {
          paper.select(ObjectSelection([candidate['id'] as String]));
        }
        return decision.accepted;
      }
      if (d.error?.rule != EditorRule.blockOverlap &&
          d.error?.rule != EditorRule.groupOverlap) {
        return false;
      }
    }
    return false;
  }

  /// Puts [item] where [id] is, with its place and size (B9.4); with
  /// [keepSize] false only the place is kept.
  bool _replace(String id, Map<String, Object?> item, {bool keepSize = true}) {
    final old = _json(id);
    if (old == null) return false;
    final next = {
      ...item,
      'id': id,
      for (final k in [
        'x',
        'y',
        if (keepSize) ...['width', 'height'],
      ])
        k: old[k],
    };
    final op = next['kind'] == old['kind']
        ? {'op': 'replace', 'item': next}
        : {
            'op': 'batch',
            'steps': [
              {'op': 'delete', 'id': id},
              {'op': 'add', 'item': next},
            ],
          };
    return paper
        .apply(
          HistoryCommand(CommandKind.card),
          (rules, doc) => rules.check(doc, op),
        )
        .accepted;
  }

  Map<String, Object?>? _json(String id) {
    final d = paper.document;
    if (d is! PaperDocument) return null;
    for (final it in d.itemsJson) {
      if (it['id'] == id) return it;
    }
    return null;
  }

  /// Adds a link card (a YouTube card for YouTube links) at [at]. False
  /// when [text] is not one web link or no place was found.
  Future<bool> addLink(String text, {Offset? at}) async {
    if (!paper.editingEnabled) return false;
    final url = webLink(text);
    if (url == null) return false;
    final item = await _linkItem(newId(), url);
    return _placeNew(item, defaultPlace(at));
  }

  Future<Map<String, Object?>> _linkItem(String id, String url) async {
    final youtube = isYoutubeUrl(url);
    Map<String, Object?>? data;
    if (preview case final p?) {
      try {
        data = await p(url);
      } on Object {
        data = null;
      }
    }
    String? text(String key) {
      final v = data?[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final description = text('description');
    final kind = youtube
        ? 'youtube_card'
        : description != null
        ? 'website_card'
        : 'link_card';
    final item = <String, Object?>{
      'id': id,
      'kind': kind,
      'width': _gridWidth(kind == 'link_card' ? 320 : 400),
      'url': url,
      'title': ?text('title'),
      if (!youtube && text('site_name') != null) 'site_name': text('site_name'),
      if (kind == 'website_card') 'description': description,
    };
    item['height'] = _measure(item);
    return item;
  }

  /// Adds dropped (or pasted) files and links at [at] (page units).
  Future<void> drop(List<String> paths, List<String> texts, Offset at) async {
    if (!paper.editingEnabled) return;
    var place = at;
    for (final path in paths) {
      final name = path.split(RegExp(r'[/\\]')).lastWhere((s) => s.isNotEmpty);
      add(AttachmentSource.path(path, name: name), place);
      place += const Offset(0, 16);
    }
    for (final text in texts) {
      if (await addLink(text, at: place)) place += const Offset(0, 16);
    }
  }

  /// A wheel over a CSV table scrolls the table (internal scrolling).
  /// True when the table took it.
  bool wheel(Offset screen, Offset delta) {
    final v = paper.view.value, d = paper.document;
    if (v == null || d is! PaperDocument) return false;
    final p = v.toPage(screen);
    for (final it in d.itemsJson.reversed) {
      if (it['kind'] != 'csv_table') continue;
      final r = Rect.fromLTWH(
        (it['x'] as num).toDouble(),
        (it['y'] as num).toDouble(),
        (it['width'] as num).toDouble(),
        (it['height'] as num).toDouble(),
      );
      if (!r.contains(p)) continue;
      return paper.files.scrollTable(
        it['id'] as String,
        it['file_id'] as String,
        r.size,
        delta / v.zoom,
      );
    }
    return false;
  }

  // Actions --------------------------------------------------------------

  /// The kind of the one selected card, or null.
  String? cardKind(String id) {
    final kind = _json(id)?['kind'];
    return isCardKind(kind) ? kind as String : null;
  }

  bool isLink(String id) => const {
    'link_card',
    'website_card',
    'youtube_card',
  }.contains(cardKind(id));

  Future<bool> _launch(Uri uri) =>
      (launch ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(
        uri,
      );

  /// Opens a web link with the system browser.
  Future<bool> launchLink(String url) => _launch(Uri.parse(url));

  /// Opens the link, or the stored copy of the file with the system.
  Future<bool> open(String id) async {
    final it = _json(id);
    if (it == null || it['restricted'] == true) return false;
    if (it['url'] case final String url) return _launch(Uri.parse(url));
    final fileId = it['file_id'] as String?;
    final file = fileId == null
        ? null
        : await paper.autosave.files.attachment(fileId);
    if (file == null) return false;
    return _launch(Uri.file(file.path));
  }

  /// Saves a copy of the stored file where the user chooses.
  Future<bool> saveCopy(String id) async {
    final fileId = _json(id)?['file_id'] as String?;
    if (fileId == null) return false;
    final store = paper.autosave.files;
    final file = await store.attachment(fileId);
    final bytes = await store.readAttachment(fileId);
    if (file == null || bytes == null) return false;
    final path = await (saveLocation ?? _saveLocation)(file.name);
    if (path == null) return false;
    await fs.XFile.fromData(bytes, name: file.name).saveTo(path);
    return true;
  }

  static Future<String?> _saveLocation(String name) async =>
      (await fs.getSaveLocation(suggestedName: name))?.path;

  /// Picks one file and puts it where [id] is.
  Future<void> replace(String id) async {
    if (!paper.editingEnabled) return;
    final it = _json(id);
    if (it == null) return;
    final files = await (pickFiles ?? fs.openFiles)();
    if (files.isEmpty) return;
    final f = files.first;
    add(
      AttachmentSource.path(f.path, name: f.name),
      Offset((it['x'] as num).toDouble(), (it['y'] as num).toDouble()),
      replacing: id,
    );
  }

  /// Removes the card from the note (after the user confirmed). The file
  /// on the computer stays; other notes keep their copies.
  bool remove(String id) =>
      paper.editingEnabled &&
      paper
          .apply(
            HistoryCommand(CommandKind.remove),
            (rules, doc) => rules.remove(doc, [id]),
          )
          .accepted;

  Future<void> copyLink(String id) async {
    if (_json(id)?['url'] case final String url) {
      await Clipboard.setData(ClipboardData(text: url));
    }
  }

  /// Gives the link card [id] the link [text]. A taller card that would
  /// overlap a block is rejected (type C). False when nothing changed.
  Future<bool> editLink(String id, String text) async {
    if (!paper.editingEnabled) return false;
    final old = _json(id);
    final url = webLink(text);
    if (old == null || url == null) return false;
    final fresh = await _linkItem(id, url);
    final next = {
      ...fresh,
      'x': old['x'],
      'y': old['y'],
      'width': old['width'],
    };
    next['height'] = _measure(next);
    return _replace(id, next, keepSize: false);
  }

  @override
  void dispose() {
    jobs.dispose();
    super.dispose();
  }
}
