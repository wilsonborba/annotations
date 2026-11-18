import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:annotations_shared/core/tracking.dart';
import 'package:flutter/material.dart';
import '../../components/icons.dart';
import 'package:go_router/go_router.dart';
import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/tokens.dart';
import '../../components/shell.dart';
import '../../components/post_card.dart';
import '../../handlers/content_handler.dart';
import '../../handlers/waitlist_handler.dart';
import '../../../../domain/models/content.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});
  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  Future<Data>? latest;
  WaitlistHandler? waitlist;
  final email = TextEditingController(), message = TextEditingController();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = AppScope.of(context).service;
    latest ??= ContentHandler(service).articles();
    waitlist ??= WaitlistHandler(service)..load();
  }

  @override
  void dispose() {
    waitlist?.dispose();
    email.dispose();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ContentWidth(
        padding: EdgeInsets.symmetric(
          horizontal: MediaQuery.sizeOf(context).width > 740 ? 32 : 20,
          vertical: 64,
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 850;
            final introduction = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('eyebrow'),
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: context.colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  context.tr('heroTitle'),
                  style: Theme.of(
                    context,
                  ).textTheme.headlineLarge?.copyWith(fontSize: wide ? 62 : 43),
                ),
                const SizedBox(height: 24),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Text(
                    context.tr('heroLead'),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                const SizedBox(height: 32),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    track(
                      'landing.browse.open',
                      AppButton.primary(
                        label: context.tr('browse'),
                        trailingIcon: AppIcons.chevronRight,
                        onPressed: () => context.go('/v1/menu'),
                      ),
                    ),
                    track(
                      'landing.instant.open',
                      AppButton(
                        label: context.tr('instant'),
                        onPressed: () => context.go('/v1/instant'),
                      ),
                    ),
                  ],
                ),
              ],
            );
            final picture = Container(
              height: 390,
              decoration: BoxDecoration(
                color: context.colors.subtle,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Stack(
                children: [
                  Positioned(
                    top: 26,
                    left: 26,
                    right: 26,
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: context.colors.surface,
                        borderRadius: BorderRadius.circular(7),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x16000000),
                            blurRadius: 24,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              AppIcon(
                                AppIcons.fileText,
                                color: context.colors.icon,
                              ),
                              SizedBox(width: 9),
                              Text(
                                context.tr('noteSources'),
                                style: TextStyle(
                                  color: context.colors.text,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 20),
                          LinearProgressIndicator(
                            value: .8,
                            minHeight: 5,
                            backgroundColor: context.colors.subtle,
                            color: context.colors.border,
                          ),
                          SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: .6,
                            minHeight: 5,
                            backgroundColor: context.colors.subtle,
                            color: context.colors.border,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 12,
                    child: Image.asset(
                      'lib/presentation/frontend/assets/images/pointing_guy.png',
                      package: 'annotations_shared',
                      height: 285,
                    ),
                  ),
                  Positioned(
                    bottom: 36,
                    left: 20,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: context.colors.inverse,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(
                            AppIcons.link,
                            color: context.colors.onInverse,
                          ),
                          SizedBox(width: 10),
                          Text(
                            context.tr('ideaConnections'),
                            style: TextStyle(
                              color: context.colors.onInverse,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(flex: 6, child: introduction),
                      const SizedBox(width: 48),
                      Expanded(flex: 5, child: picture),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      introduction,
                      const SizedBox(height: 40),
                      picture,
                    ],
                  );
          },
        ),
      ),
      ContentWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.tr('latest'),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                track(
                  'landing.catalog.all',
                  AppButton.subtle(
                    label: context.tr('all'),
                    trailingIcon: AppIcons.chevronRight,
                    onPressed: () => context.go('/v1/menu'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 25),
            FutureBuilder<Data>(
              future: latest,
              builder: (context, s) {
                if (s.hasError) {
                  return LoadError(
                    reference: ClientErrors.referenceOf(s.error),
                    retry: () => setState(
                      () => latest = ContentHandler(
                        AppScope.of(context).service,
                      ).articles(),
                    ),
                  );
                }
                if (!s.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final items = records(s.data!['items']);
                return items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Text(context.tr('empty')),
                      )
                    : PostGrid(items: items.take(6).toList());
              },
            ),
          ],
        ),
      ),
      Container(
        margin: const EdgeInsets.only(top: 32),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.symmetric(
            horizontal: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: ContentWidth(
          child: LayoutBuilder(
            builder: (context, c) {
              final intro = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIcon(
                    AppIcons.userAdd,
                    color: context.colors.icon,
                    size: 30,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    context.tr('waitTitle'),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.tr('waitLead'),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              );
              final form = AnimatedBuilder(
                animation: waitlist!,
                builder: (context, _) => waitlist!.registered
                    ? Container(
                        padding: const EdgeInsets.all(24),
                        child: Row(
                          children: [
                            const AppIcon(AppIcons.checkmarkCircle),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                context.tr(
                                  waitlist!.status == 'already_registered'
                                      ? 'already'
                                      : 'registered',
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          track(
                            'landing.waitlist.email',
                            TextField(
                              key: const Key('waitlist-email'),
                              controller: email,
                              keyboardType: TextInputType.emailAddress,
                              decoration: InputDecoration(
                                labelText: context.tr('email'),
                              ),
                            ),
                            controller: email,
                          ),
                          const SizedBox(height: 12),
                          track(
                            'landing.waitlist.message',
                            TextField(
                              key: const Key('waitlist-message'),
                              controller: message,
                              minLines: 2,
                              maxLines: 3,
                              decoration: InputDecoration(
                                labelText: context.tr('message'),
                              ),
                            ),
                            controller: message,
                          ),
                          const SizedBox(height: 14),
                          track(
                            'landing.waitlist.submit',
                            AppButton(
                              key: const Key('waitlist-submit'),
                              onPressed: waitlist!.busy
                                  ? null
                                  : () {
                                      trackSubmit(
                                        context,
                                        'landing.waitlist.submit',
                                      );
                                      waitlist!.submit(
                                        email.text,
                                        message.text,
                                      );
                                    },
                              label: context.tr('join'),
                            ),
                          ),
                          if (waitlist!.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Row(
                                children: [
                                  AppIcon(
                                    AppIcons.alertDiamond,
                                    color: context.colors.danger,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(waitlist!.error!)),
                                ],
                              ),
                            ),
                        ],
                      ),
              );
              return c.maxWidth > 850
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: intro),
                        const SizedBox(width: 80),
                        Expanded(child: form),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [intro, const SizedBox(height: 28), form],
                    );
            },
          ),
        ),
      ),
    ],
  );
}
