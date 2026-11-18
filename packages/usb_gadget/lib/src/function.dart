import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:usb_models/usb_models.dart';

import 'rust/api/function.dart' as rust;
import 'rust/api/gadget.dart' show FunctionHandle;
import 'rust/api.dart' show ClassCodes;

/// A USB function: one or more interfaces of a gadget, implemented by a
/// kernel driver ([KernelFunction]) or by Dart (`CustomFunction`).
///
/// A function only does something once its gadget is registered; until then
/// [state] is [rust.FunctionState.unregistered].
abstract base class GadgetFunction {
  GadgetFunction();

  /// Registration state.
  rust.FunctionState get state;

  /// The function's configfs directory, once registered.
  String? get path;

  /// Creates the native function on first use and returns a handle for one
  /// configuration.
  @internal
  FunctionHandle createHandle();
}

ClassCodes classCodes(Class c) =>
    ClassCodes(class_: c.code, subClass: c.subClass, protocol: c.protocol);

/// A function implemented by a Linux kernel driver: configured here, then
/// used through the device file or network interface the kernel creates.
abstract base class KernelFunction extends GadgetFunction {
  KernelFunction();

  rust.KernelFunction? _native;

  /// Creates the native function from this function's settings.
  @protected
  rust.KernelFunction create();

  /// The native function. Throws a [StateError] before registration.
  @protected
  rust.KernelFunction get native =>
      _native ??
      (throw StateError('$runtimeType is not part of a registered gadget'));

  @override
  @internal
  FunctionHandle createHandle() {
    // A new registration after removal gets a fresh native function, as
    // custom functions do, rather than reusing one configfs let go of.
    if (_native case final native? when native.state != .removed) {
      return native.handle();
    }
    _native?.dispose();
    return (_native = create()).handle();
  }

  @override
  rust.FunctionState get state => _native?.state ?? .unregistered;

  @override
  String? get path => _native?.path;
}

/// A human interface device implemented by the kernel (`hid`): the gadget
/// sends input reports written to [devicePath] and delivers output reports
/// for reading from it.
///
/// Requires `CONFIG_USB_CONFIGFS_F_HID`.
final class HidFunction extends KernelFunction {
  HidFunction({
    required this.reportDescriptor,
    required this.reportLength,
    this.subClass = 0,
    this.protocol = 0,
    this.noOutEndpoint = false,
  });

  /// The HID report descriptor.
  final List<int> reportDescriptor;

  /// Length of the longest report, in bytes.
  final int reportLength;

  /// 1 for a boot interface device.
  final int subClass;

  /// For boot devices: 1 keyboard, 2 mouse.
  final int protocol;

  /// Omits the interrupt OUT endpoint; output reports then arrive through
  /// control requests.
  final bool noOutEndpoint;

  @override
  rust.KernelFunction create() => rust.KernelFunction.hid(
    spec: rust.HidSpec(
      subClass: subClass,
      protocol: protocol,
      reportDescriptor: Uint8List.fromList(reportDescriptor),
      reportLength: reportLength,
      noOutEndpoint: noOutEndpoint,
    ),
  );

  /// The device file, such as `/dev/hidg0`. Available once registered.
  String get devicePath => native.devicePath();

  /// Opens [devicePath]: write input reports to it, read output reports
  /// from it.
  Future<RandomAccessFile> open() => File(devicePath).open(mode: .append);
}

/// A logical unit of a [MassStorageFunction].
final class Lun {
  /// A unit backed by [file], a disk image or block device.
  const Lun(
    String this.file, {
    this.readOnly = false,
    this.cdrom = false,
    this.noFua = false,
    this.removable = false,
    this.inquiryString = '',
  });

  /// A removable unit with no medium; load one with
  /// [MassStorageFunction.setFile].
  const Lun.empty({
    this.readOnly = false,
    this.cdrom = false,
    this.noFua = false,
    this.inquiryString = '',
  }) : file = null,
       removable = true;

  final String? file;
  final bool readOnly;

  /// Emulates a CD-ROM; implies [readOnly].
  final bool cdrom;

  /// Ignores the FUA (force unit access) flag of SCSI writes.
  final bool noFua;
  final bool removable;

