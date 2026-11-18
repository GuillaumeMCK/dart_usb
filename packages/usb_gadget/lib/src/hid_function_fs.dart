/// @docImport 'package:usb_gadget/src/function.dart';
library;

// Hooks return FutureOr<void>, like CustomFunction's.
// ignore_for_file: avoid_futureor_void

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:usb_gadget/src/custom/custom.dart';
import 'package:usb_models/usb_models.dart';

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
/// [onOtherSetup].
class HidFunctionFs({
  required this.config,
  required List<int> reportDescriptor,
  String name = '',
  this.subClass = 0,
  int protocol = 0,
  int hidVersion = 0x0111,
  int countryCode = 0,
  super.queueLength,
}) extends CustomFunction {
  /// A HID function with interrupt endpoints from [config] and
  /// [reportDescriptor].
  this
    : reportDescriptor = Uint8List.fromList(reportDescriptor),
      _protocol = protocol,
      hidDescriptor = HidDescriptor(
        hidVersion: hidVersion,
        countryCode: countryCode,
        reportLength: reportDescriptor.length,
      ),
      super(
        interfaces: [
          CustomInterface(
            class_: Class(.hid, subClass, protocol),
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

  /// The HID class descriptor.
  final HidDescriptor hidDescriptor;

  /// 1 for a boot interface device.
  final int subClass;

  int _protocol;

  /// The protocol in use: for boot devices, 0 boot and 1 report.
  int get protocol => _protocol;

  final _idleRates = <int, int>{};

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

  /// The host switched between the boot (0) and report (1) protocols.
  @protected
  FutureOr<void> onSetProtocol(int protocol) {}

  /// A request that isn't a HID request. The default stalls it.
  @protected
  FutureOr<void> onOtherSetup(ControlRequest request) {}

  @override
  @mustCallSuper
  Future<void> onSetup(ControlRequest request) async {
    final ControlRequest(:setup) = request;
    final low = setup.value & 0xFF, high = setup.value >> 8;
    switch ((request, setup.type, setup.request)) {
      case (final ControlInRequest r, .standard, 0x06)
          when high == HidDescriptorType.hid.value:
        await r.send(hidDescriptor.toBytes());
      case (final ControlInRequest r, .standard, 0x06)
          when high == HidDescriptorType.report.value:
        await r.send(reportDescriptor);
      case (final ControlInRequest r, .class_, 0x01): // GET_REPORT
        final report = await onGetReport(HidReportType.fromByte(high), low);
        if (report != null) await r.send(report);
      case (final ControlOutRequest r, .class_, 0x09): // SET_REPORT
        await onSetReport(HidReportType.fromByte(high), low, await r.receive());
      case (final ControlInRequest r, .class_, 0x02): // GET_IDLE
        await r.send([_idleRates[low] ?? _idleRates[0] ?? 0]);
      case (final ControlOutRequest r, .class_, 0x0A): // SET_IDLE
        _idleRates[low] = high;
        await r.ack();
        await onSetIdle(low, high);
      case (final ControlInRequest r, .class_, 0x03): // GET_PROTOCOL
        await r.send([_protocol]);
      case (final ControlOutRequest r, .class_, 0x0B): // SET_PROTOCOL
        _protocol = low;
        await r.ack();
        await onSetProtocol(low);
      default:
        await onOtherSetup(request);
    }
  }
}
