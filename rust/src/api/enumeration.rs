//! Listing devices and buses, and hotplug events.

use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Instant;

use chrono::Duration;
use flutter_rust_bridge::frb;
use futures_lite::Stream;
use nusb::MaybeFuture;

use super::device::Device;
use super::error::UsbException;
use super::types::{std_duration, Speed, UsbControllerType};

/// Opaque system identifier for a connected device. Equal for the same device
/// across listings and hotplug events while it stays connected.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[frb(dart_code = r#"
  @override
  String toString() => 'DeviceId($key)';
"#)]
pub struct DeviceId {
    pub key: String,
}

impl From<nusb::DeviceId> for DeviceId {
    fn from(id: nusb::DeviceId) -> Self {
        DeviceId { key: format!("{id:?}") }
    }
}

/// Summary of an interface, available without opening the device.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'InterfaceInfo($interfaceNumber, class 0x${interfaceClass.toRadixString(16)}'
      '${interfaceString == null ? '' : ', "$interfaceString"'})';
"#)]
pub struct InterfaceInfo {
    pub interface_number: u8,
    pub interface_class: u8,
    pub subclass: u8,
    pub protocol: u8,
    pub interface_string: Option<String>,
}

/// Information about a device that can be obtained without opening it.
#[frb(opaque)]
pub struct DeviceInfo(pub(crate) nusb::DeviceInfo);

impl DeviceInfo {
    #[frb(sync, getter)]
    pub fn id(&self) -> DeviceId {
        self.0.id().into()
    }

    #[frb(sync, getter)]
    pub fn vendor_id(&self) -> u16 {
        self.0.vendor_id()
    }

    #[frb(sync, getter)]
    pub fn product_id(&self) -> u16 {
        self.0.product_id()
    }

    /// `bcdDevice`
    #[frb(sync, getter)]
    pub fn device_version(&self) -> u16 {
        self.0.device_version()
    }

    /// `bcdUSB`
    #[frb(sync, getter)]
    pub fn usb_version(&self) -> u16 {
        self.0.usb_version()
    }

    #[frb(sync, getter)]
    pub fn device_class(&self) -> u8 {
        self.0.class()
    }

    #[frb(sync, getter)]
    pub fn subclass(&self) -> u8 {
        self.0.subclass()
    }

    #[frb(sync, getter)]
    pub fn protocol(&self) -> u8 {
        self.0.protocol()
    }

    #[frb(sync, getter)]
    pub fn speed(&self) -> Option<Speed> {
        self.0.speed().and_then(Speed::from_nusb)
    }

    /// Identifier for the bus the device is connected to.
    #[frb(sync, getter)]
    pub fn bus_id(&self) -> String {
        self.0.bus_id().to_owned()
    }

    #[frb(sync, getter)]
    pub fn device_address(&self) -> u8 {
        self.0.device_address()
    }

    /// Port numbers from the root hub to the device.
    #[frb(sync, getter)]
    pub fn port_chain(&self) -> Vec<u8> {
        self.0.port_chain().to_vec()
    }

    /// The manufacturer string, if the OS cached it.
    #[frb(sync, getter)]
    pub fn manufacturer_string(&self) -> Option<String> {
        self.0.manufacturer_string().map(str::to_owned)
    }

    /// The product string, if the OS cached it.
    #[frb(sync, getter)]
    pub fn product_string(&self) -> Option<String> {
        self.0.product_string().map(str::to_owned)
    }

    /// The serial number, if the OS cached it.
    #[frb(sync, getter)]
    pub fn serial_number(&self) -> Option<String> {
        self.0.serial_number().map(str::to_owned)
    }

    /// The manufacturer string, requesting it from the device if needed.
    pub fn get_manufacturer_string(&self) -> Result<Option<String>, UsbException> {
        Ok(self.0.get_manufacturer_string().wait()?)
    }

