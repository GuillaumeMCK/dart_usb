//! Opened devices and claimed interfaces.

use std::num::NonZeroU8;
use chrono::Duration;

use flutter_rust_bridge::frb;
use nusb::transfer::{Bulk, In, Interrupt, Out};
use nusb::MaybeFuture;

use super::descriptors::{ConfigurationDescriptor, DeviceDescriptor, InterfaceDescriptor};
use super::endpoint::{InEndpoint, InKind, OutEndpoint, OutKind};
use super::error::{UsbException, UsbErrorKind};
use super::types::{timeout_or_default, ControlIn, ControlOut, Speed, US_ENGLISH};

/// An opened USB device. The OS handle closes once this object and every
/// interface claimed from it are garbage collected or disposed.
#[frb(opaque)]
pub struct Device(pub(crate) nusb::Device);

impl Device {
    /// Opens an interface of the device and claims it for exclusive use.
    #[frb(positional)]
    pub fn claim_interface(&self, interface_number: u8) -> Result<Interface, UsbException> {
        Ok(Interface(self.0.claim_interface(interface_number).wait()?))
    }

    /// Detaches kernel drivers, then claims the interface. Kernel drivers
    /// can only be detached on Linux; elsewhere this is [claimInterface].
    #[frb(positional)]
    pub fn detach_and_claim_interface(&self, interface_number: u8) -> Result<Interface, UsbException> {
        Ok(Interface(self.0.detach_and_claim_interface(interface_number).wait()?))
    }

    /// Detaches the kernel driver from an interface (Linux only).
    #[frb(sync, positional)]
    pub fn detach_kernel_driver(&self, interface_number: u8) -> Result<(), UsbException> {
        Ok(self.0.detach_kernel_driver(interface_number)?)
    }

    /// Reattaches the kernel driver to an interface (Linux only).
    #[frb(sync, positional)]
    pub fn attach_kernel_driver(&self, interface_number: u8) -> Result<(), UsbException> {
        Ok(self.0.attach_kernel_driver(interface_number)?)
    }

    #[frb(sync, getter)]
    pub fn device_descriptor(&self) -> DeviceDescriptor {
        self.0.device_descriptor().into()
    }

    #[frb(sync, getter)]
    pub fn speed(&self) -> Option<Speed> {
        self.0.speed().and_then(Speed::from_nusb)
    }

    /// The active configuration's descriptor. Throws `notConfigured` if the
    /// device is unconfigured.
    #[frb(sync)]
    pub fn active_configuration(&self) -> Result<ConfigurationDescriptor, UsbException> {
        Ok(self.0.active_configuration()?.into())
    }

    #[frb(sync, getter)]
    pub fn configurations(&self) -> Vec<ConfigurationDescriptor> {
        self.0.configurations().map(Into::into).collect()
    }

    /// Sets the configuration (`bConfigurationValue`), or 0 to unconfigure.
    /// Not supported on Windows.
    #[frb(positional)]
    pub fn set_configuration(&self, configuration: u8) -> Result<(), UsbException> {
        Ok(self.0.set_configuration(configuration).wait()?)
    }

    /// Resets the device, forcing it to re-enumerate. Not supported on
    /// Windows.
    pub fn reset(&self) -> Result<(), UsbException> {
        Ok(self.0.reset().wait()?)
    }

    /// Requests a descriptor from the device. [languageId] is only used for
    /// string descriptors. [timeout] defaults to 1 second.
    pub fn get_descriptor(
        &self,
        descriptor_type: u8,
        index: u8,
        language_id: Option<u16>,
        timeout: Option<Duration>,
    ) -> Result<Vec<u8>, UsbException> {
        Ok(self
            .0
            .get_descriptor(descriptor_type, index, language_id.unwrap_or(0), timeout_or_default(timeout))
            .wait()?)
    }

    /// The language IDs supported for string descriptors.
    pub fn get_string_descriptor_supported_languages(&self, timeout: Option<Duration>) -> Result<Vec<u16>, UsbException> {
        Ok(self
            .0
            .get_string_descriptor_supported_languages(timeout_or_default(timeout))
            .wait()?
            .collect())
    }

    /// Requests string descriptor [index]. [languageId] defaults to US
    /// English (0x0409), the only language most devices support.
    pub fn get_string_descriptor(
        &self,
        index: u8,
        language_id: Option<u16>,
        timeout: Option<Duration>,
    ) -> Result<String, UsbException> {
        let index = NonZeroU8::new(index)
            .ok_or_else(|| UsbException::new(UsbErrorKind::TransferInvalidArgument, "string index must be nonzero"))?;
        Ok(self
            .0
            .get_string_descriptor(index, language_id.unwrap_or(US_ENGLISH), timeout_or_default(timeout))
            .wait()?)
    }

