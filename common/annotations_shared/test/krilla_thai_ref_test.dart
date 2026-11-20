import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('render Flutter HarfBuzz Thai reference PNG', (tester) async {
    await tester.runAsync(() async {
      final fontFile = File(
        'lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf',
      );
      final bytes = await fontFile.readAsBytes();
      final loader = FontLoader('IBMPlexSansThaiRef')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 595, 842));
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 595, 842),
        Paint()..color = Colors.white,
      );

      final tp1 = TextPainter(
        text: const TextSpan(
          text: 'กิ๊ กี๊ กึ๊ กื๊',
          style: TextStyle(
            fontFamily: 'IBMPlexSansThaiRef',
            fontSize: 18,
            color: Colors.black,
            height: 26 / 18,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 499);
      tp1.paint(canvas, const Offset(48, 72));

      final tp2 = TextPainter(
        text: const TextSpan(
          text:
              'การบันทึกข้อความภาษาไทยในระบบเอกสารดิจิทัลต้องรองรับการวางตำแหน่งสระและวรรณยุกต์อย่างถูกต้องรวมถึงการตัดคำขึ้นบรรทัดใหม่โดยไม่ตัดกลางคำเพื่อให้ผู้อ่านสามารถอ่านและค้นหาข้อความได้อย่างสมบูรณ์',
          style: TextStyle(
            fontFamily: 'IBMPlexSansThaiRef',
            fontSize: 14,
            color: Colors.black,
            height: 22 / 14,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 460);
      tp2.paint(canvas, const Offset(48, 112));

      canvas.drawLine(
        const Offset(48, 190),
        const Offset(547, 190),
        Paint()
          ..color = const Color(0xFF0F62FE)
          ..strokeWidth = 2,
      );

      final picture = recorder.endRecording();
      final image = await picture.toImage(1190, 1684);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('/tmp/krilla_spike').create(recursive: true);
      await File(
        '/tmp/krilla_spike/flutter_thai_ref.png',
      ).writeAsBytes(png!.buffer.asUint8List());
    });
  });
}
