import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

Widget embeddedFrame(String url, {double height = 480}) => SizedBox(
  height: height,
  width: double.infinity,
  child: HtmlElementView.fromTagName(
    key: ValueKey(url),
    tagName: 'iframe',
    onElementCreated: (element) {
      final frame = element as web.HTMLIFrameElement;
      frame.src = url;
      frame.title = 'Embedded content';
      frame.loading = 'lazy';
      frame.referrerPolicy = 'strict-origin-when-cross-origin';
      frame.allow = 'fullscreen';
      frame.style.border = '0';
      frame.style.width = '100%';
      frame.style.height = '100%';
    },
  ),
);
