import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:usb_gadget/src/rust/api.dart' show ClassCodes;
import 'package:usb_gadget/src/rust/api/function.dart' as rust;
import 'package:usb_gadget/src/rust/api/gadget.dart' show FunctionHandle;
import 'package:usb_models/usb_models.dart';

/// A USB function: one or more interfaces of a gadget, implemented by a
/// kernel driver ([KernelFunction]) or by Dart (`CustomFunction`).
///
/// A function only does something once its gadget is registered.
abstract class GadgetFunction() {
  /// Creates a function; see the subclasses.
  this;

  /// The function's configfs directory, once registered.
  String? get path;

  /// Creates the native function on first use and returns a handle for one
  /// configuration.
  @internal
  FunctionHandle createHandle();

  /// Called once the gadget holding this function is removed, to release
  /// what the registration opened.
  @internal
  @mustCallSuper
  void didRemove() {}
}

/// The bridge representation of [c]. Internal to usb_gadget.
ClassCodes classCodes(Class c) =>
    ClassCodes(class_: c.code, subClass: c.subClass, protocol: c.protocol);

/// A function implemented by a Linux kernel driver: configured here, then
/// used through the device file or network interface the kernel creates.
abstract class KernelFunction() extends GadgetFunction {
  /// Creates a kernel function; see the subclasses.
  this;

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

  /// Registration state.
  rust.FunctionState get state => _native?.state ?? .unregistered;

  @override
  String? get path => _native?.path;
}

/// A human interface device implemented by the kernel (`hid`): the gadget
/// sends input reports written to [devicePath] and delivers output reports
/// for reading from it.
///
/// Requires `CONFIG_USB_CONFIGFS_F_HID`.
class HidFunction({
  required this.reportDescriptor,
  required this.reportLength,
  this.subClass = 0,
  this.protocol = 0,
  this.noOutEndpoint = false,
}) extends KernelFunction {
  /// A HID function with [reportDescriptor], whose longest report is
  /// [reportLength] bytes.
  this;

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

  RandomAccessFile? _file;

  /// The device file, opened on first use: write input reports to it, read
  /// output reports from it. Available once registered.
  RandomAccessFile get file =>
      _file ??= File(devicePath).openSync(mode: .append);

  /// Sends one input report.
  void sendReport(List<int> report) => file.writeFromSync(report);

  @override
  @internal
  FunctionHandle createHandle() {
    // A new registration has a new device file.
    _closeFile();
    return super.createHandle();
  }

  @override
  @internal
  void didRemove() {
    super.didRemove();
    _closeFile();
  }

  void _closeFile() {
    _file?.closeSync();
    _file = null;
  }
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

  /// Backing file or block device; `null` for an empty unit.
  final String? file;

  /// Rejects writes from the host.
  final bool readOnly;

  /// Emulates a CD-ROM; implies [readOnly].
  final bool cdrom;

  /// Ignores the FUA (force unit access) flag of SCSI writes.
  final bool noFua;

  /// Reports the medium as removable, so it can be ejected and
  /// replaced.
  final bool removable;

  /// SCSI inquiry string; empty for the kernel's default.
  final String inquiryString;
}

/// A USB mass storage device (`mass_storage`).
///
/// Requires `CONFIG_USB_CONFIGFS_MASS_STORAGE`.
class MassStorageFunction(this.luns, {this.stall}) extends KernelFunction {
  /// A mass storage function with one logical unit per entry of [luns].
  this;