    /// IN control transfer on the default endpoint; [timeout] defaults to 1
    /// second. Not supported on Windows:
    /// claim an interface and use [Interface.controlIn].
    pub fn control_in(&self, request: ControlIn, timeout: Option<Duration>) -> Result<Vec<u8>, UsbException> {
        #[cfg(target_os = "windows")]
        {
            let _ = (request, timeout);
            Err(UsbException::new(UsbErrorKind::Unsupported, "use Interface.controlIn on Windows"))
        }
        #[cfg(not(target_os = "windows"))]
        Ok(self.0.control_in((&request).into(), timeout_or_default(timeout)).wait()?)
    }

    /// OUT control transfer on the default endpoint; [timeout] defaults to 1
    /// second. Not supported on Windows:
    /// claim an interface and use [Interface.controlOut].
    pub fn control_out(&self, request: ControlOut, timeout: Option<Duration>) -> Result<(), UsbException> {
        #[cfg(target_os = "windows")]
        {
            let _ = (request, timeout);
            Err(UsbException::new(UsbErrorKind::Unsupported, "use Interface.controlOut on Windows"))
        }
        #[cfg(not(target_os = "windows"))]
        Ok(self.0.control_out(request.as_nusb(), timeout_or_default(timeout)).wait()?)
    }
}

/// A claimed interface. Released once this object and its endpoints are
/// garbage collected or disposed.
#[frb(opaque)]
pub struct Interface(pub(crate) nusb::Interface);

impl Interface {
    #[frb(sync, getter)]
    pub fn interface_number(&self) -> u8 {
        self.0.interface_number()
    }

    #[frb(sync, getter)]
    pub fn alt_setting(&self) -> u8 {
        self.0.get_alt_setting()
    }

    /// Selects an alternate setting. All endpoints must be closed first.
    #[frb(positional)]
    pub fn set_alt_setting(&self, alt_setting: u8) -> Result<(), UsbException> {
        Ok(self.0.set_alt_setting(alt_setting).wait()?)
    }

    /// The descriptors of every alternate setting of this interface.
    #[frb(sync, getter)]
    pub fn descriptors(&self) -> Vec<InterfaceDescriptor> {
        self.0.descriptors().map(Into::into).collect()
    }

    /// The descriptor of the current alternate setting.
    #[frb(sync, getter)]
    pub fn descriptor(&self) -> Option<InterfaceDescriptor> {
        self.0.descriptor().map(Into::into)
    }

    /// IN control transfer. On Windows, for `Recipient.interface`, the low
    /// byte of `index` must be this interface's number.
    pub fn control_in(&self, request: ControlIn, timeout: Option<Duration>) -> Result<Vec<u8>, UsbException> {
        Ok(self.0.control_in((&request).into(), timeout_or_default(timeout)).wait()?)
    }

    /// OUT control transfer. Same Windows restriction as [controlIn].
    pub fn control_out(&self, request: ControlOut, timeout: Option<Duration>) -> Result<(), UsbException> {
        Ok(self.0.control_out(request.as_nusb(), timeout_or_default(timeout)).wait()?)
    }

    /// Opens a bulk or interrupt IN endpoint for exclusive use.
    #[frb(sync, positional)]
    pub fn endpoint_in(&self, address: u8) -> Result<InEndpoint, UsbException> {
        let kind = match self.transfer_type(address)? {
            nusb::descriptors::TransferType::Bulk => InKind::Bulk(self.0.endpoint::<Bulk, In>(address)?),
            nusb::descriptors::TransferType::Interrupt => InKind::Interrupt(self.0.endpoint::<Interrupt, In>(address)?),
            _ => return Err(unsupported_endpoint()),
        };
        Ok(InEndpoint(kind))
    }

    /// Opens a bulk or interrupt OUT endpoint for exclusive use.
    #[frb(sync, positional)]
    pub fn endpoint_out(&self, address: u8) -> Result<OutEndpoint, UsbException> {
        let kind = match self.transfer_type(address)? {
            nusb::descriptors::TransferType::Bulk => OutKind::Bulk(self.0.endpoint::<Bulk, Out>(address)?),
            nusb::descriptors::TransferType::Interrupt => {
                OutKind::Interrupt(self.0.endpoint::<Interrupt, Out>(address)?)
            }
            _ => return Err(unsupported_endpoint()),
        };
        Ok(OutEndpoint(kind))
    }

    fn transfer_type(&self, address: u8) -> Result<nusb::descriptors::TransferType, UsbException> {
        self.0
            .descriptor()
            .and_then(|d| d.endpoints().find(|e| e.address() == address).map(|e| e.transfer_type()))
            .ok_or_else(|| UsbException::new(UsbErrorKind::NotFound, "specified endpoint does not exist on this interface"))
    }
}

fn unsupported_endpoint() -> UsbException {
    UsbException::new(UsbErrorKind::Unsupported, "only bulk and interrupt endpoints are supported")
}
