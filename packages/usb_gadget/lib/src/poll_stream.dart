import 'dart:async';

import 'package:usb_gadget/src/rust/api/error.dart';

/// A single-subscription stream fed by repeatedly awaiting [next] on a
/// native object, for native sources flutter_rust_bridge can't push from.
///
/// - Waits for [native] first, so it can be listened to before the gadget
///   is registered.
/// - Doesn't call [next] while paused, so a slow listener pushes back on
///   the native side (and on the host) instead of buffering in Dart.
/// - Ends without an error when the native side reports
///   [GadgetErrorKind.disconnected]: the function was disabled or removed.
/// - Ends without an error once [isCurrent] returns false: the native
///   object was replaced by a new registration.
/// - [stop] runs once when the listener cancels or the stream ends.
Stream<T> pollStream<N, T extends Object>({
  required Future<N> native,
  required Future<T?> Function(N native) next,
  void Function(N native)? start,
  void Function(N native)? stop,
  bool Function(N native)? isCurrent,
}) {
  late final StreamController<T> controller;
  var active = false;
  N? attached;
  Completer<void>? resumed;

  void finish() {
    if (!active) return;
    active = false;
    if (attached case final n?) stop?.call(n);
    resumed?.complete();
    resumed = null;
  }

  Future<void> run() async {
    final N n;
    try {
      n = await native;
    } catch (e, s) {
      if (active) controller.addError(e, s);
      finish();
      await controller.close();
      return;
    }
    if (!active) return;
    try {
      start?.call(n);
    } catch (e, s) {
      // Not attached: [stop] must not undo another listener's [start].
      controller.addError(e, s);
      active = false;
      await controller.close();
      return;
    }
    attached = n;
    while (active && (isCurrent?.call(n) ?? true)) {
      if (controller.isPaused) {
        await (resumed ??= Completer()).future;
        continue;
      }
      try {
        final value = await next(n);
        if (value != null && active) controller.add(value);
      } on GadgetException catch (e, s) {
        if (active && e.kind != GadgetErrorKind.disconnected) {
          controller.addError(e, s);
        }
        break;
      } catch (e, s) {
        if (active && (isCurrent?.call(n) ?? true)) controller.addError(e, s);
        break;
      }
    }
    final ended = active;
    finish();
    if (ended) await controller.close();
  }

  controller = StreamController<T>(
    onListen: () {
      active = true;
      unawaited(run());
    },
    onResume: () {
      resumed?.complete();
      resumed = null;
    },
    onCancel: finish,
  );
  return controller.stream;
}