  /// The logical units, numbered from 0.
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
enum NetClass() {
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
class NetFunction(
  this.netClass, {
  this._deviceAddress,
  this._hostAddress,
  this.qmult,
  this.interfaceClass,
}) extends KernelFunction {
  /// A network function of [netClass]. [deviceAddress] and [hostAddress]
  /// fix the MAC addresses of the two ends (6 bytes each); by default the
  /// kernel picks them.
  this;

  /// The Ethernet over USB flavour.
  final NetClass netClass;

  final List<int>? _deviceAddress;
  final List<int>? _hostAddress;

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
      deviceAddress: switch (_deviceAddress) {
        final a? => Uint8List.fromList(a),
        null => null,
      },
      hostAddress: switch (_hostAddress) {
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
class SerialFunction({this.acm = true, this.console}) extends KernelFunction {
  /// A serial function: CDC ACM if [acm], else the generic serial driver.
  this;

  /// Whether this is a CDC ACM port rather than generic serial.
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
class MidiFunction({
  this.bufferLength,
  this.id,
  this.inPorts,
  this.outPorts,
  this.index,
  this.queueLength,
  this.interfaceString,
}) extends KernelFunction {
  /// A MIDI function; `null` settings keep the kernel defaults.
  this;

  /// Size of the MIDI buffer, in bytes.
  final int? bufferLength;

  /// ID string of the sound card.
  final String? id;

  /// Number of MIDI input ports.
  final int? inPorts;

  /// Number of MIDI output ports.
  final int? outPorts;

  /// Sound card index; `null` picks one.
  final int? index;

  /// Number of USB read requests queued.
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
class PrinterFunction({this.pnpString, this.queueLength})
    extends KernelFunction {
  /// A printer function; `null` settings keep the kernel defaults.
  this;

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
class LoopbackFunction({this.queueLength, this.bulkBufferLength})
    extends KernelFunction {
  /// A loopback function; `null` settings keep the kernel defaults.
  this;

  /// Number of requests allocated per endpoint.
  final int? queueLength;

  /// Size of each bulk transfer buffer, in bytes.
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
class SourceSinkFunction({
  this.pattern,
  this.isocInterval,
  this.isocMaxPacket,
  this.isocMult,
  this.isocMaxBurst,
  this.bulkBufferLength,
  this.bulkQueueLength,
  this.isocQueueLength,
}) extends KernelFunction {
  /// A source/sink function; `null` settings keep the kernel defaults.
  this;

  /// 0 zeros, 1 bytes mod 63, 2 no checking.
  final int? pattern;

  /// Isochronous polling interval (1 to 16).
  final int? isocInterval;

  /// Max packet size of the isochronous endpoints.
  final int? isocMaxPacket;

  /// Isochronous transactions per microframe minus one (0 to 2).
  final int? isocMult;

  /// SuperSpeed isochronous burst (0 to 15).
  final int? isocMaxBurst;

  /// Size of each bulk transfer buffer, in bytes.
  final int? bulkBufferLength;

  /// Number of bulk transfer buffers.
  final int? bulkQueueLength;

  /// Number of isochronous transfer buffers.
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
final class const AudioStream({
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
}) {
  /// Stream settings; `null` keeps the kernel default for each.
  this;

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

  /// Whether a mute control is present.
  final bool? mutePresent;

  /// UAC2.
  final int? terminalType;

  /// Whether a volume control is present.
  final bool? volumePresent;

  /// Minimum volume, in 1/256 dB.
  final int? volumeMin;

  /// Maximum volume, in 1/256 dB.
  final int? volumeMax;

  /// Volume step, in 1/256 dB.
  final int? volumeResolution;

  /// Name of the volume control.
  final String? volumeName;

  /// Name of the input terminal.
  final String? inputTerminalName;

  /// Name of the input terminal channel.
  final String? inputTerminalChannelName;

  /// Name of the output terminal.
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
class AudioFunction extends KernelFunction {
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

  /// Audio the gadget sends to the host.
  final AudioStream capture;

  /// Audio the gadget receives from the host.
  final AudioStream playback;

  /// Number of requests queued per stream.
  final int? requestNumber;

  /// Name of the audio function.
  final String? functionName;

  /// UAC2: maximum feedback deviation, in parts per million.
  final int? fbMax;

  /// UAC2: name of the AudioControl interface.
  final String? controlName;

  /// UAC2: name of the input clock source.
  final String? clockSourceInName;

  /// UAC2: name of the output clock source.
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
final class const VideoFormat._(
  this._kind, [
  this.guid = const [],
  this.name = '',
  this.bitsPerPixel = 0,
]) {
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

  /// Framebased formats: the 16-byte GUID; empty otherwise.
  final List<int> guid;

  /// Framebased formats: the configfs directory name; empty otherwise.
  final String name;

  /// Framebased formats: bits per pixel, 0 for compressed formats.
  final int bitsPerPixel;
}

/// Color matching descriptor values.
final class const ColorMatching(
  this.colorPrimaries,
  this.transferCharacteristics,
  this.matrixCoefficients,
) {
  /// Color matching with the given descriptor codes.
  this;

  /// `bColorPrimaries`.
  final int colorPrimaries;

  /// `bTransferCharacteristics`.
  final int transferCharacteristics;

  /// `bMatrixCoefficients`.
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
  }) : intervals = [for (final f in fps) 10_000_000 ~/ f];

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Pixel format.
  final VideoFormat format;

  /// Frame intervals, in 100 ns units.
  final List<int> intervals;

  /// Color matching; `null` for the kernel default.
  final ColorMatching? colorMatching;
}

/// A USB video class camera (`uvc`); frames are written to the V4L2 output
/// device the kernel creates.
///
/// Requires `CONFIG_USB_CONFIGFS_F_UVC`.
class VideoFunction(
  this.frames, {
  this.streamingInterval,
  this.streamingMaxBurst,
  this.streamingMaxPacket,
  this.functionName,
  this.processingControls,
  this.cameraControls,
}) extends KernelFunction {
  /// A camera offering [frames]; `null` settings keep the kernel defaults.
  this;

  /// Frame sizes, formats and rates offered to the host.
  final List<VideoFrame> frames;

  /// Polling interval of the streaming endpoint.
  final int? streamingInterval;

  /// SuperSpeed burst of the streaming endpoint (1 to 15).
  final int? streamingMaxBurst;

  /// 1024, 2048 or 3072.
  final int? streamingMaxPacket;

  /// Name of the video interface.
  final String? functionName;

  /// Processing Unit `bmControls`.
  final int? processingControls;

  /// Camera Terminal `bmControls`.
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
class OtherFunction(this.driver, {this.properties = const {}})
    extends KernelFunction {
  /// A function of kernel [driver] with raw configfs [properties].
  this;

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
