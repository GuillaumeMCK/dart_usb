import 'package:usb_gadget/src/function.dart';
import 'package:usb_gadget/src/loader.dart';
import 'package:usb_gadget/src/rust/api.dart' show LocalizedString;
import 'package:usb_gadget/src/rust/api/gadget.dart' as rust;
import 'package:usb_gadget/src/rust/api/udc.dart' show Udc;
import 'package:usb_models/usb_models.dart';

/// Device strings in one language.
final class const GadgetStrings({
  this.manufacturer = '',
  this.product = '',
  this.serialNumber = '',
}) {
  /// Strings for one language.
  this;

  /// Manufacturer name.
  final String manufacturer;

  /// Product name.
  final String product;

  /// Should be unique per device; required by some classes, such as mass
  /// storage.
  final String serialNumber;
}

/// A configuration: the set of functions a host enables together. Most
/// gadgets have one.
final class Config({
  this.description = '',
  this.functions = const [],
  this.maxPower = const MaxPower(500),
  this.selfPowered = false,
  this.remoteWakeup = false,
  Map<LanguageId, String> descriptions = const {},
}) {
  /// A configuration with [functions].
  this : descriptions = {.enUS: description, ...descriptions};

  /// Description in US English; see [descriptions] for other languages.
  final String description;

  /// Description per language.
  final Map<LanguageId, String> descriptions;

  /// The functions, in order.
  final List<GadgetFunction> functions;

  /// Maximum current drawn from the bus.
  final MaxPower maxPower;

  /// Whether the device has its own power source.
  final bool selfPowered;

  /// Whether the device can wake a suspended host.
  final bool remoteWakeup;
}

/// Microsoft OS descriptor, which lets Windows load drivers such as WinUSB
/// without an INF file.
final class const OsDescriptor({
  this.vendorCode = 0xf0,
  this.qwSign = 'MSFT100',
  this.config = 0,
}) {
  /// A Microsoft OS descriptor; the defaults are Microsoft's.
  this;

  /// Vendor request code Windows uses to fetch the descriptors.
  final int vendorCode;

  /// Signature; `MSFT100` for Microsoft.
  final String qwSign;

  /// Index of the configuration Windows uses.
  final int config;
}

/// WebUSB platform capability: lets browsers find the device and suggest
/// [landingPage].
final class const WebUsb({
  required this.vendorCode,
  required this.landingPage,
  this.version = 0x0100,
}) {
  /// The WebUSB capability pointing browsers at [landingPage].
  this;

  /// Vendor request code browsers use to fetch the landing page.
  final int vendorCode;

  /// URL browsers suggest when the device is plugged in.
  final String landingPage;

  /// `bcdVersion`; 0x0100 for WebUSB 1.0.
  final int version;
}

