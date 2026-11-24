import 'core/tracking_manifest.dart';
import 'core/tracking.dart';
import 'dal/remote/aes_cbc.dart';
import 'dal/remote/api_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'core/settings.dart';
import 'dal/remote/browser/session_browser.dart' as browser;
import 'domain/services/account_service.dart';
import 'domain/services/installed_account.dart';
import 'domain/services/local_workspace.dart';
import 'domain/services/my_notes_service.dart';
import 'domain/services/preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'presentation/frontend/widgets/account/my_notes_page.dart';
import 'presentation/frontend/widgets/account/sync_page.dart';
import 'presentation/frontend/widgets/workspace/installed_sign_in_page.dart';
import 'presentation/frontend/widgets/workspace/intro_page.dart';
import 'presentation/frontend/widgets/workspace/note_editor_page.dart';
import 'presentation/frontend/widgets/workspace/workspace_page.dart';
import 'presentation/frontend/widgets/workspace/writer_shell.dart';
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
import 'presentation/frontend/widgets/catalog/catalog_page.dart';
import 'presentation/frontend/widgets/article/article_page.dart';
import 'presentation/frontend/widgets/instant/instant_page.dart';

class AnnotationsApp extends StatefulWidget {
  final AnnotationsService? service;
  final String? initialLocation;
  final ScreenTrail? tracker;
  final bool trackingEnabled;

  /// The browser account; by default the real one in a browser and none in
  /// the installed apps (annotations#38).
  final AccountService? account;
  final MyNotesService? myNotes;

  /// The notes on this device. Installed apps give it and open the writer
  /// workspace (first start: the intro); the browser has none.
  final LocalWorkspace? workspace;

  /// True when the intro was seen (installed apps).
  final bool introSeen;

  /// The installed-app account (native handoff); null in the browser.
  final InstalledAccount? installed;
  const AnnotationsApp({
    super.key,
    this.installed,
    this.workspace,
    this.introSeen = true,
    this.account,
    this.myNotes,
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
  late final http.Client? _browserClient = kIsWeb
      ? browser.createCredentialsClient()
      : null;
  late final AccountService? account =
      widget.account ??
      (kIsWeb && _browserClient != null
          ? AccountService(
              client: _browserClient,
              appContextKey: Settings.current.appContextKey,
              authBase: Settings.current.authBase,
              platform: SessionPlatform(
                readCookie: browser.readCookie,
                deleteCookie: browser.deleteCookie,
                origin: browser.currentOrigin,
                open: (uri) => launchUrl(uri, webOnlyWindowName: '_self'),
                aes: aesCbcEncrypt,
              ),
            )
          : null);
  late final MyNotesService? myNotes =
      widget.myNotes ??
      (_browserClient != null ? MyNotesService(client: _browserClient) : null);
  void trackRoute() =>
      tracker.view(router.routeInformationProvider.value.uri.path);

  @override
  void initState() {
    super.initState();
    registerDesignLicenses();
    preferences.load();
    // The live session check on load (never a stored flag).
    account?.check();
    widget.installed?.check();
    if (widget.trackingEnabled) errors.install();
    service.api.onError = (error, stack, operation) => errors.report(
      error,
      stack,
      operation: operation,
      type: 'ApiError',
      httpStatus: error is ApiError ? error.status : null,
    );
    router = GoRouter(
      initialLocation:
          widget.initialLocation ??
          (widget.workspace == null
              ? null
              : widget.introSeen
              ? '/v1/write'
              : '/v1/welcome'),
      observers: [ScreenTrailObserver(tracker)],
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/v1/home'),
        if (widget.workspace != null) ...[
          GoRoute(path: '/v1/welcome', builder: (_, _) => const IntroPage()),
          GoRoute(
            path: '/v1/sign-in',
            builder: (_, _) => const WriterShell(child: InstalledSignInPage()),
          ),
          GoRoute(
            path: '/v1/write',
            builder: (_, _) => const WriterShell(child: WorkspacePage()),
          ),
          GoRoute(
            path: '/v1/write/:id',
            builder: (_, state) =>
                NoteEditorPage(noteId: state.pathParameters['id']!),
          ),
        ],
        GoRoute(
          path: AccountService.syncPath,
          builder: (_, state) => Scaffold(
            body: SyncPage(
              token: state.uri.queryParameters[AccountService.tokenParam] ?? '',
              onAddress: browser.replaceAddress,
            ),
          ),
        ),
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
              builder: (_, state) => ShellPage(
                child: CatalogPage(
                  query: state.uri.queryParameters['q'] ?? '',
                  topic: state.uri.queryParameters['topic'] ?? '',
                  channel: state.uri.queryParameters['channel'] ?? '',
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
              path: AccountService.myNotesPath,
              builder: (_, _) => const ShellPage(child: MyNotesPage()),
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
    _browserClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (_, _) => AppScope(
      preferences: preferences,
      service: service,
      account: account,
      myNotes: myNotes,
      workspace: widget.workspace,
      installed: widget.installed,
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
