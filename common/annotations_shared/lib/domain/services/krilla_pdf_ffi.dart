import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _AllocNative = Pointer<Uint8> Function(IntPtr size);
typedef _AllocDart = Pointer<Uint8> Function(int size);

typedef _FreeNative = Void Function(Pointer<Uint8> ptr, IntPtr len);
typedef _FreeDart = void Function(Pointer<Uint8> ptr, int len);

typedef _PingNative = Int32 Function();
typedef _PingDart = int Function();

typedef _RenderNative = Int32 Function(
  Pointer<Uint8> modelJsonPtr,
  IntPtr modelJsonLen,
  Pointer<Uint8> regularFontPtr,
  IntPtr regularFontLen,
  Pointer<Uint8> boldFontPtr,
  IntPtr boldFontLen,
  Pointer<Pointer<Uint8>> outPtr,
  Pointer<IntPtr> outLen,
);
typedef _RenderDart = int Function(
  Pointer<Uint8> modelJsonPtr,
  int modelJsonLen,
  Pointer<Uint8> regularFontPtr,
  int regularFontLen,
  Pointer<Uint8> boldFontPtr,
  int boldFontLen,
  Pointer<Pointer<Uint8>> outPtr,
  Pointer<IntPtr> outLen,
);

DynamicLibrary? _cachedLib;
bool _searchedLib = false;

DynamicLibrary? _loadLibrary() {
  if (_searchedLib) return _cachedLib;
  _searchedLib = true;

  // 1. Apple platforms statically link libpdf_krilla.a with -force_load.
  if (Platform.isIOS || Platform.isMacOS) {
    final lib = DynamicLibrary.process();
    _cachedLib = lib;
    return lib;
  }

  // 2. Standard system / bundle RPATH / Android jniLibs lookup.
  try {
    final lib = DynamicLibrary.open('libpdf_krilla.so');
    _cachedLib = lib;
    return lib;
  } on Object {
    // Fall through to development/test workspace lookup.
  }

  // 3. Walk up from current working directory for flutter test / dart test.
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = File(
      '${dir.path}/native/pdf_krilla/target/release/libpdf_krilla.so',
    );
    if (candidate.existsSync()) {
      try {
        final lib = DynamicLibrary.open(candidate.path);
        _cachedLib = lib;
        return lib;
      } on Object {
        // Ignore and continue walking up.
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<bool> krillaIsAvailable() async {
  final lib = _loadLibrary();
  if (lib == null) return false;
  try {
    final ping = lib.lookupFunction<_PingNative, _PingDart>(
      'asodya_krilla_ping',
    );
    return ping() == 41;
  } on Object {
    return false;
  }
}

Future<Uint8List?> krillaRenderPdf({
  required Uint8List modelJsonBytes,
  required Uint8List regularFontBytes,
  Uint8List? boldFontBytes,
}) async {
  final lib = _loadLibrary();
  if (lib == null) return null;

  final alloc = lib.lookupFunction<_AllocNative, _AllocDart>(
    'asodya_krilla_alloc',
  );
  final free = lib.lookupFunction<_FreeNative, _FreeDart>(
    'asodya_krilla_free_buffer',
  );
  final render = lib.lookupFunction<_RenderNative, _RenderDart>(
    'asodya_krilla_render_pdf',
  );

  final jsonPtr = alloc(modelJsonBytes.length);
  final regPtr = alloc(regularFontBytes.length);
  final boldLen = boldFontBytes?.length ?? 0;
  final boldPtr = boldLen > 0 ? alloc(boldLen) : nullptr.cast<Uint8>();

  // 16 bytes holds Pointer<Uint8> outPtr (8 bytes) + IntPtr outLen (8 bytes).
  final outBox = alloc(16);
  final outPtrSlot = outBox.cast<Pointer<Uint8>>();
  final outLenSlot = Pointer<IntPtr>.fromAddress(outBox.address + 8);

  try {
    jsonPtr.asTypedList(modelJsonBytes.length).setAll(0, modelJsonBytes);
    regPtr.asTypedList(regularFontBytes.length).setAll(0, regularFontBytes);
    if (boldLen > 0 && boldFontBytes != null) {
      boldPtr.asTypedList(boldLen).setAll(0, boldFontBytes);
    }
    outPtrSlot.value = nullptr.cast<Uint8>();
    outLenSlot.value = 0;

    final rc = render(
      jsonPtr,
      modelJsonBytes.length,
      regPtr,
      regularFontBytes.length,
      boldPtr,
      boldLen,
      outPtrSlot,
      outLenSlot,
    );
    if (rc != 0) {
      throw StateError('krilla FFI render failed with code $rc');
    }
    final resultPtr = outPtrSlot.value;
    final resultLen = outLenSlot.value;
    if (resultPtr == nullptr || resultLen <= 0) {
      throw StateError('krilla FFI returned empty buffer');
    }
    try {
      return Uint8List.fromList(resultPtr.asTypedList(resultLen));
    } finally {
      free(resultPtr, resultLen);
    }
  } finally {
    free(jsonPtr, modelJsonBytes.length);
    free(regPtr, regularFontBytes.length);
    if (boldLen > 0) {
      free(boldPtr, boldLen);
    }
    free(outBox, 16);
  }
}
