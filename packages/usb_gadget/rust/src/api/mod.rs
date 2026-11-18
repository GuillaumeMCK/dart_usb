//! The API exposed to Dart: thin wrappers over the `usb-gadget` crate. Gadget
//! and function settings cross as plain structs; registered gadgets,
//! functions and endpoints are opaque Dart objects. The Dart library wraps
//! these in its own classes built on package:usb_models.

pub mod custom;
pub mod endpoint;
pub mod error;
pub mod function;
pub mod gadget;
pub mod udc;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Converts a Dart `Duration` (bridged as `chrono::Duration`) to a std
/// duration. Negative durations become zero.
pub(crate) fn std_duration(d: chrono::Duration) -> std::time::Duration {
    d.to_std().unwrap_or_default()
}

/// Speed as a small code mirrored by `Speed` in package:usb_models
/// (0 unknown, 1 low, 2 full, 3 high, 4 super, 5 super+).
pub(crate) fn speed_code(speed: usb_gadget::Speed) -> u8 {
    match speed {
        usb_gadget::Speed::LowSpeed => 1,
        usb_gadget::Speed::FullSpeed => 2,
        usb_gadget::Speed::HighSpeed => 3,
        usb_gadget::Speed::SuperSpeed => 4,
        usb_gadget::Speed::SuperSpeedPlus => 5,
        _ => 0,
    }
}

pub(crate) fn speed_from_code(code: u8) -> usb_gadget::Speed {
    match code {
        1 => usb_gadget::Speed::LowSpeed,
        2 => usb_gadget::Speed::FullSpeed,
        3 => usb_gadget::Speed::HighSpeed,
        4 => usb_gadget::Speed::SuperSpeed,
        5 => usb_gadget::Speed::SuperSpeedPlus,
        _ => usb_gadget::Speed::Unknown,
    }
}

/// A string in one language, for string descriptors.
#[derive(Debug, Clone)]
pub struct LocalizedString {
    /// USB language ID, such as 0x0409 for US English.
    pub language: u16,
    pub text: String,
}

pub(crate) fn localized(
    strings: Vec<LocalizedString>,
) -> std::collections::HashMap<usb_gadget::Language, String> {
    strings.into_iter().map(|s| (usb_gadget::Language::Other(s.language), s.text)).collect()
}

/// Class, subclass and protocol codes.
#[derive(Debug, Clone, Copy)]
pub struct ClassCodes {
    pub class: u8,
    pub sub_class: u8,
    pub protocol: u8,
}

impl From<ClassCodes> for usb_gadget::Class {
    fn from(c: ClassCodes) -> Self {
        usb_gadget::Class::new(c.class, c.sub_class, c.protocol)
    }
}

pub(crate) fn path_string(path: impl AsRef<std::path::Path>) -> String {
    path.as_ref().to_string_lossy().into_owned()
}
