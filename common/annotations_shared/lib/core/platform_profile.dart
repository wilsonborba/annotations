import 'dart:ui' show Display, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Device class that decides which features the app shows.
///
/// There is no Windows profile: Windows is not an Annotations target.
enum PlatformProfile {
  /// Installed macOS, Linux, iPad and Android tablet apps.
  fullWriter,

  /// Installed Android phone and iPhone apps.
  phone,

  /// The browser app (apps/cloud).
  browser,
}

/// Android devices with a shortest display side of this many logical
/// pixels (dp) or more are tablets.
const double androidTabletShortestSideDp = 600;

/// Channel of the iOS runner that reports the iPad interface idiom.
const MethodChannel platformProfileChannel = MethodChannel(
  'annotations/platform_profile',
);

/// Chooses the profile from the platform and the device form factor.
///
/// [isPad] is the iOS iPad interface idiom. [shortestSideDp] is the shortest
/// side of the Android display (not of the window) in logical pixels.
/// Returns null for a platform that has no profile.
PlatformProfile? resolvePlatformProfile({
  required bool isWeb,
  required TargetPlatform platform,
  bool isPad = false,
  double? shortestSideDp,
}) {
  if (isWeb) return PlatformProfile.browser;
  switch (platform) {
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return PlatformProfile.fullWriter;
    case TargetPlatform.iOS:
      return isPad ? PlatformProfile.fullWriter : PlatformProfile.phone;
    case TargetPlatform.android:
      final side = shortestSideDp;
      return side != null && side >= androidTabletShortestSideDp
          ? PlatformProfile.fullWriter
          : PlatformProfile.phone;
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return null;
  }
}

/// Shortest side of the physical display in logical pixels, or null when
/// the engine reports no display. The display size does not change when the
/// window is resized or split.
double? displayShortestSideDp(PlatformDispatcher dispatcher) {
  final Display? display = dispatcher.displays.isNotEmpty
      ? dispatcher.displays.first
      : dispatcher.implicitView?.display;
  if (display == null || display.devicePixelRatio <= 0) return null;
  final size = display.size / display.devicePixelRatio;
  if (size.isEmpty) return null;
  return size.shortestSide;
}

/// Asks the iOS runner for the interface idiom. A missing or failed answer
/// counts as not an iPad.
Future<bool> readIsPad() async {
  try {
    return await platformProfileChannel.invokeMethod<bool>('isPad') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Reads the profile of the running device.
///
/// Unknown device sizes fall back to [PlatformProfile.phone], which shows
/// complex content read-only and never drops it.
Future<PlatformProfile> detectPlatformProfile() async {
  final platform = defaultTargetPlatform;
  final profile = resolvePlatformProfile(
    isWeb: kIsWeb,
    platform: platform,
    isPad: !kIsWeb && platform == TargetPlatform.iOS
        ? await readIsPad()
        : false,
    shortestSideDp: !kIsWeb && platform == TargetPlatform.android
        ? displayShortestSideDp(ServicesBinding.instance.platformDispatcher)
        : null,
  );
  if (profile == null) {
    throw UnsupportedError('Annotations has no profile for $platform.');
  }
  return profile;
}