  /// SCSI inquiry string; empty for the kernel's default.
  final String inquiryString;
}

/// A USB mass storage device (`mass_storage`).
///
/// Requires `CONFIG_USB_CONFIGFS_MASS_STORAGE`.
final class MassStorageFunction extends KernelFunction {
  MassStorageFunction(this.luns, {this.stall});

  final List<Lun> luns;

  /// Lets the function halt bulk endpoints; `null` for the kernel's default.
  final bool? stall;

  @override
  rust.KernelFunction create() => rust.KernelFunction.massStorage(
    stall: stall,
    luns: [
      for (final lun in luns)
        rust.LunSpec(
          file: lun.file,
          readOnly: lun.readOnly,
          cdrom: lun.cdrom,
          noFua: lun.noFua,
          removable: lun.removable,
          inquiryString: lun.inquiryString,
        ),
    ],
  );

  /// Ejects the medium of unit [lun], even if the host locked it.
  Future<void> forceEject(int lun) => native.forceEject(lun);

  /// Loads [file] into unit [lun]; `null` ejects it.
  Future<void> setFile(int lun, String? file) => native.setFile(lun, file);
}

/// Ethernet over USB flavours of [NetFunction].
enum NetClass {
  /// CDC ECM; most hosts except Windows. `CONFIG_USB_CONFIGFS_ECM`.
  ecm,

  /// CDC ECM subset. `CONFIG_USB_CONFIGFS_ECM_SUBSET`.
  ecmSubset,

  /// CDC EEM. `CONFIG_USB_CONFIGFS_EEM`.
  eem,

  /// CDC NCM; Linux, macOS and Windows 11. `CONFIG_USB_CONFIGFS_NCM`.
  ncm,

  /// RNDIS, for older Windows. `CONFIG_USB_CONFIGFS_RNDIS`.
  rndis,
}

/// A network interface between the gadget and the host.
final class NetFunction extends KernelFunction {
  NetFunction(
    this.netClass, {
    List<int>? deviceAddress,
    List<int>? hostAddress,
    this.qmult,
    this.interfaceClass,
  }) : requestedDeviceAddress = deviceAddress,
       requestedHostAddress = hostAddress;

  final NetClass netClass;

  /// The device-end MAC address asked for; `null` lets the kernel pick.
  final List<int>? requestedDeviceAddress;

  /// The host-end MAC address asked for; `null` lets the kernel pick.
  final List<int>? requestedHostAddress;

  /// Queue length multiplier for high and super speed.
  final int? qmult;

  /// RNDIS only: the interface class to report.
  final Class? interfaceClass;

  @override
  rust.KernelFunction create() => rust.KernelFunction.net(
    spec: rust.NetSpec(
      class_: switch (netClass) {
        .ecm => .ecm,
        .ecmSubset => .ecmSubset,
        .eem => .eem,
        .ncm => .ncm,
        .rndis => .rndis,
      },
      deviceAddress: switch (requestedDeviceAddress) {
        final a? => Uint8List.fromList(a),
        null => null,
      },
      hostAddress: switch (requestedHostAddress) {
        final a? => Uint8List.fromList(a),
        null => null,
      },
      qmult: qmult,
      interfaceClass: interfaceClass == null
          ? null
          : classCodes(interfaceClass!),
    ),
  );

  /// Name of the gadget-side network interface, such as `usb0`.
  String get interfaceName => native.interfaceName();

  /// MAC address of the gadget end: the one given, or the kernel's.
  Uint8List get deviceAddress => native.deviceAddress();

  /// MAC address of the host end: the one given, or the kernel's.
  Uint8List get hostAddress => native.hostAddress();
}

/// A serial port: CDC ACM (`acm`, needs `CONFIG_USB_CONFIGFS_ACM`) by
/// default, or the generic serial driver (`CONFIG_USB_CONFIGFS_SERIAL`).
final class SerialFunction extends KernelFunction {
  SerialFunction({this.acm = true, this.console});

  final bool acm;

  /// Uses the port as a kernel console (`CONFIG_U_SERIAL_CONSOLE`).
  final bool? console;

