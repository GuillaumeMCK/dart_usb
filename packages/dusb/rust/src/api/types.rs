//! Plain enums and structs mirrored from nusb.


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

/// Speed as a small code mirrored by `Speed` in package:usb_models
/// (1 low, 2 full, 3 high, 4 super, 5 super+).
pub(crate) fn speed_code(speed: nusb::Speed) -> Option<u8> {
    Some(match speed {
        nusb::Speed::Low => 1,
        nusb::Speed::Full => 2,
        nusb::Speed::High => 3,
        nusb::Speed::Super => 4,
        nusb::Speed::SuperPlus => 5,
        _ => return None,
    })
}

/// Decodes the type and recipient of a `bmRequestType` byte.
pub(crate) fn control_kind(
    request_type: u8,
) -> Result<(nusb::transfer::ControlType, nusb::transfer::Recipient), super::error::UsbException> {
    use super::error::{UsbErrorKind, UsbException};
    let control_type = match (request_type >> 5) & 0x03 {
        0 => nusb::transfer::ControlType::Standard,
        1 => nusb::transfer::ControlType::Class,
        2 => nusb::transfer::ControlType::Vendor,
        _ => return Err(UsbException::new(UsbErrorKind::TransferInvalidArgument, "reserved request type")),
    };
    let recipient = match request_type & 0x1f {
        0 => nusb::transfer::Recipient::Device,
        1 => nusb::transfer::Recipient::Interface,
        2 => nusb::transfer::Recipient::Endpoint,
        3 => nusb::transfer::Recipient::Other,
        _ => return Err(UsbException::new(UsbErrorKind::TransferInvalidArgument, "reserved recipient")),
    };
    Ok((control_type, recipient))
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
