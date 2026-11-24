import 'core/tracking_manifest.dart';
import 'core/tracking.dart';
import 'dal/remote/api_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:go_router/go_router.dart';
import 'domain/services/preferences.dart';
import 'domain/services/annotations_service.dart';
import 'presentation/frontend/components/scope.dart';
import 'presentation/frontend/components/shell.dart';
import 'presentation/frontend/components/theme.dart';
import 'presentation/frontend/widgets/gallery/gallery_page.dart';
import 'presentation/frontend/widgets/landing/download_page.dart';
import 'presentation/frontend/widgets/landing/engineering_page.dart';
import 'presentation/frontend/widgets/landing/features_page.dart';
import 'presentation/frontend/widgets/landing/how_it_works_page.dart';
import 'presentation/frontend/widgets/landing/landing_page.dart';
import 'domain/services/discovery_reader_service.dart';
import 'presentation/frontend/widgets/discovery/discovery_pages.dart';
import 'presentation/frontend/widgets/article/article_page.dart';
import 'presentation/frontend/widgets/instant/instant_page.dart';

class AnnotationsApp extends StatefulWidget {
  final AnnotationsService? service;
  final String? initialLocation;
  final ScreenTrail? tracker;
  final bool trackingEnabled;
  const AnnotationsApp({
    super.key,
    this.service,
    this.initialLocation,
    this.tracker,
    this.trackingEnabled = true,
  });
  @override
  State<AnnotationsApp> createState() => _AnnotationsAppState();
}

class _AnnotationsAppState extends State<AnnotationsApp> {
  late final service = widget.service ?? AnnotationsService();
  final preferences = Preferences();
  late final GoRouter router;
  HttpTrailTransport? _transport;
  late final tracker =
      widget.tracker ??
      createTracker(
        transport: _transport = createTrailTransport(),
        autoFlush: widget.trackingEnabled,
      );
  late final errors = ClientErrors(tracker);
  void trackRoute() =>
      tracker.view(router.routeInformationProvider.value.uri.path);

  @override
  void initState() {
    super.initState();
    registerDesignLicenses();
    preferences.load();
    if (widget.trackingEnabled) errors.install();
    service.api.onError = (error, stack, operation) => errors.report(
      error,
      stack,
      operation: operation,
      type: 'ApiError',
      httpStatus: error is ApiError ? error.status : null,
    );
    router = GoRouter(
      initialLocation: widget.initialLocation,
      observers: [ScreenTrailObserver(tracker)],
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/v1/home'),
        ShellRoute(
          builder: (_, state, child) =>
              PageShell(location: state.uri.path, child: child),
          routes: [
            GoRoute(
              path: '/v1/home',
              builder: (_, _) => const ShellPage(child: LandingPage()),
            ),
            GoRoute(
              path: '/v1/home/features',
              builder: (_, _) => const ShellPage(child: FeaturesPage()),
            ),
            GoRoute(
              path: '/v1/home/how-it-works',
              builder: (_, _) => const ShellPage(child: HowItWorksPage()),
            ),
            GoRoute(
              path: '/v1/home/engineering',
              builder: (_, _) => const ShellPage(child: EngineeringPage()),
            ),
            GoRoute(
              path: '/v1/home/download',
              builder: (_, _) => const ShellPage(child: DownloadPage()),
            ),
            GoRoute(
              path: '/v1/menu',
              builder: (_, state) {
                final q = state.uri.queryParameters;
                return ShellPage(
                  child: BrowsePage(
                    query: DiscoveryQuery(
                      q: q['q'] ?? '',
                      tag: q['tag'],
                      authorId: q['author'],
                      language: q['language'],
                      projectId: q['project'],
                    ),
                  ),
                );
              },
            ),
            GoRoute(
              path: '/v1/authors/:id',
              builder: (_, state) => ShellPage(
                child: AuthorPage(authorId: state.pathParameters['id']!),
              ),
            ),
            GoRoute(
              path: '/v1/projects/:id',
              builder: (_, state) => ShellPage(
                child: ProjectPage(projectId: state.pathParameters['id']!),
              ),
            ),
            GoRoute(
              path: '/v1/notes/:id',
              builder: (_, state) => ShellPage(
                child: ReaderPage(
                  key: ValueKey(state.uri.toString()),
                  noteId: state.pathParameters['id']!,
                  view: switch (state.uri.queryParameters['view']) {
                    'typed' => NoteViewMode.typed,
                    'original' => NoteViewMode.original,
                    _ => null,
                  },
                ),
              ),
            ),
            GoRoute(
              path: '/v1/menu/:channel/:slug',
              builder: (_, state) => ShellPage(
                child: ArticlePage(
                  channel: state.pathParameters['channel']!,
                  slug: state.pathParameters['slug']!,
                  language: state.uri.queryParameters['lang'] ?? '',
                ),
              ),
            ),
            GoRoute(
              path: '/v1/instant',
              builder: (_, _) => const ShellPage(child: InstantPage()),
            ),
            GoRoute(
              path: '/v1/instant/:code',
              builder: (_, state) => ShellPage(
                child: InstantPage(code: state.pathParameters['code']!),
              ),
            ),
            // Design review only: release builds have no gallery route.
            if (kDebugMode)
              GoRoute(
                path: '/v1/gallery',
                builder: (_, _) => const ShellPage(child: GalleryPage()),
              ),
          ],
        ),
      ],
    );
    router.routeInformationProvider.addListener(trackRoute);
    trackRoute();
  }

  @override
  void dispose() {
    router.routeInformationProvider.removeListener(trackRoute);
    router.dispose();
    service.api.onError = null;
    errors.dispose();
    tracker.dispose();
    _transport?.close();
    preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (_, _) => AppScope(
      preferences: preferences,
      service: service,
      child: MaterialApp.router(
        title: 'Annotations',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: preferences.theme,
        routerConfig: router,
        // The text editor of note blocks needs its localizations (#23).
        localizationsDelegates:
            FlutterQuillLocalizations.localizationsDelegates,
        builder: (context, child) => ScreenTrailRoot(
          tracker: tracker,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ),
  );
}
