import 'package:flutter/material.dart';
import '../../components/controls.dart';
import '../../components/icons.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/theme.dart';
import '../../components/tokens.dart';

/// The component gallery for design review. The router adds it only in
/// debug builds; release builds do not contain the route.
class GalleryPage extends StatelessWidget {
  const GalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    return ContentWidth(
      width: 1280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Component gallery', style: text.headlineLarge),
          const SizedBox(height: 6),
          Text(
            '${c.isDark ? 'Dark' : 'Light'} mode · '
            '${AppScope.of(context).preferences.locale}',
            style: text.bodySmall,
          ),
          const _Section(title: 'Colors', child: _Colors()),
          const _Section(title: 'Typography', child: _Typography()),
          const _Section(title: 'Buttons', child: _Buttons()),
          const _Section(title: 'Icon buttons', child: _IconButtons()),
          const _Section(title: 'Selection and fields', child: _Selection()),
          const _Section(
            title: 'Menus, dialogs and toasts',
            child: _Overlays(),
          ),
          const _Section(title: 'Icons', child: _Icons()),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 36),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 16),
        child,
      ],
    ),
  );
}

class _Caption extends StatelessWidget {
  final String text;
  const _Caption(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class _Swatch extends StatelessWidget {
  final String name;
  final Color color;
  final Color? on;
  const _Swatch(this.name, this.color, {this.on});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(appRadius),
              border: Border.all(color: c.border),
            ),
            child: on == null
                ? null
                : Text(
                    'Aa ก',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium!.copyWith(color: on),
                  ),
          ),
          const SizedBox(height: 6),
          Text(name, style: Theme.of(context).textTheme.labelMedium),
          Text(_hex(color), style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Colors extends StatelessWidget {
  const _Colors();
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _Swatch('page', c.page, on: c.text),
            _Swatch('surface', c.surface, on: c.text),
            _Swatch('subtle', c.subtle, on: c.textSecondary),
            _Swatch('accent', c.accent, on: c.onAccent),
            _Swatch('selection', c.selection, on: c.onSelection),
            _Swatch('selectionOutline', c.selectionOutline),
            _Swatch('danger', c.danger, on: c.onDanger),
            _Swatch('warning', c.warning, on: c.onWarning),
            _Swatch('inverse', c.inverse, on: c.onInverse),
            _Swatch('control', c.control),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 28,
          runSpacing: 8,
          children: [
            Text('text', style: text.bodyMedium!.copyWith(color: c.text)),
            Text(
              'textSecondary',
              style: text.bodyMedium!.copyWith(color: c.textSecondary),
            ),
            Text(
              'link',
              style: text.bodyMedium!.copyWith(
                color: c.link,
                decoration: TextDecoration.underline,
                decorationColor: c.link,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('Color pairs (small amounts)', style: text.labelMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            for (final (first, second) in AppPalette.pairs)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final color in [first, second])
                    Container(
                      width: 44,
                      height: 28,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Text('${_hex(first)} ${_hex(second)}', style: text.bodySmall),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _Typography extends StatelessWidget {
  const _Typography();
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    Widget row(String name, TextStyle? style, String sample) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              '$name ${style!.fontSize!.round()}',
              style: text.bodySmall,
            ),
          ),
          Expanded(child: Text(sample, style: style)),
        ],
      ),
    );
    return Column(
      children: [
        row('headlineLarge', text.headlineLarge, context.tr('roomTitle')),
        row('headlineMedium', text.headlineMedium, context.tr('latest')),
        row('headlineSmall', text.headlineSmall, context.tr('waitTitle')),
        row('titleLarge', text.titleLarge, context.tr('research')),
        row('bodyLarge', text.bodyLarge, context.tr('heroLead')),
        row('bodyMedium', text.bodyMedium, context.tr('roomNote')),
        row('labelLarge', text.labelLarge, context.tr('openRoom')),
        row('bodySmall', text.bodySmall, context.tr('limit')),
      ],
    );
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons();
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 16,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          AppButton.primary(
            label: context.tr('download'),
            icon: AppIcons.download,
            onPressed: () {},
          ),
          AppButton(
            label: context.tr('browse'),
            trailingIcon: AppIcons.chevronRight,
            onPressed: () {},
          ),
          AppButton.subtle(label: context.tr('all'), onPressed: () {}),
          AppButton.danger(
            label: context.tr('remove'),
            icon: AppIcons.delete,
            onPressed: () {},
          ),
          AppButton.primary(label: context.tr('save'), onPressed: null),
          AppButton(label: context.tr('cancel'), onPressed: null),
        ],
      ),
      const _Caption(
        'Primary (one per page), secondary, subtle, danger with a text '
        'label, disabled primary and secondary.',
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          FocusRing(
            visible: true,
            child: AppButton.primary(
              label: context.tr('openRoom'),
              onPressed: () {},
            ),
          ),
          FocusRing(
            visible: true,
            child: AppButton(label: context.tr('retry'), onPressed: () {}),
          ),
        ],
      ),
      const _Caption('Keyboard focus ring.'),
    ],
  );
}

