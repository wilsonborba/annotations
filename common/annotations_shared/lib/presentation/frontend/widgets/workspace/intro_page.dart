import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/tracking_manifest.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/sketch_art.dart';
import '../../components/tokens.dart';

/// Shown once: the installed apps open here the first time.
const introSeenKey = 'annotations.intro_seen';

/// The installed first start (installed-app rule 9882f515): three short
/// screens at most, then the writer workspace. Skip leaves at any time.
class IntroPage extends StatefulWidget {
  const IntroPage({super.key});

  static const screens = [
    (SketchScene.writing, 'intro1Title', 'intro1Text'),
    (SketchScene.tasks, 'intro2Title', 'intro2Text'),
    (SketchScene.sharing, 'intro3Title', 'intro3Text'),
  ];

  @override
  State<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends State<IntroPage> {
  int _step = 0;

  Future<void> _done() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(introSeenKey, true);
    } catch (_) {}
    if (mounted) context.go('/v1/write');
  }

  @override
  Widget build(BuildContext context) {
    final (scene, title, text) = IntroPage.screens[_step];
    final last = _step == IntroPage.screens.length - 1;
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    key: Key('intro-art-$_step'),
                    height: 200,
                    child: SketchArt(scene),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    context.tr(title),
                    key: Key('intro-title-$_step'),
                    style: theme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.tr(text),
                    style: theme.bodyLarge!.copyWith(
                      color: context.colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      for (var i = 0; i < IntroPage.screens.length; i++)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == _step
                                ? context.colors.accent
                                : context.colors.border,
                          ),
                        ),
                      const Spacer(),
                      if (!last)
                        track(
                          'intro.skip',
                          AppButton.subtle(
                            key: const Key('intro-skip'),
                            label: context.tr('introSkip'),
                            onPressed: _done,
                          ),
                        ),
                      const SizedBox(width: 8),
                      track(
                        'intro.next',
                        AppButton.primary(
                          key: const Key('intro-next'),
                          label: context.tr(last ? 'introStart' : 'introNext'),
                          onPressed: last
                              ? _done
                              : () => setState(() => _step++),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
