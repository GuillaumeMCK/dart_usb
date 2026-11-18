//! Gadget registration in configfs.

use std::sync::Mutex;

use flutter_rust_bridge::frb;

use super::error::{GadgetErrorKind, GadgetException};
use super::udc::Udc;
use super::{localized, path_string, speed_from_code, ClassCodes, LocalizedString};

/// A function as added to a configuration. Obtained from a function with
/// `handle()`; each handle is used once.
#[frb(opaque)]
pub struct FunctionHandle(pub(crate) usb_gadget::function::Handle);

/// Device strings in one language.
#[derive(Debug, Clone)]
pub struct GadgetStringsSpec {
    pub language: u16,
    pub manufacturer: String,
    pub product: String,
    pub serial_number: String,
}

/// Microsoft OS descriptor.
#[derive(Debug, Clone)]
pub struct OsDescriptorSpec {
    pub vendor_code: u8,
    pub qw_sign: String,
    /// Index of the configuration Windows uses.
    pub config: u32,
}

/// WebUSB platform capability.
#[derive(Debug, Clone)]
pub struct WebUsbSpec {
    /// `bcdVersion`, 0x0100 for WebUSB 1.0.
    pub version: u16,
    pub vendor_code: u8,
    pub landing_page: String,
}

/// A configuration and its functions.
pub struct ConfigSpec {
    pub description: Vec<LocalizedString>,
    /// In milliamps.
    pub max_power: u16,
    pub self_powered: bool,
    pub remote_wakeup: bool,
    pub functions: Vec<FunctionHandle>,
}

/// Everything configfs needs to create a gadget.
pub struct GadgetSpec {
    pub name: Option<String>,
    pub class: ClassCodes,
    pub vendor: u16,
    pub product: u16,
    pub strings: Vec<GadgetStringsSpec>,
    pub max_packet_size0: u8,
    pub device_release: u16,
    /// `bcdUSB`.
    pub usb_version: u16,
    /// Speed code (see `speed_code`), or none for the UDC's maximum.
    pub max_speed: Option<u8>,
    pub os_descriptor: Option<OsDescriptorSpec>,
    pub web_usb: Option<WebUsbSpec>,
    pub configs: Vec<ConfigSpec>,
    /// Keeps the partially created gadget in configfs if registration fails,
    /// for debugging.
    pub keep_on_error: bool,
}

/// A function as listed in configfs.
#[derive(Debug, Clone)]
pub struct RegisteredFunction {
    pub driver: String,
    pub instance: String,
}

fn usb_version(bcd: u16) -> usb_gadget::UsbVersion {
    use usb_gadget::UsbVersion as V;
    match bcd {
        0x0110 => V::V11,
        0x0200 => V::V20,
        0x0210 => V::V21,
        0x0300 => V::V30,
        0x0310 => V::V31,
        other => V::Other(other),
    }
}

fn build(spec: GadgetSpec) -> usb_gadget::Gadget {
    let mut gadget = usb_gadget::Gadget::new(
        spec.class.into(),
        usb_gadget::Id::new(spec.vendor, spec.product),
        usb_gadget::Strings::new("", "", ""),
    );
    gadget.name = spec.name;
    gadget.strings = spec
        .strings
        .into_iter()
        .map(|s| {
            (
                usb_gadget::Language::Other(s.language),
                usb_gadget::Strings::new(s.manufacturer, s.product, s.serial_number),
            )
        })
        .collect();
    gadget.max_packet_size0 = spec.max_packet_size0;
    gadget.device_release = spec.device_release;
    gadget.usb_version = usb_version(spec.usb_version);
    gadget.max_speed = spec.max_speed.map(speed_from_code);
    gadget.os_descriptor = spec.os_descriptor.map(|o| {
        let mut os = usb_gadget::OsDescriptor::microsoft();
        os.vendor_code = o.vendor_code;
        os.qw_sign = o.qw_sign;
        os.config = o.config as usize;
        os
    });
    gadget.web_usb = spec.web_usb.map(|w| {
        let mut web = usb_gadget::WebUsb::new(w.vendor_code, w.landing_page);
        web.version = match w.version {
            0x0100 => usb_gadget::WebUsbVersion::V10,
            other => usb_gadget::WebUsbVersion::Other(other),
        };
        web
    });
    gadget.keep_on_error = spec.keep_on_error;
    for c in spec.configs {
        let mut config = usb_gadget::Config::new("");
        config.description = localized(c.description);
        config.max_power = c.max_power;
        config.self_powered = c.self_powered;
        config.remote_wakeup = c.remote_wakeup;
        config.functions = c.functions.into_iter().map(|f| f.0).collect();
        gadget.add_config(config);
    }
    gadget
}

