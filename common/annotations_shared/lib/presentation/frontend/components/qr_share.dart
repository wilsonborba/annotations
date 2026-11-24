import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../../../core/landing_settings.dart';
import '../../../core/settings.dart';
import 'controls.dart';
import 'scope.dart';
import 'tokens.dart';

/// Builds a routable public app URL. Development keeps the current browser
/// origin; production uses the configured public site address.
Uri publicAppUri({
  required List<String> pathSegments,
  Map<String, String>? queryParameters,
}) {
  final base = Settings.current.development
      ? Uri.base
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
  const QrShareControl({super.key, required this.url, required this.caption});

  final Uri url;
  final String caption;

  @override
  State<QrShareControl> createState() => _QrShareControlState();
}

class _QrShareControlState extends State<QrShareControl> {
  final FocusNode _triggerFocus = FocusNode();

  @override
  void dispose() {
    _triggerFocus.dispose();
    super.dispose();
  }

  Future<void> _enlarge() async {
    await showAppDialog<void>(
      context,
      (dialogContext) => AppDialog(
        title: dialogContext.tr('shareQr'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrCodeView(
              data: widget.url.toString(),
              size: MediaQuery.sizeOf(dialogContext).width < 600 ? 240 : 300,
            ),
            const SizedBox(height: 16),
            SelectableText(
              widget.caption,
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.bodyMedium,
            ),
          ],
        ),
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
    label: context.tr('shareQr'),
    hint: widget.caption,
    child: TextButton(
      focusNode: _triggerFocus,
      onPressed: _enlarge,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.all(8),
        foregroundColor: context.colors.text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrCodeView(data: widget.url.toString(), size: 96),
          const SizedBox(height: 4),
          Text(
            context.tr('shareQr'),
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    ),
  );
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
