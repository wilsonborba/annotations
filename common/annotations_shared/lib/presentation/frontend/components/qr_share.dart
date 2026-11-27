import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../../../core/landing_settings.dart';
import '../../../core/settings.dart';
import 'controls.dart';
import 'icons.dart';
import 'scope.dart';
import 'theme.dart';
import 'tokens.dart';

const _qrIcon = AppIconData('QRCode', [
  'M1 1h6v1H2v4h-1z M3 3h2v2H3z M13 1h6v6h-1V2h-5z M15 3h2v2h-2z M1 13h6v6H1v-1h5v-4H2v4H1z M3 15h2v2H3z M9 1h2v2H9z M9 5h2v2H9z M9 9h2v2H9z M13 9h2v2h-2z M17 9h2v2h-2z M13 13h2v2h-2z M17 13h2v2h-2z M9 13h2v2H9z M11 17h2v2h-2z M15 17h2v2h-2z M19 17h1v2h-1z',
]);

/// Builds a routable public app URL. Development keeps the current browser
/// origin; production uses the configured public site address.
Uri publicAppUri({
  required List<String> pathSegments,
  Map<String, String>? queryParameters,
}) {
  final currentOrigin = Uri.base;
  final useBrowserOrigin =
      Settings.current.development &&
      (currentOrigin.scheme == 'http' || currentOrigin.scheme == 'https') &&
      currentOrigin.host.isNotEmpty;
  final base = useBrowserOrigin
      ? currentOrigin
      : Uri.parse(LandingSettings.siteAddress);
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: pathSegments,
    queryParameters: queryParameters,
  );
}

/// A local QR preview for an already-authorized browser URL.
///
/// The URI is only encoded into pixels in this process. This widget makes no
/// network requests and does not report the URI to application telemetry.
class QrShareControl extends StatefulWidget {
  const QrShareControl({
    super.key,
    required this.url,
    required this.caption,
    this.semanticHint,
    required this.labelKey,
  });

  final Uri url;
  final String caption;
  final String? semanticHint;
  final String labelKey;

  @override
  State<QrShareControl> createState() => _QrShareControlState();
}

class _QrShareControlState extends State<QrShareControl> {
  final FocusNode _triggerFocus = FocusNode();
  bool _triggerFocused = false;

  @override
  void dispose() {
    _triggerFocus.dispose();
    super.dispose();
  }

  Future<void> _enlarge() async {
    await showAppDialog<void>(
      context,
      (dialogContext) => AppDialog(
        title: dialogContext.tr(widget.labelKey),
        content: _QrDialogContent(url: widget.url, caption: widget.caption),
        actions: [
          AppButton(
            label: dialogContext.tr('close'),
            onPressed: () => Navigator.pop(dialogContext),
          ),
        ],
      ),
    );
    if (mounted) _triggerFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.tr(widget.labelKey),
    hint: widget.semanticHint ?? widget.caption,
    child: Focus(
      onFocusChange: (value) => setState(() => _triggerFocused = value),
      child: FocusRing(
        visible:
            _triggerFocused &&
            FocusManager.instance.highlightMode ==
                FocusHighlightMode.traditional,
        child: TextButton(
          focusNode: _triggerFocus,
          style: appButtonStyle(
            context.colors,
            Theme.of(context).textTheme,
            AppButtonKind.secondary,
          ),
          onPressed: _enlarge,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(_qrIcon, size: 18),
              const SizedBox(width: 8),
              Flexible(child: Text(context.tr(widget.labelKey))),
            ],
          ),
        ),
      ),
    ),
  );
}

class _QrDialogContent extends StatelessWidget {
  const _QrDialogContent({required this.url, required this.caption});

  final Uri url;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final widthLimit = math.max(1.0, viewport.width - 104);
    final heightLimit = math.max(160.0, viewport.height - 220);
    final qrSize = math.min(320.0, math.min(widthLimit, heightLimit));
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: qrSize,
            child: QrCodeView(data: url.toString(), size: qrSize),
          ),
          const SizedBox(height: 12),
          SelectableText(
            caption,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            url.toString(),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Paints a QR matrix on a solid white surface with a four-module quiet zone.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: Colors.white, width: 4),
    ),
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _QrCodePainter(
          QrImage(
            QrCode.fromData(
              data: data,
              errorCorrectLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
        isComplex: true,
      ),
    ),
  );
}

class _QrCodePainter extends CustomPainter {
  _QrCodePainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final moduleCount = image.moduleCount;
    final moduleSize = size.width / (moduleCount + 8);
    final paint = Paint()
      ..color = const Color(0xff0b0c10)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;
    for (var row = 0; row < moduleCount; row++) {
      for (var column = 0; column < moduleCount; column++) {
        if (!image.isDark(row, column)) continue;
        final left = (column + 4) * moduleSize;
        final top = (row + 4) * moduleSize;
        canvas.drawRect(
          Rect.fromLTRB(left, top, left + moduleSize, top + moduleSize),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrCodePainter oldDelegate) => image != oldDelegate.image;
}