/// Creates the gadget in configfs without binding it to a UDC.
pub fn register_gadget(spec: GadgetSpec) -> Result<RegisteredGadget, GadgetException> {
    Ok(RegisteredGadget(Mutex::new(Some(build(spec).register()?))))
}

/// A gadget created in configfs. It stays registered until [remove] is
/// called, or until this object is disposed unless [detach] was called.
#[frb(opaque)]
pub struct RegisteredGadget(Mutex<Option<usb_gadget::RegGadget>>);

impl RegisteredGadget {
    fn with<T>(
        &self,
        f: impl FnOnce(&mut usb_gadget::RegGadget) -> std::io::Result<T>,
    ) -> Result<T, GadgetException> {
        let mut guard = self.0.lock().unwrap();
        let reg = guard
            .as_mut()
            .ok_or_else(|| GadgetException::new(GadgetErrorKind::Disconnected, "gadget was removed"))?;
        Ok(f(reg)?)
    }

    /// Name of the gadget's configfs directory.
    #[frb(sync)]
    pub fn name(&self) -> Result<String, GadgetException> {
        self.with(|r| Ok(path_string(r.name())))
    }

    /// The gadget's configfs directory.
    #[frb(sync)]
    pub fn path(&self) -> Result<String, GadgetException> {
        self.with(|r| Ok(path_string(r.path())))
    }

    /// Whether disposing this object removes the gadget; see [detach].
    #[frb(sync)]
    pub fn is_attached(&self) -> Result<bool, GadgetException> {
        self.with(|r| Ok(r.is_attached()))
    }

    /// Name of the UDC the gadget is bound to, if any.
    #[frb(sync)]
    pub fn udc(&self) -> Result<Option<String>, GadgetException> {
        self.with(|r| Ok(r.udc()?.map(path_string)))
    }

    /// The gadget's functions, as configfs lists them.
    #[frb(sync)]
    pub fn functions(&self) -> Result<Vec<RegisteredFunction>, GadgetException> {
        self.with(|r| {
            Ok(r.functions()?
                .into_iter()
                .map(|f| RegisteredFunction { driver: f.driver().into(), instance: f.instance().into() })
                .collect())
        })
    }

    /// Binds the gadget to [udc], so a host connected to it sees the device.
    #[frb(positional)]
    pub fn bind(&self, udc: &Udc) -> Result<(), GadgetException> {
        self.with(|r| r.bind(Some(&udc.0)))
    }

    /// Unbinds the gadget from its UDC; the host sees the device unplugged.
    pub fn unbind(&self) -> Result<(), GadgetException> {
        self.with(|r| r.bind(None))
    }

    /// Keeps the gadget registered after this object is disposed, or after
    /// the process exits.
    #[frb(sync)]
    pub fn detach(&self) -> Result<(), GadgetException> {
        self.with(|r| {
            r.detach();
            Ok(())
        })
    }

    /// Unbinds and removes the gadget from configfs.
    pub fn remove(&self) -> Result<(), GadgetException> {
        let reg = self.0.lock().unwrap().take();
        match reg {
            Some(reg) => Ok(reg.remove()?),
            None => Ok(()),
        }
    }
}

/// Every gadget in configfs, including ones registered by other programs.
/// They are detached: disposing them doesn't remove them.
#[frb(sync)]
pub fn registered_gadgets() -> Result<Vec<RegisteredGadget>, GadgetException> {
    Ok(usb_gadget::registered()?.into_iter().map(|r| RegisteredGadget(Mutex::new(Some(r)))).collect())
}

/// Removes every gadget in configfs.
pub fn remove_all_gadgets() -> Result<(), GadgetException> {
    Ok(usb_gadget::remove_all()?)
}

/// Unbinds every gadget in configfs from its UDC.
pub fn unbind_all_gadgets() -> Result<(), GadgetException> {
    Ok(usb_gadget::unbind_all()?)
}
