import 'package:flutter/material.dart';

Widget embeddedFrame(String url, {double height = 480}) => SizedBox(
  height: height,
  child: const Center(child: Icon(Icons.open_in_browser_rounded)),
);
