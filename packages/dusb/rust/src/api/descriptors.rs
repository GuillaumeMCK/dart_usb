//! Parsed descriptors, copied into plain structs.

use flutter_rust_bridge::frb;

use super::types::{Direction, TransferType};

/// The device descriptor.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'DeviceDescriptor(${vendorId.toRadixString(16).padLeft(4, '0')}:${productId.toRadixString(16).padLeft(4, '0')}, '
      'USB ${(usbVersion >> 8).toRadixString(16)}.${(usbVersion & 0xff).toRadixString(16).padLeft(2, '0')}, '
      'class 0x${deviceClass.toRadixString(16)}, $numConfigurations configuration(s))';
"#)]
pub struct DeviceDescriptor {
    pub usb_version: u16,
    pub device_class: u8,
    pub subclass: u8,
    pub protocol: u8,
    pub max_packet_size_0: u8,
    pub vendor_id: u16,
    pub product_id: u16,
    pub device_version: u16,
    pub manufacturer_string_index: Option<u8>,
    pub product_string_index: Option<u8>,
    pub serial_number_string_index: Option<u8>,
    pub num_configurations: u8,
    /// The raw 18-byte descriptor.
    pub raw: Vec<u8>,
}

impl From<nusb::descriptors::DeviceDescriptor> for DeviceDescriptor {
    fn from(d: nusb::descriptors::DeviceDescriptor) -> Self {
        DeviceDescriptor {
            usb_version: d.usb_version(),
            device_class: d.class(),
            subclass: d.subclass(),
            protocol: d.protocol(),
            max_packet_size_0: d.max_packet_size_0(),
            vendor_id: d.vendor_id(),
            product_id: d.product_id(),
            device_version: d.device_version(),
            manufacturer_string_index: d.manufacturer_string_index().map(|i| i.get()),
            product_string_index: d.product_string_index().map(|i| i.get()),
            serial_number_string_index: d.serial_number_string_index().map(|i| i.get()),
            num_configurations: d.num_configurations(),
            raw: d.as_bytes().to_vec(),
        }
    }
}

/// A configuration descriptor with its interfaces and endpoints.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'ConfigurationDescriptor($configurationValue, interfaces: $interfaces)';
"#)]
pub struct ConfigurationDescriptor {
    pub configuration_value: u8,
    pub num_interfaces: u8,
    pub attributes: u8,
    /// `bMaxPower`, in units of 2 mA (USB 2) or 8 mA (USB 3).
    pub max_power: u8,
    pub string_index: Option<u8>,
    /// Interfaces in ascending order, each with its alternate settings.
    pub interfaces: Vec<InterfaceDescriptors>,
    /// The raw descriptors, `wTotalLength` bytes.
    pub raw: Vec<u8>,
}

impl From<nusb::descriptors::ConfigurationDescriptor<'_>> for ConfigurationDescriptor {
    fn from(c: nusb::descriptors::ConfigurationDescriptor<'_>) -> Self {
        ConfigurationDescriptor {
            configuration_value: c.configuration_value(),
            num_interfaces: c.num_interfaces(),
            attributes: c.attributes(),
            max_power: c.max_power(),
            string_index: c.string_index().map(|i| i.get()),
            interfaces: c
                .interfaces()
                .map(|i| InterfaceDescriptors {
                    interface_number: i.interface_number(),
                    alt_settings: i.alt_settings().map(Into::into).collect(),
                })
                .collect(),
            raw: c.as_bytes().to_vec(),
        }
    }
}

/// All alternate settings of one interface.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'Interface($interfaceNumber, altSettings: $altSettings)';
"#)]
pub struct InterfaceDescriptors {
    pub interface_number: u8,
    pub alt_settings: Vec<InterfaceDescriptor>,
}

/// One alternate setting of an interface.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'InterfaceDescriptor($interfaceNumber/$alternateSetting, class 0x${interfaceClass.toRadixString(16)}, endpoints: $endpoints)';
"#)]
pub struct InterfaceDescriptor {
    pub interface_number: u8,
    pub alternate_setting: u8,
    pub num_endpoints: u8,
    pub interface_class: u8,
    pub subclass: u8,
    pub protocol: u8,
    pub string_index: Option<u8>,
    pub endpoints: Vec<EndpointDescriptor>,
    /// The raw interface descriptor and everything up to the next one,
    /// including class-specific descriptors.
    pub raw: Vec<u8>,
}

impl From<nusb::descriptors::InterfaceDescriptor<'_>> for InterfaceDescriptor {
    fn from(i: nusb::descriptors::InterfaceDescriptor<'_>) -> Self {
        InterfaceDescriptor {
            interface_number: i.interface_number(),
            alternate_setting: i.alternate_setting(),
            num_endpoints: i.num_endpoints(),
            interface_class: i.class(),
            subclass: i.subclass(),
            protocol: i.protocol(),
            string_index: i.string_index().map(|i| i.get()),
            endpoints: i.endpoints().map(Into::into).collect(),
            raw: i.as_bytes().to_vec(),
        }
    }
}

/// An endpoint descriptor.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'EndpointDescriptor(0x${address.toRadixString(16).padLeft(2, '0')} ${transferType.name} ${direction.name}, $maxPacketSize bytes)';
"#)]
pub struct EndpointDescriptor {
    pub address: u8,
    pub direction: Direction,
    pub transfer_type: TransferType,
    pub max_packet_size: u32,
    pub packets_per_microframe: u8,
    pub interval: u8,
    /// The raw endpoint descriptor and any class-specific descriptors after it.
    pub raw: Vec<u8>,
}

impl From<nusb::descriptors::EndpointDescriptor<'_>> for EndpointDescriptor {
    fn from(e: nusb::descriptors::EndpointDescriptor<'_>) -> Self {
        EndpointDescriptor {
            address: e.address(),
            direction: e.direction().into(),
            transfer_type: e.transfer_type().into(),
            max_packet_size: e.max_packet_size() as u32,
            packets_per_microframe: e.packets_per_microframe(),
            interval: e.interval(),
            raw: e.as_bytes().to_vec(),
        }
    }
}
