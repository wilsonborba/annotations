import 'package:flutter/widgets.dart';

export 'spectrum_icons.dart';

/// One Spectrum 2 workflow icon: filled SVG paths on a 20 x 20 grid.
@immutable
class AppIconData {
  final String name;
  final List<String> paths;
  const AppIconData(this.name, this.paths);

  static final _cache = <AppIconData, List<Path>>{};

  /// The parsed paths, one per SVG path element, in grid units.
  List<Path> get parsed =>
      _cache[this] ??= [for (final data in paths) parseSvgPath(data)];
}

/// Draws an [AppIconData] with the color and size of the [IconTheme].
class AppIcon extends StatelessWidget {
  final AppIconData icon;
  final double? size;
  final Color? color;

  /// Read by screen readers. Leave it empty when a label is next to the icon.
  final String? semanticLabel;
  const AppIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final side = size ?? theme.size ?? 20;
    final paint = color ?? theme.color ?? const Color(0xFF000000);
    final drawing = SizedBox.square(
      dimension: side,
      child: CustomPaint(painter: _IconPainter(icon, paint)),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: drawing)
        : Semantics(label: semanticLabel, image: true, child: drawing);
  }
}

class _IconPainter extends CustomPainter {
  final AppIconData icon;
  final Color color;
  _IconPainter(this.icon, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    canvas.save();
    canvas.scale(size.width / 20, size.height / 20);
    // Each SVG path element fills on its own, as in the SVG file.
    for (final path in icon.parsed) {
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.icon != icon || old.color != color;
}

final _tokens = RegExp(
  r'([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)|([A-Za-z])',
);

/// Parses the SVG path commands that the Spectrum 2 icons use: M, L, H, V,
/// C, S and Z, absolute and relative. Fill rule: non-zero, as in SVG.
Path parseSvgPath(String data) {
  final path = Path();
  final tokens = _tokens.allMatches(data).map((m) => m[0]!).toList();
  var i = 0;
  var command = '';
  double x = 0, y = 0, startX = 0, startY = 0;
  double? controlX, controlY;
  bool isCommand(int at) =>
      at < tokens.length && RegExp(r'^[A-Za-z]$').hasMatch(tokens[at]);
  double number() => double.parse(tokens[i++]);

  while (i < tokens.length) {
    if (isCommand(i)) {
      command = tokens[i++];
    } else if (command.isEmpty) {
      throw FormatException('Path data must start with a command', data);
    }
    final relative = command == command.toLowerCase();
    final dx = relative ? x : 0.0, dy = relative ? y : 0.0;
    switch (command.toUpperCase()) {
      case 'M':
        x = dx + number();
        y = dy + number();
        path.moveTo(x, y);
        startX = x;
        startY = y;
        controlX = null;
        // Pairs after a move are lines.
        command = relative ? 'l' : 'L';
      case 'L':
        x = dx + number();
        y = dy + number();
        path.lineTo(x, y);
        controlX = null;
      case 'H':
        x = dx + number();
        path.lineTo(x, y);
        controlX = null;
      case 'V':
        y = dy + number();
        path.lineTo(x, y);
        controlX = null;
      case 'C':
        final x1 = dx + number(), y1 = dy + number();
        final x2 = dx + number(), y2 = dy + number();
        x = dx + number();
        y = dy + number();
        path.cubicTo(x1, y1, x2, y2, x, y);
        controlX = x2;
        controlY = y2;
      case 'S':
        final x1 = controlX == null ? x : 2 * x - controlX;
        final y1 = controlX == null ? y : 2 * y - controlY!;
        final x2 = dx + number(), y2 = dy + number();
        x = dx + number();
        y = dy + number();
        path.cubicTo(x1, y1, x2, y2, x, y);
        controlX = x2;
        controlY = y2;
      case 'Z':
        path.close();
        x = startX;
        y = startY;
        controlX = null;
        if (!isCommand(i) && i < tokens.length) {
          throw FormatException('Numbers after Z', data);
        }
      default:
        throw FormatException('Unsupported path command $command', data);
    }
  }
  return path;
}
