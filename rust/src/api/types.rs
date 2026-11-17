//! Plain enums and structs mirrored from nusb.

use flutter_rust_bridge::frb;

/// Converts a Dart `Duration` (bridged as `chrono::Duration`) to the std
/// duration nusb takes. Negative durations become zero.
pub(crate) fn std_duration(d: chrono::Duration) -> std::time::Duration {
    d.to_std().unwrap_or_default()
}

/// Timeout for control and descriptor requests when none is given.
pub(crate) fn timeout_or_default(timeout: Option<chrono::Duration>) -> std::time::Duration {
    timeout.map_or(std::time::Duration::from_secs(1), std_duration)
}

/// US English, the language almost every device's strings use.
pub(crate) const US_ENGLISH: u16 = 0x0409;

/// USB connection speed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Speed {
    /// 1.5 Mbit/s
    Low,
    /// 12 Mbit/s
    Full,
    /// 480 Mbit/s
    High,
    /// 5000 Mbit/s
    SuperSpeed,
    /// 10000 Mbit/s
    SuperSpeedPlus,
}

impl Speed {
    pub(crate) fn from_nusb(s: nusb::Speed) -> Option<Speed> {
        Some(match s {
            nusb::Speed::Low => Speed::Low,
            nusb::Speed::Full => Speed::Full,
            nusb::Speed::High => Speed::High,
            nusb::Speed::Super => Speed::SuperSpeed,
            nusb::Speed::SuperPlus => Speed::SuperSpeedPlus,
            _ => return None,
        })
    }
}

/// USB host controller type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsbControllerType {
    Xhci,
    Ehci,
    Ohci,
    Uhci,
    Vhci,
}

impl UsbControllerType {
    pub(crate) fn from_nusb(t: nusb::UsbControllerType) -> Option<Self> {
        Some(match t {
            nusb::UsbControllerType::XHCI => Self::Xhci,
            nusb::UsbControllerType::EHCI => Self::Ehci,
            nusb::UsbControllerType::OHCI => Self::Ohci,
            nusb::UsbControllerType::UHCI => Self::Uhci,
            nusb::UsbControllerType::VHCI => Self::Vhci,
            _ => return None,
        })
    }
}

/// Transfer direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Host to device.
    Out,
    /// Device to host.
    In,
}

impl From<nusb::transfer::Direction> for Direction {
    fn from(d: nusb::transfer::Direction) -> Self {
        match d {
            nusb::transfer::Direction::Out => Direction::Out,
            nusb::transfer::Direction::In => Direction::In,
        }
    }
}

/// Endpoint transfer type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferType {
    Control,
    Isochronous,
    Bulk,
    Interrupt,
}

impl From<nusb::descriptors::TransferType> for TransferType {
    fn from(t: nusb::descriptors::TransferType) -> Self {
        match t {
            nusb::descriptors::TransferType::Control => TransferType::Control,
            nusb::descriptors::TransferType::Isochronous => TransferType::Isochronous,
            nusb::descriptors::TransferType::Bulk => TransferType::Bulk,
            nusb::descriptors::TransferType::Interrupt => TransferType::Interrupt,
        }
    }
}

/// Specification defining a control request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlType {
    Standard,
    Class,
    Vendor,
}

impl From<ControlType> for nusb::transfer::ControlType {
    fn from(t: ControlType) -> Self {
        match t {
            ControlType::Standard => Self::Standard,
            ControlType::Class => Self::Class,
            ControlType::Vendor => Self::Vendor,
        }
    }
}

/// Entity targeted by a control request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Recipient {
    Device,
    Interface,
    Endpoint,
    Other,
}

impl From<Recipient> for nusb::transfer::Recipient {
    fn from(r: Recipient) -> Self {
        match r {
            Recipient::Device => Self::Device,
            Recipient::Interface => Self::Interface,
            Recipient::Endpoint => Self::Endpoint,
            Recipient::Other => Self::Other,
        }
    }
}

/// SETUP packet for an **IN** (device-to-host) control transfer.
#[derive(Debug, Clone)]
#[frb]
pub struct ControlIn {
    pub control_type: ControlType,
    pub recipient: Recipient,
    /// `bRequest`
    pub request: u8,
    /// `wValue`
    #[frb(default = 0)]
    pub value: u16,
    /// `wIndex`: the interface or endpoint number for those recipients.
    #[frb(default = 0)]
    pub index: u16,
    /// `wLength`: number of bytes to read.
    pub length: u16,
}

impl From<&ControlIn> for nusb::transfer::ControlIn {
    fn from(c: &ControlIn) -> Self {
        nusb::transfer::ControlIn {
            control_type: c.control_type.into(),
            recipient: c.recipient.into(),
            request: c.request,
            value: c.value,
            index: c.index,
            length: c.length,
        }
    }
}

/// SETUP packet and data for an **OUT** (host-to-device) control transfer.
#[derive(Debug, Clone)]
#[frb]
pub struct ControlOut {
    pub control_type: ControlType,
    pub recipient: Recipient,
    /// `bRequest`
    pub request: u8,
    /// `wValue`
    #[frb(default = 0)]
    pub value: u16,
    /// `wIndex`: the interface or endpoint number for those recipients.
    #[frb(default = 0)]
    pub index: u16,
    /// Data sent in the data stage, such as `Uint8List.fromList([1, 2, 3])`.
    pub data: Vec<u8>,
}

impl ControlOut {
    pub(crate) fn as_nusb(&self) -> nusb::transfer::ControlOut<'_> {
        nusb::transfer::ControlOut {
            control_type: self.control_type.into(),
            recipient: self.recipient.into(),
            request: self.request,
            value: self.value,
            index: self.index,
            data: &self.data,
        }
    }
}