    /// The product string, requesting it from the device if needed.
    pub fn get_product_string(&self) -> Result<Option<String>, UsbException> {
        Ok(self.0.get_product_string().wait()?)
    }

    /// The serial number, requesting it from the device if needed.
    pub fn get_serial_number_string(&self) -> Result<Option<String>, UsbException> {
        Ok(self.0.get_serial_number_string().wait()?)
    }

    #[frb(sync, getter)]
    pub fn interfaces(&self) -> Vec<InterfaceInfo> {
        self.0
            .interfaces()
            .map(|i| InterfaceInfo {
                interface_number: i.interface_number(),
                interface_class: i.class(),
                subclass: i.subclass(),
                protocol: i.protocol(),
                interface_string: i.interface_string().map(str::to_owned),
            })
            .collect()
    }

    /// *Linux:* the sysfs path of the device.
    #[frb(sync, getter)]
    pub fn sysfs_path(&self) -> Option<String> {
        #[cfg(target_os = "linux")]
        return Some(self.0.sysfs_path().display().to_string());
        #[cfg(not(target_os = "linux"))]
        None
    }

    /// *Windows:* the device instance ID.
    #[frb(sync, getter)]
    pub fn instance_id(&self) -> Option<String> {
        #[cfg(target_os = "windows")]
        return Some(self.0.instance_id().to_string_lossy().into_owned());
        #[cfg(not(target_os = "windows"))]
        None
    }

    /// *Windows:* the driver bound to the device, such as `WinUSB`.
    #[frb(sync, getter)]
    pub fn driver(&self) -> Option<String> {
        #[cfg(target_os = "windows")]
        return self.0.driver().map(str::to_owned);
        #[cfg(not(target_os = "windows"))]
        None
    }

    /// *macOS:* the IOKit `locationID`.
    #[frb(sync, getter)]
    pub fn location_id(&self) -> Option<u32> {
        #[cfg(target_os = "macos")]
        return Some(self.0.location_id());
        #[cfg(not(target_os = "macos"))]
        None
    }

    /// Whether the device matches [selector].
    #[frb(sync, positional)]
    pub fn matches(&self, selector: &DeviceSelector) -> bool {
        self.0.matches(&selector.to_nusb())
    }

    /// Opens the device.
    pub fn open(&self) -> Result<Device, UsbException> {
        Ok(Device(self.0.open().wait()?))
    }

    /// A multi-line description of every field, for debugging.
    #[frb(sync)]
    pub fn describe(&self) -> String {
        format!("{:#?}", self.0)
    }

    /// A one-line summary, such as
    /// `DeviceInfo(0bda:8153 "USB LAN" by "Realtek", bus 00, address 1)`.
    #[frb(sync)]
    #[allow(clippy::inherent_to_string)]
    pub fn to_string(&self) -> String {
        let d = &self.0;
        let mut s = format!("DeviceInfo({:04x}:{:04x}", d.vendor_id(), d.product_id());
        if let Some(p) = d.product_string() {
            s += &format!(" {p:?}");
        }
        if let Some(m) = d.manufacturer_string() {
            s += &format!(" by {m:?}");
        }
        s + &format!(", bus {}, address {})", d.bus_id(), d.device_address())
    }
}

/// Information about a system USB bus.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'BusInfo($busId${systemName == null ? '' : ' "$systemName"'}'
      '${controllerType == null ? '' : ', ${controllerType!.name}'})';
"#)]
pub struct BusInfo {
    pub bus_id: String,
    pub driver: Option<String>,
    pub controller_type: Option<UsbControllerType>,
    pub system_name: Option<String>,
}

/// Criteria for selecting a device; `null` fields match anything. As in
/// nusb, `subclass` needs `deviceClass` and `protocol` needs `subclass`.
#[derive(Debug, Clone)]
pub struct DeviceSelector {
    pub vendor_id: Option<u16>,
    pub product_id: Option<u16>,
    pub device_class: Option<u8>,
    pub subclass: Option<u8>,
    pub protocol: Option<u8>,
    pub serial_number: Option<String>,
}

