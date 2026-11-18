part of 'custom.dart';

/// A data endpoint of a [CustomFunction], declared with an
/// [EndpointTemplate] and fetched with [CustomFunction.endpointIn] or
/// [CustomFunction.endpointOut].
///
/// I/O works while the host has the function enabled (between
/// [CustomFunction.onEnable] and [CustomFunction.onDisable]). If the
/// function is registered again, the endpoint follows it.
sealed class EndpointIo<N extends RustOpaqueInterface>._(
  this.template,
  this.queueLength,
) {
  /// How the endpoint was declared.
  final EndpointTemplate template;

  /// Transfers queued in the kernel at once. Deeper queues keep the
  /// endpoint busy while Dart catches up.
  final int queueLength;

  N? _native;
  Completer<N>? _nextNative;

  void _attach(N native) {
    _native?.dispose();
    _native = native;
    _nextNative?.complete(native);
    _nextNative = null;
  }

  /// The current native endpoint, or the first one once registered.
  Future<N> get _live async =>
      _native ?? await (_nextNative ??= Completer()).future;

  N get _io =>
      _native ??
      (throw StateError(
        "the endpoint's function is not part of a registered gadget",
      ));

  /// The number this endpoint was declared with.
  EndpointNumber get number => template.address.number;

  /// Maximum packet size negotiated with the host.
  Future<int> get maxPacketSize;

  /// The endpoint address the host sees; FunctionFS may renumber endpoints.
  Future<int> get address;

  /// Stalls the endpoint.
  Future<void> halt();

  /// Clears a stall.
  Future<void> clearHalt();

  /// Cancels pending operations and queued transfers; they throw a
  /// `cancelled` [GadgetException].
  void cancel();

  @override
  String toString() =>
      '${this is InEndpoint ? 'InEndpoint' : 'OutEndpoint'}(${number.value})';
}

/// An IN endpoint: the gadget writes data for the host to read.
///
/// [write] queues data and returns once it is queued; [flush] waits until
/// it is sent. For throughput, write chunks much larger than the max packet
/// size, such as 16 KiB.
final class InEndpoint._(super.template, super.queueLength)
    extends EndpointIo<rust.EndpointSender> {
  /// Created by the function.
  this : super._();

  /// Queues [data], waiting up to [timeout] for queue space.
  Future<void> write(List<int> data, {Duration? timeout}) =>
      _io.send(data, timeout);

  /// Waits up to [timeout] for queued data to be sent. On timeout, queued
  /// transfers are cancelled.
  Future<void> flush({Duration? timeout}) => _io.flush(timeout);

  /// Writes [data] and waits until it is sent.
  Future<void> writeAndFlush(List<int> data, {Duration? timeout}) async {
    await write(data, timeout: timeout);
    await flush(timeout: timeout);
  }

  /// Writes every chunk of [stream], then flushes.
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      await write(chunk);
    }
    await flush();
  }

  /// Writes [data]`()` every [interval] while [condition]`()` holds, such
  /// as HID reports while the function is enabled. Write errors (the host
  /// not reading yet) skip that period.
  Future<void> writeWhile({
    required bool Function() condition,
    required List<int> Function() data,
    required Duration interval,
  }) async {
    while (condition()) {
      final next = Future<void>.delayed(interval);
      try {
        await write(data(), timeout: interval);
      } on GadgetException {
        // Queue full or endpoint not ready: drop this period's data.
      }
      await next;
    }
  }

  @override
  Future<int> get maxPacketSize => _io.maxPacketSize();

  @override
  Future<int> get address => _io.realAddress();

  @override
  Future<void> halt() => _io.halt();

  @override
  Future<void> clearHalt() => _io.clearHalt();

  @override
  void cancel() => _native?.cancel();
}

/// An OUT endpoint: the gadget reads data the host wrote.
///
/// Use either [read] or one [stream] at a time.
final class OutEndpoint._(super.template, super.queueLength)
    extends EndpointIo<rust.EndpointReceiver> {
  /// Created by the function.
  this : super._();

  var _streaming = false;

  /// Reads one transfer of up to [maxLength] bytes (a multiple of the max
  /// packet size), waiting up to [timeout]. A short packet ends the
  /// transfer early.
  Future<Uint8List> read({int maxLength = 16_384, Duration? timeout}) {
    if (_streaming) throw StateError('OutEndpoint is being streamed');
    return _io.receive(maxLength, false, timeout);
  }

  /// Every transfer received, keeping [queueLength] buffers of [chunkSize]
  /// bytes queued so the host rarely waits on Dart.
  ///
  /// Start it in [CustomFunction.onEnable]: it ends when the host disables
  /// the function. Pausing the subscription stops reading, so the host is
  /// held off (NAKed) instead of Dart buffering. Cancelling cancels the
  /// queued buffers.
  Stream<Uint8List> stream({int chunkSize = 16_384}) =>
      pollStream<rust.EndpointReceiver, Uint8List>(
        native: _live,
        start: (_) {
          if (_streaming) {
            throw StateError('OutEndpoint is already being streamed');
          }
          _streaming = true;
        },
        stop: (native) {
          _streaming = false;
          native.cancel();
        },
        next: (native) => native.receive(chunkSize, true, null),
      );

  @override
  Future<int> get maxPacketSize => _io.maxPacketSize();

  @override
  Future<int> get address => _io.realAddress();

  @override
  Future<void> halt() => _io.halt();

  @override
  Future<void> clearHalt() => _io.clearHalt();

  @override
  void cancel() => _native?.cancel();
}
