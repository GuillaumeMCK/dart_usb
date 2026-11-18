//! Opened devices and claimed interfaces.

use std::num::NonZeroU8;
use chrono::Duration;

use flutter_rust_bridge::frb;
use nusb::transfer::{Bulk, In, Interrupt, Out};
use nusb::MaybeFuture;

use super::endpoint::{InEndpoint, InKind, OutEndpoint, OutKind};
use super::error::{UsbException, UsbErrorKind};
use super::types::{control_kind, speed_code, timeout_or_default, US_ENGLISH};

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

    /// The 18-byte device descriptor. Parsed as `deviceDescriptor`.
    #[frb(sync, getter)]
    pub fn raw_device_descriptor(&self) -> Vec<u8> {
        self.0.device_descriptor().as_bytes().to_vec()
    }

    /// Speed code; read it as `speed`.
    #[frb(sync, getter)]
    pub fn raw_speed(&self) -> Option<u8> {
        self.0.speed().and_then(speed_code)
    }

    /// The active configuration's descriptors. Parsed as
    /// `activeConfiguration()`; throws `notConfigured` if the device is
    /// unconfigured.
    #[frb(sync)]
    pub fn raw_active_configuration(&self) -> Result<Vec<u8>, UsbException> {
        Ok(self.0.active_configuration()?.as_bytes().to_vec())
    }

    /// Each configuration's descriptors. Parsed as `configurations`.
    #[frb(sync, getter)]
    pub fn raw_configurations(&self) -> Vec<Vec<u8>> {
        self.0.configurations().map(|c| c.as_bytes().to_vec()).collect()
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

    /// IN control transfer from setup fields; use `controlIn`. Not
    /// supported on Windows: claim an interface and use its `controlIn`.
    pub fn control_in_raw(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        length: u16,
        timeout: Option<Duration>,
    ) -> Result<Vec<u8>, UsbException> {
        #[cfg(target_os = "windows")]
        {
            let _ = (request_type, request, value, index, length, timeout);
            Err(UsbException::new(UsbErrorKind::Unsupported, "use Interface.controlIn on Windows"))
        }
        #[cfg(not(target_os = "windows"))]
        Ok(self.0.control_in(control_in(request_type, request, value, index, length)?, timeout_or_default(timeout)).wait()?)
    }

    /// OUT control transfer from setup fields; use `controlOut`. Not
    /// supported on Windows: claim an interface and use its `controlOut`.
    pub fn control_out_raw(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: Vec<u8>,
        timeout: Option<Duration>,
    ) -> Result<(), UsbException> {
        #[cfg(target_os = "windows")]
        {
            let _ = (request_type, request, value, index, data, timeout);
            Err(UsbException::new(UsbErrorKind::Unsupported, "use Interface.controlOut on Windows"))
        }
        #[cfg(not(target_os = "windows"))]
        Ok(self.0.control_out(control_out(request_type, request, value, index, &data)?, timeout_or_default(timeout)).wait()?)
    }
}

fn control_in(request_type: u8, request: u8, value: u16, index: u16, length: u16) -> Result<nusb::transfer::ControlIn, UsbException> {
    let (control_type, recipient) = control_kind(request_type)?;
    Ok(nusb::transfer::ControlIn { control_type, recipient, request, value, index, length })
}

fn control_out(request_type: u8, request: u8, value: u16, index: u16, data: &[u8]) -> Result<nusb::transfer::ControlOut<'_>, UsbException> {
    let (control_type, recipient) = control_kind(request_type)?;
    Ok(nusb::transfer::ControlOut { control_type, recipient, request, value, index, data })
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

    /// Each alternate setting's descriptors, in the active configuration.
    /// Parsed as `descriptors`.
    #[frb(sync, getter)]
    pub fn raw_descriptors(&self) -> Vec<Vec<u8>> {
        self.0.descriptors().map(|d| d.as_bytes().to_vec()).collect()
    }

    /// The current alternate setting's descriptors. Parsed as `descriptor`.
    #[frb(sync, getter)]
    pub fn raw_descriptor(&self) -> Option<Vec<u8>> {
        self.0.descriptor().map(|d| d.as_bytes().to_vec())
    }

    /// IN control transfer from setup fields; use `controlIn`. On Windows,
    /// for interface recipients, the low byte of `index` must be this
    /// interface's number.
    pub fn control_in_raw(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        length: u16,
        timeout: Option<Duration>,
    ) -> Result<Vec<u8>, UsbException> {
        Ok(self.0.control_in(control_in(request_type, request, value, index, length)?, timeout_or_default(timeout)).wait()?)
    }

    /// OUT control transfer from setup fields; use `controlOut`. Same
    /// Windows restriction as `controlIn`.
    pub fn control_out_raw(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: Vec<u8>,
        timeout: Option<Duration>,
    ) -> Result<(), UsbException> {
        Ok(self.0.control_out(control_out(request_type, request, value, index, &data)?, timeout_or_default(timeout)).wait()?)
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
