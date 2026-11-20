import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

@JS('WebAssembly.instantiate')
external JSPromise<JSObject> _wasmInstantiate(
  JSArrayBuffer bytes,
  JSObject importObject,
);

JSObject? _wasmInstance;

Future<JSObject?> _ensureWasm() async {
  if (_wasmInstance != null) return _wasmInstance;
  try {
    web.Response? resp;
    for (final url in [
      'assets/packages/annotations_shared/lib/presentation/frontend/assets/wasm/pdf_krilla.wasm',
      'assets/wasm/pdf_krilla.wasm',
    ]) {
      final candidate = await web.window.fetch(url.toJS).toDart;
      if (candidate.ok) {
        resp = candidate;
        break;
      }
    }
    if (resp == null) return null;
    final buf = await resp.arrayBuffer().toDart;
    final result = await _wasmInstantiate(buf, JSObject()).toDart;
    _wasmInstance = result.getProperty<JSObject>('instance'.toJS);
    return _wasmInstance;
  } on Object {
    return null;
  }
}

Future<bool> krillaIsAvailable() async => (await _ensureWasm()) != null;

Future<Uint8List?> krillaRenderPdf({
  required Uint8List modelJsonBytes,
  required Uint8List regularFontBytes,
  Uint8List? boldFontBytes,
}) async {
  final instance = await _ensureWasm();
  if (instance == null) return null;

  final exports = instance.getProperty<JSObject>('exports'.toJS);
  final memory = exports.getProperty<JSObject>('memory'.toJS);
  final allocFn = exports.getProperty<JSFunction>('asodya_krilla_wasm_alloc'.toJS);
  final freeFn = exports.getProperty<JSFunction>('asodya_krilla_wasm_free'.toJS);
  final renderFn = exports.getProperty<JSFunction>(
    'asodya_krilla_wasm_render_pdf'.toJS,
  );

  int alloc(int len) =>
      (allocFn.callAsFunction(null, len.toJS)! as JSNumber).toDartInt;

  void free(int ptr, int len) {
    freeFn.callAsFunction(null, ptr.toJS, len.toJS);
  }

  Uint8List memView() {
    final buf = memory.getProperty<JSArrayBuffer>('buffer'.toJS);
    return buf.toDart.asUint8List();
  }

  final jsonPtr = alloc(modelJsonBytes.length);
  memView().setAll(jsonPtr, modelJsonBytes);

  final regPtr = alloc(regularFontBytes.length);
  memView().setAll(regPtr, regularFontBytes);

  final boldLen = boldFontBytes?.length ?? 0;
  final boldPtr = boldLen > 0 ? alloc(boldLen) : 0;
  if (boldLen > 0 && boldFontBytes != null) {
    memView().setAll(boldPtr, boldFontBytes);
  }

  try {
    final args = <JSAny?>[
      jsonPtr.toJS,
      modelJsonBytes.length.toJS,
      regPtr.toJS,
      regularFontBytes.length.toJS,
      boldPtr.toJS,
      boldLen.toJS,
    ].toJS;
    final packed = renderFn.callMethod<JSAny?>('apply'.toJS, null, args);
    // BigInt u64 packed as (ptr << 32) | len
    final packedBig = (packed as JSBigInt).toString();
    final val = BigInt.parse(packedBig);
    if (val == BigInt.zero) {
      throw StateError('krilla wasm32 render failed');
    }
    final outPtr = (val >> 32).toInt();
    final outLen = (val & BigInt.from(0xFFFFFFFF)).toInt();
    try {
      return Uint8List.fromList(memView().sublist(outPtr, outPtr + outLen));
    } finally {
      free(outPtr, outLen);
    }
  } finally {
    free(jsonPtr, modelJsonBytes.length);
    free(regPtr, regularFontBytes.length);
    if (boldLen > 0) {
      free(boldPtr, boldLen);
    }
  }
}
