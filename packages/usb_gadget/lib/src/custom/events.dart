part of 'custom.dart';

/// Where a [CustomFunction] is in its life.
enum CustomFunctionState() {
  /// Not part of a registered gadget.
  unregistered,

  /// Registered; the gadget isn't bound to a controller.
  registered,

  /// Bound to a controller; the host hasn't enabled the function.
  bound,

  /// The host enabled the function: endpoints are usable.
  enabled,

  /// The host disabled the function, or reset the device.
  disabled,

  /// The bus is suspended.
  suspended,

  /// The gadget was removed.
  removed,
}

/// A control request for a [CustomFunction], passed to
/// [CustomFunction.onSetup]. Answer it once; a request left unanswered when
/// `onSetup` completes is stalled.
sealed class ControlRequest._(this._function, this._id, this.setup) {
  final rust.CustomFunction _function;
  final int _id;
  var _answered = false;

  /// The request.
  final SetupPacket setup;

  /// Whether the request was answered.
  bool get isAnswered => _answered;

  void _answer() {
    if (_answered) throw StateError('control request already answered');
    _answered = true;
  }

  /// Rejects the request: the host sees a stall.
  Future<void> halt() {
    _answer();
    return _function.replyHalt(_id);
  }
}

/// A control request whose data goes to the host: answer with [send].
final class ControlInRequest._(super.function, super.id, super.setup)
    extends ControlRequest {
  /// Created by the function.
  this : super._();

  /// Sends the data stage, truncated to the `setup.length` bytes the host
  /// asked for. Returns the number of bytes sent.
  Future<int> send(List<int> data) {
    _answer();
    return _function.replySend(
      _id,
      data.length > setup.length ? data.sublist(0, setup.length) : data,
    );
  }
}

/// A control request whose data comes from the host: accept it with
/// [receive] (or [ack] when there is no data).
final class ControlOutRequest._(super.function, super.id, super.setup)
    extends ControlRequest {
  /// Created by the function.
  this : super._();

  /// Accepts the request and returns its data stage (`setup.length` bytes).
  Future<Uint8List> receive() {
    _answer();
    return _function.replyReceive(_id);
  }

  /// Accepts the request, discarding any data.
  Future<void> ack() => receive();
}
