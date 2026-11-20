// Real in-app screenshots for the landing showcase (annotations#53, H6
// point 13): the writer on a desktop, a typed note on a phone and a public
// note in the browser, rendered from the app widgets with sample notes.
//
// Run with LANDING_CAPTURE_DIR=<folder> to write the PNG files; the landing
// assets are made from them (see assets/image_sources.md). Without the
// variable the test is skipped.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:annotations_shared/app.dart';
import 'package:annotations_shared/core/platform_profile.dart';
import 'package:annotations_shared/domain/models/note_document.dart';
import 'package:annotations_shared/domain/models/stroke_samples_codec.dart';
import 'package:annotations_shared/presentation/frontend/widgets/paper/paper_screen.dart';
import 'package:annotations_shared/presentation/frontend/widgets/typed/note_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'design_goldens_test.dart' show loadAppFonts;
import 'fixtures.dart';
import 'package:annotations_shared/domain/services/note_autosave.dart';
import 'package:annotations_shared/presentation/frontend/handlers/paper_handler.dart';
import 'paper_canvas_test.dart'
    show MemoryStore, handlerFor, host, schema, text;
import 'phone_notes_test.dart' show typed;

final out = Platform.environment['LANDING_CAPTURE_DIR'];

/// A pen stroke through [points] (page units), sampled like real ink.
Map<String, Object?> ink(
  String id,
  List<Offset> points, {
  num width = 3,
  String color = '#3B82F6FF',
  String tool = 'round',
  num opacity = 1,
}) {
  final xs = <int>[], ys = <int>[];
  final random = Random(id.hashCode);
  final at = <int>[];
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i], b = points[i + 1];
    at.add(xs.length);
    final steps = max(2, ((b - a).distance / 6).round());
    for (var s = 0; s < steps; s++) {
      final p = Offset.lerp(a, b, s / steps)!;
      xs.add(((p.dx + random.nextDouble() * .6) * 100).round());
      ys.add(((p.dy + random.nextDouble() * .6) * 100).round());
    }
  }
  at.add(xs.length);
  xs.add((points.last.dx * 100).round());
  ys.add((points.last.dy * 100).round());
  final n = xs.length;
  // One smooth node per drawn point, with handles a third of the way to
  // the neighbours, so the editor draws the same curve as the pen.
  Map<String, int> handle(Offset from, Offset to) {
    final h = from + (to - from) / 3;
    return {'x': (h.dx * 100).round(), 'y': (h.dy * 100).round()};
  }

  final nodes = [
    for (var i = 0; i < points.length; i++)
      {
        'x': (points[i].dx * 100).round(),
        'y': (points[i].dy * 100).round(),
        if (i > 0)
          'in': handle(
            points[i],
            i + 1 < points.length
                ? points[i] - (points[i + 1] - points[i - 1]) / 2
                : points[i - 1],
          ),
        if (i + 1 < points.length)
          'out': handle(
            points[i],
            i > 0
                ? points[i] + (points[i + 1] - points[i - 1]) / 2
                : points[i + 1],
          ),
        'mode': i == 0 || i == points.length - 1 ? 'independent' : 'smooth',
        'corner': i == 0 || i == points.length - 1,
        'sample': at[i],
      },
  ];
  return {
    'id': id,
    'kind': 'stroke',
    'tool': tool,
    'brush_version': 1,
    'width': width,
    'color': color,
    'opacity': opacity,
    'samples': SampleCodec.encode(
      SampleColumns(
        x: xs,
        y: ys,
        t: [for (var i = 0; i < n; i++) i * 8],
        pressure: [for (var i = 0; i < n; i++) 420 + (i % 7) * 40],
        tilt: [for (var i = 0; i < n; i++) 600],
      ),
    ),
    'nodes': nodes,
  };
}

