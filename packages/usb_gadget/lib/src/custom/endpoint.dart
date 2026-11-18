part of 'custom.dart';

/// The data side of a [CustomEndpoint]. I/O works once the function's
/// gadget is registered and the host has enabled the function; if the
/// function is registered again, the endpoint follows it.
sealed class EndpointIo<N extends RustOpaqueInterface> {
  EndpointIo({this.queueLength = 16}) {
    if (queueLength < 1) {
      throw ArgumentError.value(
        queueLength,
        'queueLength',
        'must be at least 1',
      );
    }
  }

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

  /// Maximum packet size negotiated with the host.
  Future<int> get maxPacketSize;

  /// The endpoint address the host sees.
  Future<int> get address;

  /// Stalls the endpoint.
  Future<void> halt();

  /// Clears a stall.
  Future<void> clearHalt();

  /// Cancels pending operations and queued transfers; they throw a
  /// `cancelled` [GadgetException].
  void cancel();
}

/// An IN endpoint: the gadget writes data for the host to read.
///
/// For throughput, write chunks much larger than the max packet size, such
/// as 16 KiB; [write] queues them and returns, [flush] waits for them.
final class InEndpoint extends EndpointIo<rust.EndpointSender> {
  InEndpoint({super.queueLength});

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

  /// Writes every chunk of [stream], then flushes. Chunks are queued as
  /// they come, up to [queueLength] in flight.
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      await write(chunk);
    }
    await flush();
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
final class OutEndpoint extends EndpointIo<rust.EndpointReceiver> {
  OutEndpoint({super.queueLength});

  var _streaming = false;

  /// Reads one transfer of up to [maxLength] bytes (a multiple of the max
  /// packet size), waiting up to [timeout]. A short packet ends the
  /// transfer early.
  Future<Uint8List> read({int maxLength = 16384, Duration? timeout}) {
    if (_streaming) throw StateError('OutEndpoint is being streamed');
    return _io.receive(maxLength, false, timeout);
  }

  /// Every transfer received, keeping [queueLength] buffers of [chunkSize]
  /// bytes queued so the host rarely waits on Dart.
  ///
  /// Start it on [EnableEvent]: it ends when the host disables the function
  /// (or hasn't enabled it yet). Pausing the subscription stops reading:
  /// once the queued buffers fill, the host is held off (NAKed) until it
  /// resumes. Cancelling cancels the queued buffers.
  Stream<Uint8List> stream({int chunkSize = 16384}) =>
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
