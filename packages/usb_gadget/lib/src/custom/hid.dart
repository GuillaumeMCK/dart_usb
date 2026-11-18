part of 'custom.dart';

// Hooks return FutureOr<void>, like CustomFunction's.
// ignore_for_file: avoid_futureor_void

/// A HID device implemented in Dart: a [CustomFunction] that answers the
/// HID class requests itself, where [HidFunction] leaves them to the
/// kernel.
///
/// ```dart
/// class Gamepad extends HidFunctionFs {
///   Gamepad()
///     : super(
///         name: 'Gamepad',
///         config: const .inputOnly(maxPacketSize: 7),
///         reportDescriptor: gamepadReportDescriptor,
///       );
///
///   @override
///   void onEnable() => epIn.writeWhile(
///     condition: () => state == .enabled,
///     data: report,
///     interval: config.reportInterval,
///   );
/// }
/// ```
///
/// It answers GET_DESCRIPTOR (HID and report), GET_REPORT ([onGetReport]),
/// SET_REPORT ([onSetReport]), GET/SET_IDLE ([onSetIdle]) and
/// GET/SET_PROTOCOL ([onSetProtocol]); everything else goes to
/// [onOtherSetup]. Override those rather than [onSetup].
class HidFunctionFs({
  required this.config,
  required List<int> reportDescriptor,
  String name = '',
  this.subClass = 0,
  this.interfaceProtocol = 0,
  int hidVersion = 0x0111,
  int countryCode = 0,
  super.queueLength,
}) extends CustomFunction {
  /// A HID function with interrupt endpoints from [config] and
  /// [reportDescriptor].
  this
    : reportDescriptor = Uint8List.fromList(reportDescriptor),
      super(
        interfaces: [
          CustomInterface(
            class_: Class(.hid, subClass, interfaceProtocol),
            name: name,
            endpoints: config.descriptors
                .whereType<EndpointTemplate>()
                .toList(),
            descriptors: [
              HidDescriptor(
                hidVersion: hidVersion,
                countryCode: countryCode,
                reportLength: reportDescriptor.length,
              ),
            ],
          ),
        ],
      );

  /// The interrupt endpoints.
  final HidEndpointConfig config;

  /// The report descriptor the host reads.
  final Uint8List reportDescriptor;

  /// 1 for a boot interface device.
  final int subClass;

  /// `bInterfaceProtocol`: for boot devices, 1 keyboard and 2 mouse.
  final int interfaceProtocol;

  /// The HID class descriptor.
  HidDescriptor get hidDescriptor =>
      interfaces.single.descriptors.single as HidDescriptor;

  /// Whether the host selected the boot protocol with SET_PROTOCOL. Devices
  /// start in the report protocol, and return to it when disabled.
  bool get bootProtocol => _bootProtocol;
  var _bootProtocol = false;

  final _idleRates = <int, int>{};

  @override
  void _reset() {
    _bootProtocol = false;
    _idleRates.clear();
  }

  /// The interrupt IN endpoint, for input reports.
  InEndpoint get epIn => endpointIn(
    config.inEndpointNumber ??
        (throw StateError('this HID function has no IN endpoint')),
  );

  /// The interrupt OUT endpoint, for output reports.
  OutEndpoint get epOut => endpointOut(
    config.outEndpointNumber ??
        (throw StateError('this HID function has no OUT endpoint')),
  );

  /// The report for GET_REPORT of [type] and [reportId]; `null` stalls.
  /// Include the report ID byte if the descriptor uses report IDs.
  @protected
  FutureOr<List<int>?> onGetReport(HidReportType type, int reportId) => null;

  /// The host sent a report with SET_REPORT.
  @protected
  FutureOr<void> onSetReport(
    HidReportType type,
    int reportId,
    Uint8List data,
  ) {}

  /// The host set the idle rate of [reportId] (0 for all) to [duration] in
  /// 4 ms units; 0 means report only on change.
  @protected
  FutureOr<void> onSetIdle(int reportId, int duration) {}

  /// The host switched to the boot protocol ([boot]) or the report one.
  @protected
  FutureOr<void> onSetProtocol({required bool boot}) {}

  /// A request that isn't a HID request. The default stalls it.
  @protected
  FutureOr<void> onOtherSetup(ControlRequest request) {}

  @override
  Future<void> onSetup(ControlRequest request) async {
    final ControlRequest(:setup) = request;
    final low = setup.value & 0xFF, high = setup.value >> 8;
    // Report types outside 1-3 are invalid; they stall (unanswered).
    final reportType = switch (high) {
      1 => HidReportType.input,
      2 => HidReportType.output,
      3 => HidReportType.feature,
      _ => null,
    };
    switch ((request, setup.type, setup.request)) {
      case (final ControlInRequest r, .standard, 0x06)
          when high == HidDescriptorType.hid.value:
        await r.send(hidDescriptor.toBytes());
      case (final ControlInRequest r, .standard, 0x06)
          when high == HidDescriptorType.report.value:
        await r.send(reportDescriptor);
      case (final ControlInRequest r, .class_, 0x01): // GET_REPORT
        if (reportType == null) return;
        final report = await onGetReport(reportType, low);
        if (report != null) await r.send(report);
      case (final ControlOutRequest r, .class_, 0x09): // SET_REPORT
        if (reportType == null) return;
        await onSetReport(reportType, low, await r.receive());
      case (final ControlInRequest r, .class_, 0x02): // GET_IDLE
        await r.send([_idleRates[low] ?? _idleRates[0] ?? 0]);
      case (final ControlOutRequest r, .class_, 0x0A): // SET_IDLE
        _idleRates[low] = high;
        await r.ack();
        await onSetIdle(low, high);
      case (final ControlInRequest r, .class_, 0x03): // GET_PROTOCOL
        await r.send([if (_bootProtocol) 0 else 1]);
      case (final ControlOutRequest r, .class_, 0x0B) // SET_PROTOCOL
          when low <= 1:
        _bootProtocol = low == 0;
        await r.ack();
        await onSetProtocol(boot: _bootProtocol);
      case (ControlOutRequest(), .class_, 0x0B):
        return; // Neither boot (0) nor report (1): stall.
      default:
        await onOtherSetup(request);
    }
  }
}
