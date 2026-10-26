import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'domain/services/preferences.dart';
import 'domain/services/annotations_service.dart';
import 'presentation/frontend/components/scope.dart';
import 'presentation/frontend/components/shell.dart';
import 'presentation/frontend/widgets/landing/landing_page.dart';
import 'presentation/frontend/widgets/catalog/catalog_page.dart';
import 'presentation/frontend/widgets/article/article_page.dart';
import 'presentation/frontend/widgets/instant/instant_page.dart';

class AnnotationsApp extends StatefulWidget {
  final AnnotationsService? service;
  final String? initialLocation;
  const AnnotationsApp({super.key, this.service, this.initialLocation});
  @override
  State<AnnotationsApp> createState() => _AnnotationsAppState();
}

class _AnnotationsAppState extends State<AnnotationsApp> {
  late final service = widget.service ?? AnnotationsService();
  final preferences = Preferences();
  late final GoRouter router;
  @override
  void initState() {
    super.initState();
    preferences.load();
    router = GoRouter(
      initialLocation: widget.initialLocation,
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/v1/home'),
        ShellRoute(
          builder: (_, _, child) => PageShell(child: child),
          routes: [
            GoRoute(path: '/v1/home', builder: (_, _) => const LandingPage()),
            GoRoute(
              path: '/v1/menu',
              builder: (_, state) => CatalogPage(
                query: state.uri.queryParameters['q'] ?? '',
                topic: state.uri.queryParameters['topic'] ?? '',
                channel: state.uri.queryParameters['channel'] ?? '',
              ),
            ),
            GoRoute(
              path: '/v1/menu/:channel/:slug',
              builder: (_, state) => ArticlePage(
                channel: state.pathParameters['channel']!,
                slug: state.pathParameters['slug']!,
                language: state.uri.queryParameters['lang'] ?? '',
              ),
            ),
            GoRoute(
              path: '/v1/instant',
              builder: (_, _) => const InstantPage(),
            ),
            GoRoute(
              path: '/v1/instant/:code',
              builder: (_, state) =>
                  InstantPage(code: state.pathParameters['code']!),
            ),
          ],
        ),
      ],
    );
  }

  @override
  void dispose() {
    router.dispose();
    preferences.dispose();
    super.dispose();
  }

  ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xFF0B0C10) : const Color(0xFFFAF9F6);
    final surface = dark ? const Color(0xFF15171D) : Colors.white;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C3AED),
      brightness: brightness,
      surface: surface,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Ubuntu Sans',
      fontFamilyFallback: const ['IBM Plex Sans Thai'],
      scaffoldBackgroundColor: background,
      dividerColor: dark ? const Color(0xFF30323B) : const Color(0xFFE5E3DF),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(
            color: dark ? const Color(0xFF30323B) : const Color(0xFFE5E3DF),
          ),
        ),
      ),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
          fontSize: 48,
          fontWeight: FontWeight.w700,
          height: 1.08,
          letterSpacing: -1.8,
          color: scheme.onSurface,
        ),
        headlineMedium: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          height: 1.15,
          color: scheme.onSurface,
        ),
        titleLarge: const TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
        bodyLarge: const TextStyle(fontSize: 17, height: 1.65),
        bodyMedium: const TextStyle(fontSize: 15, height: 1.55),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (_, _) => AppScope(
      preferences: preferences,
      service: service,
      child: MaterialApp.router(
        title: 'Annotations · Asodya',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        themeMode: preferences.theme,
        routerConfig: router,
      ),
    ),
  );
}