  @override
  rust.KernelFunction create() =>
      rust.KernelFunction.serial(acm: acm, console: console);

  /// The gadget-side tty, such as `/dev/ttyGS0`. Available once registered.
  String get devicePath => native.devicePath();
}

/// A USB MIDI adapter backed by an ALSA sound card (`midi`).
///
/// Requires `CONFIG_USB_CONFIGFS_F_MIDI`.
final class MidiFunction extends KernelFunction {
  MidiFunction({
    this.bufferLength,
    this.id,
    this.inPorts,
    this.outPorts,
    this.index,
    this.queueLength,
    this.interfaceString,
  });

  final int? bufferLength;

  /// ID string of the sound card.
  final String? id;
  final int? inPorts;
  final int? outPorts;

  /// Sound card index; `null` picks one.
  final int? index;
  final int? queueLength;

  /// AudioControl interface string (Linux 7.0+).
  final String? interfaceString;

  @override
  rust.KernelFunction create() => rust.KernelFunction.midi(
    spec: rust.MidiSpec(
      bufferLength: bufferLength,
      id: id,
      inPorts: inPorts,
      outPorts: outPorts,
      index: index,
      queueLength: queueLength,
      interfaceString: interfaceString,
    ),
  );
}

/// A USB printer; print jobs arrive on `/dev/g_printerN` (`printer`).
///
/// Requires `CONFIG_USB_CONFIGFS_F_PRINTER`.
final class PrinterFunction extends KernelFunction {
  PrinterFunction({this.pnpString, this.queueLength});

  /// IEEE 1284 device ID, such as `MFG:ACME;MDL:Printer;`.
  final String? pnpString;

  /// Number of 8 KiB buffers per endpoint.
  final int? queueLength;

  @override
  rust.KernelFunction create() => rust.KernelFunction.printer(
    pnpString: pnpString,
    queueLength: queueLength,
  );
}

/// Echoes OUT data back on IN, for testing (`Loopback`).
///
/// Requires `CONFIG_USB_ZERO`.
final class LoopbackFunction extends KernelFunction {
  LoopbackFunction({this.queueLength, this.bulkBufferLength});

  final int? queueLength;
  final int? bulkBufferLength;

  @override
  rust.KernelFunction create() => rust.KernelFunction.loopback(
    queueLength: queueLength,
    bulkBufferLength: bulkBufferLength,
  );
}

/// Sources and sinks data, for throughput testing (`SourceSink`).
///
/// Requires `CONFIG_USB_ZERO`.
final class SourceSinkFunction extends KernelFunction {
  SourceSinkFunction({
    this.pattern,
    this.isocInterval,
    this.isocMaxPacket,
    this.isocMult,
    this.isocMaxBurst,
    this.bulkBufferLength,
    this.bulkQueueLength,
    this.isocQueueLength,
  });

  /// 0 zeros, 1 bytes mod 63, 2 no checking.
  final int? pattern;
  final int? isocInterval;
  final int? isocMaxPacket;
  final int? isocMult;
  final int? isocMaxBurst;
  final int? bulkBufferLength;
  final int? bulkQueueLength;
  final int? isocQueueLength;

  @override
  rust.KernelFunction create() => rust.KernelFunction.sourceSink(
    spec: rust.SourceSinkSpec(
      pattern: pattern,
      isocInterval: isocInterval,
      isocMaxPacket: isocMaxPacket,
      isocMult: isocMult,
      isocMaxBurst: isocMaxBurst,
      bulkBufferLength: bulkBufferLength,
      bulkQueueLength: bulkQueueLength,
      isocQueueLength: isocQueueLength,
    ),
  );
}

/// One direction of an [AudioFunction]. `null` fields keep the kernel's
/// default; fields marked UAC2 are ignored by UAC1.
final class AudioStream {
  const AudioStream({
    this.channelMask,
    this.sampleRate,
    this.sampleSize,
    this.syncType,
    this.hsInterval,
    this.mutePresent,
    this.terminalType,
    this.volumePresent,
    this.volumeMin,
    this.volumeMax,
    this.volumeResolution,
    this.volumeName,
    this.inputTerminalName,
    this.inputTerminalChannelName,
    this.outputTerminalName,
  });