/// An ellipse drawn by hand around a word, with the pen overlapping its
/// start.
List<Offset> loop(Offset center, double rx, double ry) => [
  for (var i = 0; i <= 40; i++)
    center +
        Offset(
          rx * cos(-pi / 2 + i * 2.15 * pi / 40) * (1 + i * .002),
          ry * sin(-pi / 2 + i * 2.15 * pi / 40),
        ),
];

/// A small hand-written word as wavy pen lines.
List<Offset> scribble(Offset start, double length, {double rise = 6}) => [
  for (var i = 0; i <= 24; i++)
    start +
        Offset(length * i / 24, sin(i * 1.7) * rise - (i % 5 == 0 ? rise : 0)),
];

NoteDocument studyPage() => NoteDocument.fromJson({
  'page': {
    'width': 1000,
    'background': {'kind': 'dots', 'spacing': 32, 'visibility': 0.6},
  },
  'items': [
    text('title', 48, 40, 620, 52, [
      {'text': 'Photosynthesis', 'size': 34, 'bold': true},
    ]),
    text('body', 48, 112, 470, 150, [
      {'text': 'Plants turn light, water and carbon dioxide into '},
      {'text': 'glucose', 'bold': true, 'color': '#7A00C2FF'},
      {
        'text':
            ' and oxygen.\nIt happens in the chloroplasts, inside the leaf cells.',
      },
    ]),
    text('steps', 48, 300, 420, 140, [
      {'text': '1. Light reactions\n', 'bold': true},
      {'text': '2. Calvin cycle\n', 'bold': true},
      {'text': '3. Sugar for the plant'},
    ]),
    // Ink: the circled word, an arrow to the drawing, a highlight.
    ink('circle', loop(const Offset(262, 164), 70, 22), color: '#7A00C2FF'),
    ink(
      'under',
      [const Offset(52, 446), const Offset(260, 442), const Offset(300, 446)],
      width: 14,
      color: '#6EFF00FF',
      tool: 'highlighter',
      opacity: .45,
    ),
    ink('arrow', [
      const Offset(330, 180),
      const Offset(420, 210),
      const Offset(560, 236),
    ], width: 3),
    ink('arrowhead', [
      const Offset(540, 222),
      const Offset(562, 236),
      const Offset(538, 248),
    ], width: 3),
    // A drawn leaf with the sun.
    ink(
      'leaf',
      [
        const Offset(600, 300),
        const Offset(640, 230),
        const Offset(720, 200),
        const Offset(800, 220),
        const Offset(760, 300),
        const Offset(680, 330),
        const Offset(600, 300),
      ],
      width: 4,
      color: '#1F7A1FFF',
    ),
    ink(
      'vein',
      [const Offset(605, 298), const Offset(700, 255), const Offset(790, 222)],
      width: 2,
      color: '#1F7A1FFF',
    ),
    ink('sun', loop(const Offset(860, 110), 34, 34), color: '#E08600FF'),
    for (var i = 0; i < 8; i++)
      ink('ray$i', [
        const Offset(860, 110) +
            Offset(cos(i * pi / 4) * 46, sin(i * pi / 4) * 46),
        const Offset(860, 110) +
            Offset(cos(i * pi / 4) * 64, sin(i * pi / 4) * 64),
      ], color: '#E08600FF'),
    ink('note1', scribble(const Offset(600, 380), 230), width: 2.5),
    ink('note2', scribble(const Offset(600, 414), 180), width: 2.5),
    {
      'id': 'box',
      'kind': 'shape',
      'shape': 'rectangle',
      'color': '#7A00C2FF',
      'line_width': 2,
      'opacity': 1,
      'x': 580,
      'y': 356,
      'width': 290,
      'height': 100,
    },
  ],
}, schema: schema);

