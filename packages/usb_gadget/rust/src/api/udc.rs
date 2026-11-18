//! USB device controllers (UDCs): the hardware a gadget binds to.

use flutter_rust_bridge::frb;

use super::error::GadgetException;
use super::{path_string, speed_code};

/// A USB device controller, as listed in `/sys/class/udc`.
#[frb(opaque)]
pub struct Udc(pub(crate) usb_gadget::Udc);

/// USB device state of a UDC, as defined in chapter 9 of the USB 2.0
/// specification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UdcState {
    NotAttached,
    Attached,
    Powered,
    Reconnecting,
    Unauthenticated,
    Default,
    Addressed,
    Configured,
    Suspended,
    Unknown,
}

impl From<usb_gadget::UdcState> for UdcState {
    fn from(s: usb_gadget::UdcState) -> Self {
        use usb_gadget::UdcState as S;
        match s {
            S::NotAttached => Self::NotAttached,
            S::Attached => Self::Attached,
            S::Powered => Self::Powered,
            S::Reconnecting => Self::Reconnecting,
            S::Unauthenticated => Self::Unauthenticated,
            S::Default => Self::Default,
            S::Addressed => Self::Addressed,
            S::Configured => Self::Configured,
            S::Suspended => Self::Suspended,
            _ => Self::Unknown,
        }
    }
}

/// The USB device controllers of this system.
#[frb(sync)]
pub fn udcs() -> Result<Vec<Udc>, GadgetException> {
    Ok(usb_gadget::udcs()?.into_iter().map(Udc).collect())
}

/// The system's only, or first, USB device controller.
#[frb(sync)]
pub fn default_udc() -> Result<Udc, GadgetException> {
    Ok(Udc(usb_gadget::default_udc()?))
}

impl Udc {
    /// Name, such as `dummy_udc.0` or `fe980000.usb`.
    #[frb(sync, getter)]
    pub fn name(&self) -> String {
        path_string(self.0.name())
    }

    #[frb(sync)]
    pub fn state(&self) -> Result<UdcState, GadgetException> {
        Ok(self.0.state()?.into())
    }

    /// Speed code of the current connection; read it as `currentSpeed`.
    #[frb(sync)]
    pub fn raw_current_speed(&self) -> Result<u8, GadgetException> {
        Ok(speed_code(self.0.current_speed()?))
    }

    /// Speed code of the fastest supported speed; read it as `maxSpeed`.
    #[frb(sync)]
    pub fn raw_max_speed(&self) -> Result<u8, GadgetException> {
        Ok(speed_code(self.0.max_speed()?))
    }

    /// Whether the controller supports USB On-The-Go.
    #[frb(sync)]
    pub fn is_otg(&self) -> Result<bool, GadgetException> {
        Ok(self.0.is_otg()?)
    }

    /// Whether an OTG controller is in the A-peripheral role.
    #[frb(sync)]
    pub fn is_a_peripheral(&self) -> Result<bool, GadgetException> {
        Ok(self.0.is_a_peripheral()?)
    }

    /// Connects (`true`) or disconnects the data pull-up, so the host sees
    /// the device plugged in or unplugged.
    #[frb(positional)]
    pub fn set_soft_connect(&self, connect: bool) -> Result<(), GadgetException> {
        Ok(self.0.set_soft_connect(connect)?)
    }

    /// Starts Session Request Protocol (OTG).
    pub fn start_srp(&self) -> Result<(), GadgetException> {
        Ok(self.0.start_srp()?)
    }

    /// Kernel driver of the controller.
    #[frb(sync)]
    pub fn driver(&self) -> Result<String, GadgetException> {
        Ok(path_string(self.0.driver()?))
    }

    /// Name of the gadget driver bound to the controller, if any.
    #[frb(sync)]
    pub fn function(&self) -> Result<Option<String>, GadgetException> {
        Ok(self.0.function()?.map(path_string))
    }
}
