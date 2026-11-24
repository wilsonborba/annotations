import 'package:flutter/material.dart';
import 'package:reports_view/reports_view.dart';

import '../../../domain/models/reports_embed_data.dart';
import 'scope.dart';

/// Displays an authorized Reports page in the bounds of a note card.
/// Access states never show report metadata or values.
class ReportsEmbedCard extends StatelessWidget {
  const ReportsEmbedCard({
    super.key,
    required this.data,
    required this.loading,
    required this.snapshot,
    this.onRetry,
    this.onSignIn,
    this.onOpen,
  });

  final ReportsEmbedData? data;
  final bool loading;
  final bool snapshot;
  final VoidCallback? onRetry;
  final VoidCallback? onSignIn;
  final VoidCallback? onOpen;

  static const _palette = ReportPalette(
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFF4F4F5),
    surfaceAlt: Color(0xFFE9E9EC),
    border: Color(0xFFE4E4E7),
    textPrimary: Color(0xFF1E1E1E),
    textMuted: Color(0xFF52525B),
    accent: Color(0xFF7C3AED),
    onAccent: Color(0xFFFFFFFF),
    positive: Color(0xFF16A34A),
    warning: Color(0xFFCA8A04),
    negative: Color(0xFFDC2626),
    info: Color(0xFF0891B2),
    caution: Color(0xFFEA580C),
    series: [
      Color(0xFFEB6834),
      Color(0xFF0F9FA8),
      Color(0xFF008300),
      Color(0xFFE87BA4),
      Color(0xFFEDA100),
      Color(0xFFE34948),
      Color(0xFF6250D6),
      Color(0xFF1BAF7A),
    ],
    other: Color(0xFFA8A8A8),
    highlight: Color(0xFF16A34A),
  );

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final reportTheme = _palette.toTheme(brightness);
    final d = data;
    final readable = d?.canRender == true;
    final header = _header(context, d, readable);
    final body = readable ? _chart(d!) : _status(context, d);
    return Theme(
      data: reportTheme,
      child: Material(
        color: _palette.canvas,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border.fromBorderSide(
                BorderSide(color: Color(0xFFE4E4E7)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ReportsEmbedData? d, bool readable) {
    final label = context.tr(snapshot ? 'reportsSnapshot' : 'reportsLive');
    final stamp = snapshot && d?.capturedAt != null
        ? context.tr('reportsCaptured', {'date': _date(d!.capturedAt!)})
        : null;
    final offline = d?.state == ReportsEmbedState.offline;
    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      color: _palette.surface,
      child: Row(
        children: [
          Expanded(
            child: Text(
              [
                if (readable) label else _stateTitle(context, d),
                if (readable && stamp != null) stamp,
                if (offline) context.tr('reportsOffline'),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: _palette.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (offline && d?.cachedAt != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                context.tr('reportsLastSaved', {'date': _date(d!.cachedAt!)}),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: _palette.textMuted),
              ),
            ),
          if (readable && onOpen != null)
            IconButton(
              key: const Key('reports-open-in-reports'),
              tooltip: context.tr('reportsOpen'),
              visualDensity: VisualDensity.compact,
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new, size: 16),
            ),
        ],
      ),
    );
  }

  Widget _chart(ReportsEmbedData d) {
    final page = d.page!;
    final frameState = d.state == ReportsEmbedState.offline
        ? ChartFrameState.offline
        : page.rows.isEmpty
        ? ChartFrameState.empty
        : ChartFrameState.ready;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: ChartFrame(
        page: page,
        mode: ChartFrameMode.embed,
        state: frameState,
        title: d.reportView?.title ?? page.descriptor.title,
        subtitle: d.reportView?.description,
        snapshotDate: d.capturedAt?.toIso8601String(),
        enableTableToggle: false,
        showAxisTitles: false,
        child: LayoutBuilder(
          builder: (context, box) => VisualChooser.build(
            page,
            Slot(page.descriptor.datasetId),
            full: true,
            height: box.maxHeight,
            frame: box.maxWidth,
          ),
        ),
      ),
    );
  }

  Widget _status(BuildContext context, ReportsEmbedData? d) {
    final state = d?.state;
    final message = switch (state) {
      ReportsEmbedState.restricted => context.tr('reportsRestricted'),
      ReportsEmbedState.signInRequired => context.tr('reportsSignInRequired'),
      ReportsEmbedState.unavailable => context.tr('reportsUnavailable'),
      ReportsEmbedState.offline => context.tr('reportsOfflineUnavailable'),
      ReportsEmbedState.readable || null => context.tr('reportsLoading'),
    };
    final action = state == ReportsEmbedState.signInRequired
        ? onSignIn
        : (state == ReportsEmbedState.restricted ? null : onRetry);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading || state == null)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (state == ReportsEmbedState.restricted)
              const Icon(Icons.lock_outline, size: 20)
            else
              const Icon(Icons.insert_chart_outlined, size: 20),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            if (action != null)
              TextButton.icon(
                key: const Key('reports-retry'),
                onPressed: action,
                icon: Icon(
                  state == ReportsEmbedState.signInRequired
                      ? Icons.login
                      : Icons.refresh,
                  size: 15,
                ),
                label: Text(
                  state == ReportsEmbedState.signInRequired
                      ? context.tr('reportsSignIn')
                      : context.tr('reportsRetry'),
                  maxLines: 1,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _stateTitle(BuildContext context, ReportsEmbedData? d) => 'Reports';

  String _date(DateTime at) => at.toLocal().toIso8601String().split('T').first;
}