  /// No stream in this direction.
  static const disabled = AudioStream(channelMask: 0);

  /// Channels present, one bit each: 0x3 for stereo.
  final int? channelMask;

  /// In Hz.
  final int? sampleRate;

  /// Bytes per sample.
  final int? sampleSize;

  /// UAC2.
  final int? syncType;

  /// UAC2.
  final int? hsInterval;
  final bool? mutePresent;

  /// UAC2.
  final int? terminalType;
  final bool? volumePresent;
  final int? volumeMin;
  final int? volumeMax;
  final int? volumeResolution;
  final String? volumeName;
  final String? inputTerminalName;
  final String? inputTerminalChannelName;
  final String? outputTerminalName;

  rust.AudioStreamSpec _spec() => rust.AudioStreamSpec(
    channel: rust.AudioChannelSpec(
      channelMask: channelMask,
      sampleRate: sampleRate,
      sampleSize: sampleSize,
    ),
    syncType: syncType,
    hsInterval: hsInterval,
    mutePresent: mutePresent,
    terminalType: terminalType,
    volumePresent: volumePresent,
    volumeMin: volumeMin,
    volumeMax: volumeMax,
    volumeResolution: volumeResolution,
    volumeName: volumeName,
    inputTerminalName: inputTerminalName,
    inputTerminalChannelName: inputTerminalChannelName,
    outputTerminalName: outputTerminalName,
  );
}

/// A USB sound card backed by an ALSA device on the gadget: capture is
/// audio the gadget sends to the host, playback what it receives.
final class AudioFunction extends KernelFunction {
  /// USB Audio Class 1 (`uac1`, `CONFIG_USB_CONFIGFS_F_UAC1`).
  AudioFunction.uac1({
    this.capture = const AudioStream(),
    this.playback = const AudioStream(),
    this.requestNumber,
    this.functionName,
  }) : version = 1,
       fbMax = null,
       controlName = null,
       clockSourceInName = null,
       clockSourceOutName = null;

  /// USB Audio Class 2 (`uac2`, `CONFIG_USB_CONFIGFS_F_UAC2`).
  AudioFunction.uac2({
    this.capture = const AudioStream(),
    this.playback = const AudioStream(),
    this.requestNumber,
    this.functionName,
    this.fbMax,
    this.controlName,
    this.clockSourceInName,
    this.clockSourceOutName,
  }) : version = 2;

  /// 1 or 2.
  final int version;
  final AudioStream capture;
  final AudioStream playback;
  final int? requestNumber;
  final String? functionName;
  final int? fbMax;
  final String? controlName;
  final String? clockSourceInName;
  final String? clockSourceOutName;

  @override
  rust.KernelFunction create() => rust.KernelFunction.audio(
    spec: rust.AudioSpec(
      version: version,
      capture: capture._spec(),
      playback: playback._spec(),
      requestNumber: requestNumber,
      functionName: functionName,
      fbMax: fbMax,
      controlName: controlName,
      clockSourceInName: clockSourceInName,
      clockSourceOutName: clockSourceOutName,
    ),
  );
}

/// Pixel format of a [VideoFrame].
final class VideoFormat {
  const VideoFormat._(
    this._kind, [
    this.guid = const [],
    this.name = '',
    this.bitsPerPixel = 0,
  ]);

  /// A frame-based format identified by its 16-byte [guid]. [name] names
  /// its configfs directory; [bitsPerPixel] is 0 for compressed formats.
  const VideoFormat.framebased(
    List<int> guid,
    String name, {
    int bitsPerPixel = 0,
  }) : this._(rust.VideoFormatKind.framebased, guid, name, bitsPerPixel);

  /// Uncompressed packed YUV 4:2:2.
  static const yuyv = VideoFormat._(rust.VideoFormatKind.yuyv);

  /// Motion JPEG.
  static const mjpeg = VideoFormat._(rust.VideoFormatKind.mjpeg);

  /// Uncompressed NV12.
  static const nv12 = VideoFormat.framebased(_nv12, 'nv12', bitsPerPixel: 12);

