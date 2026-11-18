import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:usb_host/usb_host.dart';

void main() => runApp(const UsbHostExampleApp());

/// The example app.
class const UsbHostExampleApp({super.key}) extends StatelessWidget {
  /// The example app, listing connected USB devices.
  this;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'usb_host',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    home: const DeviceListPage(),
  );
}

/// Lists connected USB devices and keeps the list current with hotplug
/// events.
class const DeviceListPage({super.key}) extends StatefulWidget {
  /// The device list.
  this;

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState() extends State<DeviceListPage> {
  final _devices = <DeviceId, DeviceInfo>{};
  StreamSubscription<HotplugEvent>? _events;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final Usb usb;
    try {
      usb = await Usb.initialize();
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    if (!mounted) return;
    // The stream lists the devices already connected once it is watching,
    // so none is missed and events arrive in order.
    _events = usb
        .watchDevices(includeConnected: true)
        .listen(
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
  }

  Future<void> _retry() async {
    await _events?.cancel();
    _events = null;
    setState(() {
      _error = null;
      _devices.clear();
    });
    await _start();
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('USB devices')),
    body: switch (_error) {
      final error? => Center(
        child: Column(
          mainAxisSize: .min,
          spacing: 16,
          children: [
            Text('$error', textAlign: .center),
            FilledButton(onPressed: _retry, child: const Text('Retry')),
          ],
        ),
      ),
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
