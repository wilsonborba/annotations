import 'package:annotations_shared/core/tracking_manifest.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../components/controls.dart';
import '../../components/scope.dart';
import '../../components/shell.dart';
import '../../components/tokens.dart';

/// Opens or creates an Instant room by its code (annotations#44). The room
/// itself, with the shared editor, is [InstantRoomPage] at
/// /v1/instant/{code}.
class InstantPage extends StatefulWidget {
  const InstantPage({super.key});
  @override
  State<InstantPage> createState() => _InstantPageState();
}

class _InstantPageState extends State<InstantPage> {
  final code = TextEditingController();

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  void openCode(String value) {
    trackSubmit(context, 'instant.room.open');
    if (value.trim().isNotEmpty) {
      context.go('/v1/instant/${Uri.encodeComponent(value.trim())}');
    }
  }

  @override
  Widget build(BuildContext context) => ContentWidth(
    width: 980,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ANNOTATIONS',
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.7,
            fontWeight: FontWeight.w700,
            color: context.colors.textSecondary,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          context.tr('roomTitle'),
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 18),
        Text(
          context.tr('roomLead'),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 35),
        track(
          'instant.room.code',
          TextField(
            controller: code,
            decoration: InputDecoration(labelText: context.tr('roomCode')),
            onSubmitted: openCode,
          ),
          controller: code,
          sensitive: true,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: track(
            'instant.room.open',
            AppButton.primary(
              label: context.tr('openRoom'),
              onPressed: () => openCode(code.text),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(context.tr('roomNote')),
      ],
    ),
  );
}
