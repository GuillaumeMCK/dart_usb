use flutter_rust_bridge::frb;
use nusb::transfer::TransferError;

/// What went wrong, for both device operations and transfers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsbErrorKind {
    /// Device is disconnected.
    Disconnected,
    /// Device, interface, or endpoint is in use by another application,
    /// kernel driver, or handle.
    Busy,
    /// This user or application does not have permission to perform the
    /// requested operation.
    PermissionDenied,
    /// Requested configuration, interface, or alternate setting not found.
    NotFound,
    /// The operation is not supported by the platform or its driver.
    Unsupported,
    /// Uncategorized error.
    Other,
    /// Transfer was cancelled or timed out.
    TransferCancelled,
    /// Endpoint in a STALL condition. Clear it with `clearHalt`.
    TransferStall,
    /// Device disconnected during the transfer.
    TransferDisconnected,
    /// Hardware issue or protocol violation.
    TransferFault,
    /// The request has an invalid argument or is not supported by this OS.
    TransferInvalidArgument,
    /// Unknown or OS-specific transfer error; see `osError`.
    TransferUnknown,
    /// The device returned an invalid descriptor.
    InvalidDescriptor,
    /// The device is unconfigured, or no descriptor matches the active
    /// configuration.
    NotConfigured,
    /// A read or write timed out.
    TimedOut,
    /// A reader ended before the expected data or short packet.
    EndOfStream,
}

/// Exception thrown by every failed usb_host operation.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'UsbException(${kind.name}): $message';
"#)]
pub struct UsbException {
    pub kind: UsbErrorKind,
    pub message: String,
    /// OS error code: `errno` on Linux, `WIN32_ERROR` on Windows, `IOReturn`
    /// on macOS.
    pub os_error: Option<u32>,
}

impl UsbException {
    pub(crate) fn new(kind: UsbErrorKind, message: impl Into<String>) -> Self {
        UsbException { kind, message: message.into(), os_error: None }
    }
}

impl From<nusb::Error> for UsbException {
    fn from(e: nusb::Error) -> Self {
        let kind = match e.kind() {
            nusb::ErrorKind::Disconnected => UsbErrorKind::Disconnected,
            nusb::ErrorKind::Busy => UsbErrorKind::Busy,
            nusb::ErrorKind::PermissionDenied => UsbErrorKind::PermissionDenied,
            nusb::ErrorKind::NotFound => UsbErrorKind::NotFound,
            nusb::ErrorKind::Unsupported => UsbErrorKind::Unsupported,
            _ => UsbErrorKind::Other,
        };
        UsbException { kind, message: e.to_string(), os_error: e.os_error() }
    }
}

impl From<TransferError> for UsbException {
    fn from(e: TransferError) -> Self {
        let (kind, os_error) = match e {
            TransferError::Cancelled => (UsbErrorKind::TransferCancelled, None),
            TransferError::Stall => (UsbErrorKind::TransferStall, None),
            TransferError::Disconnected => (UsbErrorKind::TransferDisconnected, None),
            TransferError::Fault => (UsbErrorKind::TransferFault, None),
            TransferError::InvalidArgument => (UsbErrorKind::TransferInvalidArgument, None),
            TransferError::Unknown(code) => (UsbErrorKind::TransferUnknown, Some(code)),
        };
        UsbException { kind, message: e.to_string(), os_error }
    }
}

impl From<nusb::GetDescriptorError> for UsbException {
    fn from(e: nusb::GetDescriptorError) -> Self {
        match e {
            nusb::GetDescriptorError::Transfer(t) => t.into(),
            nusb::GetDescriptorError::InvalidDescriptor => {
                UsbException::new(UsbErrorKind::InvalidDescriptor, "invalid descriptor")
            }
        }
    }
}

impl From<nusb::ActiveConfigurationError> for UsbException {
    fn from(e: nusb::ActiveConfigurationError) -> Self {
        UsbException::new(UsbErrorKind::NotConfigured, e.to_string())
    }
}

/// Errors from nusb's `Read`/`Write` adapters wrap a `TransferError`.
impl From<std::io::Error> for UsbException {
    fn from(e: std::io::Error) -> Self {
        if let Some(t) = e.get_ref().and_then(|inner| inner.downcast_ref::<TransferError>()) {
            return (*t).into();
        }
        let kind = match e.kind() {
            std::io::ErrorKind::TimedOut => UsbErrorKind::TimedOut,
            std::io::ErrorKind::UnexpectedEof => UsbErrorKind::EndOfStream,
            _ => UsbErrorKind::Other,
        };
        UsbException { kind, message: e.to_string(), os_error: e.raw_os_error().map(|c| c as u32) }
    }
}