/// A USB gadget: the device a host sees once the gadget is registered and
/// bound to a USB device controller.
///
/// ```dart
/// final gadget = Gadget(
///   id: const Id(vendor: 0x1234, product: 0x5678),
///   strings: {.enUS: const GadgetStrings(manufacturer: 'ACME', product: 'Widget')},
///   configs: [Config(functions: [SerialFunction()])],
/// );
/// final registered = await gadget.bind(await defaultUdc());
/// ```
final class Gadget({
  required this.id,
  this.class_ = const Class.interfaceSpecific(),
  this.strings = const {},
  this.configs = const [],
  this.name,
  this.deviceRelease = 0,
  this.usbVersion = .v20,
  this.maxPacketSize0 = 64,
  this.maxSpeed,
  this.osDescriptor,
  this.webUsb,
  this.keepOnError = false,
}) {
  /// A gadget with vendor and product [id].
  this;

  /// Vendor and product IDs.
  final Id id;

  /// Device class; [Class.interfaceSpecific] lets each interface declare its
  /// own, as composite devices do.
  final Class class_;

  /// Device strings per language.
  final Map<LanguageId, GadgetStrings> strings;

  /// The configurations; most gadgets have one.
  final List<Config> configs;

  /// Name of the configfs directory; `null` picks a free one.
  final String? name;

  /// `bcdDevice`, such as 0x0100 for 1.0.
  final int deviceRelease;

  /// `bcdUSB`: the USB version the device reports.
  final UsbVersion usbVersion;

  /// `bMaxPacketSize0`: max packet size of the control endpoint.
  final int maxPacketSize0;

  /// Caps the speed below the controller's maximum.
  final Speed? maxSpeed;

  /// Microsoft OS descriptor, for driverless WinUSB on Windows.
  final OsDescriptor? osDescriptor;

  /// WebUSB capability.
  final WebUsb? webUsb;

  /// Keeps a partially created gadget in configfs when registration fails,
  /// for debugging.
  final bool keepOnError;

  /// Creates the gadget in configfs without binding it to a controller.
  /// Needs root (or `CAP_SYS_ADMIN`) and configfs mounted.
  Future<RegisteredGadget> register() async {
    await ensureInitialized();
    return RegisteredGadget._(await rust.registerGadget(spec: _spec()), this);
  }

  /// Registers the gadget and binds it to [udc]; the host then sees the
  /// device.
  Future<RegisteredGadget> bind(Udc udc) async {
    final registered = await register();
    try {
      await registered.bind(udc);
    } catch (_) {
      await registered.remove();
      rethrow;
    }
    return registered;
  }

  rust.GadgetSpec _spec() => rust.GadgetSpec(
    name: name,
    class_: classCodes(class_),
    vendor: id.vendor,
    product: id.product,
    strings: [
      for (final MapEntry(key: language, value: s) in strings.entries)
        rust.GadgetStringsSpec(
          language: language.value,
          manufacturer: s.manufacturer,
          product: s.product,
          serialNumber: s.serialNumber,
        ),
    ],
    maxPacketSize0: maxPacketSize0,
    deviceRelease: deviceRelease,
    usbVersion: usbVersion.value,
    maxSpeed: switch (maxSpeed) {
      .lowSpeed => 1,
      .fullSpeed => 2,
      .highSpeed => 3,
      .superSpeed => 4,
      .superSpeedPlus => 5,
      _ => null,
    },
    osDescriptor: switch (osDescriptor) {
      final o? => rust.OsDescriptorSpec(
        vendorCode: o.vendorCode,
        qwSign: o.qwSign,
        config: o.config,
      ),
      null => null,
    },
    webUsb: switch (webUsb) {
      final w? => rust.WebUsbSpec(
        version: w.version,
        vendorCode: w.vendorCode,
        landingPage: w.landingPage,
      ),
      null => null,
    },
    configs: [
      for (final c in configs)
        rust.ConfigSpec(
          description: [
            for (final MapEntry(key: language, value: text)
                in c.descriptions.entries)
              if (text.isNotEmpty)
                LocalizedString(language: language.value, text: text),
          ],
          maxPower: c.maxPower.milliAmps,
          selfPowered: c.selfPowered,
          remoteWakeup: c.remoteWakeup,
          functions: [for (final f in c.functions) f.createHandle()],
        ),
    ],
    keepOnError: keepOnError,
  );
}

/// A gadget created in configfs.
///
/// It stays registered until [remove], and this object (with the gadget's
/// functions) stays reachable until then: disposing it would remove the
/// gadget.
final class RegisteredGadget._(this._native, this.gadget) {
  /// A registration of [gadget], tracked until removed or detached.
  this {
    _registered.add(this);
  }

  static final _registered = <RegisteredGadget>{};

  final rust.RegisteredGadget _native;

  /// The definition this was registered from; `null` for gadgets found
  /// with [all].
  final Gadget? gadget;

  /// Name of the configfs directory.
  String get name => _native.name();

  /// The configfs directory.
  String get path => _native.path();

  /// Name of the controller the gadget is bound to, if any.
  String? get udc => _native.udc();

  /// The gadget's functions, as configfs lists them.
  List<rust.RegisteredFunction> get functions => _native.functions();

  /// Binds the gadget to [udc]; the host sees the device plugged in.
  Future<void> bind(Udc udc) => _native.bind(udc);

  /// Unbinds the gadget; the host sees the device unplugged.
  Future<void> unbind() => _native.unbind();

  /// Leaves the gadget registered when this process exits.
  void detach() {
    _native.detach();
    _registered.remove(this);
  }

  /// Unbinds the gadget and removes it from configfs.
  Future<void> remove() async {
    await _native.remove();
    _registered.remove(this);
  }

  /// Every gadget in configfs, including other programs'.
  static Future<List<RegisteredGadget>> all() async {
    await ensureInitialized();
    return [
      for (final native in rust.registeredGadgets())
        RegisteredGadget._(native, null)..detach(),
    ];
  }

  /// Removes every gadget in configfs.
  static Future<void> removeAll() async {
    await ensureInitialized();
    await rust.removeAllGadgets();
  }

  /// Unbinds every gadget in configfs.
  static Future<void> unbindAll() async {
    await ensureInitialized();
    await rust.unbindAllGadgets();
  }

  @override
  String toString() => 'RegisteredGadget($path, udc: $udc)';
}