NoteDocument phoneNote() => NoteDocument.fromJson({
  'blocks': [
    {
      'id': 'h1',
      'kind': 'heading',
      'level': 1,
      'spans': [
        {'text': 'Cell biology'},
      ],
    },
    {
      'id': 'p1',
      'kind': 'paragraph',
      'spans': [
        {'text': 'The mitochondria make energy for the cell. '},
        {'text': 'ATP', 'bold': true},
        {'text': ' carries it to where the cell needs it.'},
      ],
    },
    {
      'id': 'h2',
      'kind': 'heading',
      'level': 2,
      'spans': [
        {'text': 'Review before Friday'},
      ],
    },
    {
      'id': 'p2',
      'kind': 'paragraph',
      'spans': [
        {'text': 'Membrane transport, osmosis and the cell cycle.'},
      ],
    },
    {
      'id': 'p3',
      'kind': 'paragraph',
      'spans': [
        {'text': 'Ask about the lab report in class.'},
      ],
    },
    {
      'id': 'h3',
      'kind': 'heading',
      'level': 2,
      'spans': [
        {'text': 'Key words'},
      ],
    },
    {
      'id': 'p4',
      'kind': 'paragraph',
      'spans': [
        {'text': 'Nucleus', 'bold': true},
        {'text': ': keeps the DNA. '},
        {'text': 'Ribosome', 'bold': true},
        {'text': ': builds proteins. '},
        {'text': 'Membrane', 'bold': true},
        {'text': ': lets some molecules in and keeps others out.'},
      ],
    },
    {
      'id': 'p5',
      'kind': 'paragraph',
      'spans': [
        {
          'text':
              'Draw the cell from memory tonight, then check it against the book.',
        },
      ],
    },
  ],
}, schema: typed);

const publicNote = {
  'title': 'How memory works when you study',
  'summary': 'Spaced practice and retrieval, in short notes.',
  'slug': 'memory',
  'owner_id': 'study-group',
  'author': {'id': 'study-group', 'name': 'Study group'},
  'language': 'en',
  'available_languages': ['en', 'pt-BR'],
  'updated_at': 0,
  'topics': [],
  'body': {
    'blocks': [
      {
        'type': 'paragraph',
        'text':
            'Reading the same page again feels like learning, but it fades fast. '
            'Trying to remember the answer first keeps it much longer.',
      },
      {
        'type': 'paragraph',
        'text':
            'Space the practice: one short review the next day, then after a '
            'week, then after a month.',
      },
      {
        'type': 'paragraph',
        'text':
            'Write the idea in your own words and draw how the parts connect.',
      },
    ],
  },
};

Future<void> shoot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  await tester.pumpAndSettle();
  await expectLater(
    find.byType(MaterialApp).first,
    matchesGoldenFile(Uri.file('$out/$name.png')),
  );
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    testWidgets('desktop writer, $mode', skip: out == null, (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      final h = handlerFor(studyPage());
      addTearDown(h.dispose);
      await tester.pumpWidget(
        host(PaperScreen(handler: h), brightness: brightness),
      );
      await shoot(tester, 'desktop_$mode');
    });

    testWidgets('phone typed note, $mode', skip: out == null, (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1688);
      addTearDown(tester.view.reset);
      final h = PaperHandler(
        noteId: 'n2',
        document: phoneNote(),
        title: 'Biology',
        autosave: NoteAutosave(MemoryStore()),
      );
      addTearDown(h.dispose);
      await tester.pumpWidget(
        host(
          NoteScreen(handler: h, profile: PlatformProfile.phone),
          brightness: brightness,
        ),
      );
      await shoot(tester, 'phone_$mode');
    });

    testWidgets('browser reader, $mode', skip: out == null, (tester) async {
      SharedPreferences.setMockInitialValues({'annotations.theme': mode});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        AnnotationsApp(
          trackingEnabled: false,
          initialLocation: '/v1/menu/study-group/memory?lang=en',
          service: fixtureService(
            handler: (_) async => http.Response(
              jsonEncode(publicNote),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await shoot(tester, 'browser_$mode');
    });
  }
}