impl DeviceSelector {
    fn to_nusb(&self) -> nusb::DeviceSelector {
        let mut s = nusb::DeviceSelector::all();
        s = match (self.vendor_id, self.product_id) {
            (Some(v), Some(p)) => s.with_vid_pid(v, p),
            (Some(v), None) => s.with_vid(v),
            _ => s,
        };
        s = match (self.device_class, self.subclass, self.protocol) {
            (Some(c), Some(sc), Some(p)) => s.with_class_subclass_protocol(c, sc, p),
            (Some(c), Some(sc), None) => s.with_class_subclass(c, sc),
            (Some(c), _, _) => s.with_class(c),
            _ => s,
        };
        match &self.serial_number {
            Some(serial) => s.with_serial_number(serial.clone()),
            None => s,
        }
    }
}

/// Lists the connected USB devices.
pub fn list_devices() -> Result<Vec<DeviceInfo>, UsbException> {
    Ok(nusb::list_devices().wait()?.map(DeviceInfo).collect())
}

/// Lists the system USB buses.
pub fn list_buses() -> Result<Vec<BusInfo>, UsbException> {
    Ok(nusb::list_buses()
        .wait()?
        .map(|b| BusInfo {
            bus_id: b.bus_id().to_owned(),
            driver: b.driver().map(str::to_owned),
            controller_type: b.controller_type().and_then(UsbControllerType::from_nusb),
            system_name: b.system_name().map(str::to_owned),
        })
        .collect())
}

/// Finds a device matching any of [selectors], or `null`.
#[frb(positional)]
pub fn request_device(selectors: Vec<DeviceSelector>) -> Result<Option<DeviceInfo>, UsbException> {
    let selectors: Vec<_> = selectors.iter().map(DeviceSelector::to_nusb).collect();
    Ok(nusb::request_device(&selectors).wait()?.map(DeviceInfo))
}

/// A device was connected or disconnected.
#[frb(non_opaque)]
pub enum HotplugEvent {
    /// A device was connected.
    Connected { device: DeviceInfo },
    /// A device was disconnected. Its [id] matches the [DeviceInfo.id] it had
    /// while connected.
    Disconnected { id: DeviceId },
}

/// Receives connect and disconnect events, starting when it is opened.
///
/// Use `watchDevices()`, which wraps this in a Dart stream.
#[frb(opaque)]
pub struct HotplugWatch(nusb::hotplug::HotplugWatch);

struct ThreadWaker(std::thread::Thread);

impl std::task::Wake for ThreadWaker {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }
}

impl HotplugWatch {
    /// Waits up to [timeout] for the next event; returns `null` on timeout.
    pub fn next_event(&mut self, timeout: Duration) -> Option<HotplugEvent> {
        let deadline = Instant::now() + std_duration(timeout);
        let waker = Waker::from(Arc::new(ThreadWaker(std::thread::current())));
        let mut cx = Context::from_waker(&waker);
        loop {
            if let Poll::Ready(event) = Pin::new(&mut self.0).poll_next(&mut cx) {
                return event.map(convert_event);
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            std::thread::park_timeout(deadline - now);
        }
    }
}

fn convert_event(event: nusb::hotplug::HotplugEvent) -> HotplugEvent {
    match event {
        nusb::hotplug::HotplugEvent::Connected(d) => HotplugEvent::Connected { device: DeviceInfo(d) },
        nusb::hotplug::HotplugEvent::Disconnected(id) => HotplugEvent::Disconnected { id: id.into() },
    }
}

/// Starts watching for hotplug events. Prefer `watchDevices()`.
pub fn open_hotplug_watch() -> Result<HotplugWatch, UsbException> {
    Ok(HotplugWatch(nusb::watch_devices()?))
}
