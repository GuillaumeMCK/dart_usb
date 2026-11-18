import 'dart:async';

import 'package:usb_host/usb_host.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  final usb = await Usb.initialize();
  runApp(UsbHostExampleApp(usb: usb));
}

class UsbHostExampleApp extends StatelessWidget {
  const UsbHostExampleApp({super.key, required this.usb});

  final Usb usb;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'usb_host',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    home: DeviceListPage(usb: usb),
  );
}

/// Lists connected USB devices and keeps the list current with hotplug
/// events.
class DeviceListPage extends StatefulWidget {
  const DeviceListPage({super.key, required this.usb});

  final Usb usb;

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  final _devices = <DeviceId, DeviceInfo>{};
  StreamSubscription<HotplugEvent>? _events;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Listen before listing, so a device connected in between isn't missed.
    _events = widget.usb.watchDevices().listen(
      (event) => setState(() {
        switch (event) {
          case HotplugConnected(:final device):
            _devices[device.id] = device;
          case HotplugDisconnected(:final id):
            _devices.remove(id);
        }
      }),
      onError: (Object e) => setState(() => _error = e),
    );
    try {
      final devices = await widget.usb.listDevices();
      setState(() => _devices.addAll({for (final d in devices) d.id: d}));
    } on UsbException catch (e) {
      setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('USB devices')),
    body: switch (_error) {
      final error? => Center(child: Text('$error')),
      null => ListView(
        children: [
          for (final DeviceInfo(
                :vendorId,
                :productId,
                :productString,
                :manufacturerString,
                :busId,
                :deviceAddress,
                :speed,
              )
              in _devices.values)
            ListTile(
              leading: const Icon(Icons.usb),
              title: Text(productString ?? 'Unknown device'),
              subtitle: Text(
                [
                  '${_hex(vendorId)}:${_hex(productId)}',
                  ?manufacturerString,
                  'bus $busId address $deviceAddress',
                  ?speed?.name,
                ].join(' · '),
              ),
            ),
        ],
      ),
    },
  );
}

String _hex(int value) => value.toRadixString(16).padLeft(4, '0');
