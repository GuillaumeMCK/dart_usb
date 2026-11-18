part of 'custom.dart';

/// Something that happened to a [CustomFunction].
sealed class const CustomEvent();

/// The function was bound to a controller.
final class const BindEvent() extends CustomEvent {
  /// Creates the event.
  this;
}

/// The function was unbound from its controller.
final class const UnbindEvent() extends CustomEvent {
  /// Creates the event.
  this;
}

/// The host selected a configuration with this function: endpoints are
/// usable.
final class const EnableEvent() extends CustomEvent {
  /// Creates the event.
  this;
}

/// The host deselected the configuration, or the device was reset.
/// Endpoint streams end.
final class const DisableEvent() extends CustomEvent {
  /// Creates the event.
  this;
}

/// The bus was suspended.
final class const SuspendEvent() extends CustomEvent {
  /// Creates the event.
  this;
}

/// The bus resumed.
final class const ResumeEvent() extends CustomEvent {
  /// Creates the event.
  this;
}

/// A FunctionFS event this version doesn't know.
final class const UnknownEvent(this.code) extends CustomEvent {
  /// An event of FunctionFS type [code].
  this;

  /// The FunctionFS event type.
  final int code;
}

/// A control request for this function; answer it exactly once, within
/// 4.5 seconds. A late answer throws a `timedOut` [GadgetException]: the
/// request was already stalled.
sealed class ControlRequest._(this._function, this._id, this.setup)
    extends CustomEvent {
  final rust.CustomFunction _function;
  final int _id;
  var _answered = false;

  /// The request.
  final SetupPacket setup;

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
  /// A request received from the host.
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
/// [receive].
final class ControlOutRequest._(super.function, super.id, super.setup)
    extends ControlRequest {
  /// A request received from the host.
  this : super._();

  /// Accepts the request and returns its data stage (`setup.length` bytes).
  Future<Uint8List> receive() {
    _answer();
    return _function.replyReceive(_id);
  }
}