  /// H.264.
  static const h264 = VideoFormat.framebased(_h264, 'h264');

  static const _nv12 = [
    0x4E,
    0x56,
    0x31,
    0x32,
    0,
    0,
    0x10,
    0,
    0x80,
    0,
    0,
    0xAA,
    0,
    0x38,
    0x9B,
    0x71,
  ];
  static const _h264 = [
    0x48,
    0x32,
    0x36,
    0x34,
    0,
    0,
    0x10,
    0,
    0x80,
    0,
    0,
    0xAA,
    0,
    0x38,
    0x9B,
    0x71,
  ];

  final rust.VideoFormatKind _kind;
  final List<int> guid;
  final String name;
  final int bitsPerPixel;
}

/// Color matching descriptor values.
final class ColorMatching {
  const ColorMatching(
    this.colorPrimaries,
    this.transferCharacteristics,
    this.matrixCoefficients,
  );

  final int colorPrimaries;
  final int transferCharacteristics;
  final int matrixCoefficients;
}

/// A frame size and its frame rates.
final class VideoFrame {
  /// [intervals] are frame intervals in 100 ns units.
  const VideoFrame(
    this.width,
    this.height,
    this.format,
    this.intervals, {
    this.colorMatching,
  });

  /// Frame rates given in frames per second.
  VideoFrame.fps(
    this.width,
    this.height,
    this.format,
    List<int> fps, {
    this.colorMatching,
  }) : intervals = [for (final f in fps) 10000000 ~/ f];

  final int width;
  final int height;
  final VideoFormat format;
  final List<int> intervals;
  final ColorMatching? colorMatching;
}

/// A USB video class camera (`uvc`); frames are written to the V4L2 output
/// device the kernel creates.
///
/// Requires `CONFIG_USB_CONFIGFS_F_UVC`.
final class VideoFunction extends KernelFunction {
  VideoFunction(
    this.frames, {
    this.streamingInterval,
    this.streamingMaxBurst,
    this.streamingMaxPacket,
    this.functionName,
    this.processingControls,
    this.cameraControls,
  });

  final List<VideoFrame> frames;
  final int? streamingInterval;
  final int? streamingMaxBurst;

  /// 1024, 2048 or 3072.
  final int? streamingMaxPacket;
  final String? functionName;
  final int? processingControls;
  final int? cameraControls;

  @override
  rust.KernelFunction create() => rust.KernelFunction.video(
    spec: rust.VideoSpec(
      frames: [
        for (final f in frames)
          rust.VideoFrameSpec(
            width: f.width,
            height: f.height,
            format: rust.VideoFormatSpec(
              kind: f.format._kind,
              guid: Uint8List.fromList(f.format.guid),
              name: f.format.name,
              bitsPerPixel: f.format.bitsPerPixel,
            ),
            intervals: Uint32List.fromList(f.intervals),
            colorMatching: switch (f.colorMatching) {
              final c? => rust.ColorMatchingSpec(
                colorPrimaries: c.colorPrimaries,
                transferCharacteristics: c.transferCharacteristics,
                matrixCoefficients: c.matrixCoefficients,
              ),
              null => null,
            },
          ),
      ],
      streamingInterval: streamingInterval,
      streamingMaxBurst: streamingMaxBurst,
      streamingMaxPacket: streamingMaxPacket,
      functionName: functionName,
      processingControls: processingControls,
      cameraControls: cameraControls,
    ),
  );
}

/// Any configfs function driver, configured with raw attribute values.
final class OtherFunction extends KernelFunction {
  OtherFunction(this.driver, {this.properties = const {}});

  /// Driver name, such as `ecm` or `acm`.
  final String driver;

  /// Attribute file name to value.
  final Map<String, List<int>> properties;

  @override
  rust.KernelFunction create() => rust.KernelFunction.other(
    driver: driver,
    properties: [
      for (final MapEntry(:key, :value) in properties.entries)
        rust.PropertySpec(name: key, value: Uint8List.fromList(value)),
    ],
  );

  /// Reads attribute [name]. Available once registered.
  Future<Uint8List> property(String name) => native.property(name);
}