class _IconButtons extends StatelessWidget {
  const _IconButtons();
  @override
  Widget build(BuildContext context) {
    final dark = context.colors.isDark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppIconButton(
              icon: AppIcons.edit,
              label: context.tr('edit'),
              onPressed: () {},
            ),
            AppIconButton(
              icon: AppIcons.link,
              label: context.tr('copy'),
              onPressed: () {},
            ),
            AppIconButton(
              icon: AppIcons.download,
              label: context.tr('download'),
              onPressed: () {},
            ),
            AppIconButton(
              icon: AppIcons.delete,
              label: context.tr('remove'),
              onPressed: () {},
            ),
            AppIconButton(
              icon: AppIcons.upload,
              label: context.tr('upload'),
              onPressed: null,
            ),
            FocusRing(
              visible: true,
              child: AppIconButton(
                icon: AppIcons.edit,
                label: context.tr('edit'),
                onPressed: () {},
              ),
            ),
            const SizedBox(width: 24),
            AppIconButton.navigation(
              icon: AppIcons.contrast,
              label: context.tr('theme'),
              onPressed: () {},
            ),
            AppMenuButton(
              icon: AppIcons.menu,
              label: context.tr('menu'),
              round: true,
              entries: [
                AppMenuEntry(label: context.tr('notes'), onSelected: () {}),
                AppMenuEntry(label: context.tr('instant'), onSelected: () {}),
              ],
            ),
          ],
        ),
        _Caption(
          'Subtle icon buttons; the label is the tooltip. Disabled: no '
          'tooltip. Focus ring. Round buttons only in the top navigation '
          '(${dark ? 'dark' : 'light'} mode shown).',
        ),
      ],
    );
  }
}

class _Selection extends StatelessWidget {
  const _Selection();
  @override
  Widget build(BuildContext context) {
    final prefs = AppScope.of(context).preferences;
    return Wrap(
      spacing: 32,
      runSpacing: 16,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LanguageSwitch(selected: prefs.locale, onChanged: (_) {}),
            const _Caption('Current choice: green fill, dark text.'),
          ],
        ),
        SizedBox(
          width: 360,
          child: TextField(
            decoration: InputDecoration(
              hintText: context.tr('search'),
              prefixIcon: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: AppIcon(AppIcons.search),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 44),
            ),
          ),
        ),
        SizedBox(
          width: 360,
          child: TextFormField(
            key: ValueKey('email-${prefs.locale}'),
            initialValue: context.tr('email'),
            decoration: InputDecoration(
              labelText: context.tr('email'),
              focusedBorder: Theme.of(
                context,
              ).inputDecorationTheme.focusedBorder,
              enabledBorder: Theme.of(
                context,
              ).inputDecorationTheme.focusedBorder,
            ),
          ),
        ),
      ],
    );
  }
}

class _Overlays extends StatelessWidget {
  const _Overlays();
  @override
  Widget build(BuildContext context) {
    final menu = [
      AppMenuEntry(
        label: context.tr('notes'),
        icon: AppIcons.fileText,
        onSelected: () {},
      ),
      AppMenuEntry(
        label: context.tr('instant'),
        icon: AppIcons.peopleGroup,
        onSelected: () {},
      ),
      AppMenuEntry(
        label: context.tr('download'),
        icon: AppIcons.download,
        onSelected: () {},
      ),
    ];
    final dialog = AppDialog(
      title: context.tr('edit'),
      content: TextFormField(
        key: ValueKey('dialog-${AppScope.of(context).preferences.locale}'),
        initialValue: context.tr('textLink'),
        maxLines: 2,
      ),
      actions: [
        AppButton(label: context.tr('cancel'), onPressed: () {}),
        AppButton.primary(label: context.tr('save'), onPressed: () {}),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 40,
          runSpacing: 24,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppMenuPanel(entries: menu, highlighted: 1),
                const _Caption('Menu; the row under the pointer.'),
              ],
            ),
            SizedBox(
              width: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MediaQuery.removeViewInsets(
                    context: context,
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        dialogTheme: Theme.of(
                          context,
                        ).dialogTheme.copyWith(insetPadding: EdgeInsets.zero),
                      ),
                      child: dialog,
                    ),
                  ),
                  const _Caption('Dialog.'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            AppToast(message: context.tr('copied')),
            AppToast(message: context.tr('limit'), tone: AppToastTone.warning),
            AppToast(message: context.tr('error'), tone: AppToastTone.danger),
          ],
        ),
        const _Caption('Toasts: neutral, warning (orange), danger (red).'),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          children: [
            AppButton(
              label: '${context.tr('edit')} …',
              onPressed: () => showAppDialog<void>(
                context,
                (dialogContext) => AppDialog(
                  title: context.tr('edit'),
                  content: Text(context.tr('roomNote')),
                  actions: [
                    AppButton(
                      label: context.tr('cancel'),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                    AppButton.primary(
                      label: context.tr('save'),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
              ),
            ),
            AppButton(
              label: context.tr('copy'),
              onPressed: () => showAppToast(context, context.tr('copied')),
            ),
          ],
        ),
      ],
    );
  }
}

class _Icons extends StatelessWidget {
  const _Icons();
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      for (final icon in AppIcons.all)
        SizedBox(
          width: 112,
          child: Column(
            children: [
              AppIcon(icon, size: 24),
              const SizedBox(height: 4),
              Text(
                icon.name,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
    ],
  );
}
