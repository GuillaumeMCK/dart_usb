part of 'custom.dart';

/// Something that happened to a [CustomFunction].
sealed class CustomEvent {
  const CustomEvent();
}

/// The function was bound to a controller.
final class BindEvent extends CustomEvent {
  const BindEvent();
}

/// The function was unbound from its controller.
final class UnbindEvent extends CustomEvent {
  const UnbindEvent();
}

/// The host selected a configuration with this function: endpoints are
/// usable.
final class EnableEvent extends CustomEvent {
  const EnableEvent();
}

/// The host deselected the configuration, or the device was reset.
/// Endpoint streams end.
final class DisableEvent extends CustomEvent {
  const DisableEvent();
}

/// The bus was suspended.
final class SuspendEvent extends CustomEvent {
  const SuspendEvent();
}

/// The bus resumed.
final class ResumeEvent extends CustomEvent {
  const ResumeEvent();
}

/// A FunctionFS event this version doesn't know.
final class UnknownEvent extends CustomEvent {
  const UnknownEvent(this.code);

  final int code;
}

/// A control request for this function; answer it exactly once, within
/// 4.5 seconds. A late answer throws a `timedOut` [GadgetException]: the
/// request was already stalled.
sealed class ControlRequest extends CustomEvent {
  ControlRequest._(this._function, this._id, this.setup);

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
final class ControlInRequest extends ControlRequest {
  ControlInRequest._(super.function, super.id, super.setup) : super._();

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
final class ControlOutRequest extends ControlRequest {
  ControlOutRequest._(super.function, super.id, super.setup) : super._();

  /// Accepts the request and returns its data stage (`setup.length` bytes).
  Future<Uint8List> receive() {
    _answer();
    return _function.replyReceive(_id);
  }
}
