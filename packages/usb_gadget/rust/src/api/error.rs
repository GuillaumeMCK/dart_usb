use flutter_rust_bridge::frb;

/// What went wrong.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GadgetErrorKind {
    /// No such UDC, gadget, function or file.
    NotFound,
    /// Configuring gadgets needs root, or `CAP_SYS_ADMIN`.
    PermissionDenied,
    /// The UDC, name or endpoint is already in use.
    Busy,
    /// The function isn't registered or bound yet, or the host hasn't
    /// enabled it.
    NotReady,
    /// The gadget was removed, unbound from its UDC, or disabled by the host.
    Disconnected,
    /// The operation timed out.
    TimedOut,
    /// The operation was cancelled.
    Cancelled,
    /// An argument or setting was rejected.
    InvalidInput,
    /// The kernel lacks the function driver or feature.
    Unsupported,
    /// Uncategorized error; see `osError`.
    Other,
}

/// Exception thrown by every failed usb_gadget operation.
#[derive(Debug, Clone)]
#[frb(dart_code = r#"
  @override
  String toString() => 'GadgetException(${kind.name}): $message';
"#)]
pub struct GadgetException {
    pub kind: GadgetErrorKind,
    pub message: String,
    /// The `errno` value, if the OS reported one.
    pub os_error: Option<i32>,
}

impl GadgetException {
    pub(crate) fn new(kind: GadgetErrorKind, message: impl Into<String>) -> Self {
        GadgetException { kind, message: message.into(), os_error: None }
    }
}

impl From<std::io::Error> for GadgetException {
    fn from(e: std::io::Error) -> Self {
        use std::io::ErrorKind as K;
        let os_error = e.raw_os_error();
        let kind = match os_error {
            Some(libc::EBUSY) | Some(libc::EADDRINUSE) => GadgetErrorKind::Busy,
            Some(libc::ESHUTDOWN) | Some(libc::ENODEV) | Some(libc::EPIPE) => GadgetErrorKind::Disconnected,
            Some(libc::ECANCELED) => GadgetErrorKind::Cancelled,
            Some(libc::EOPNOTSUPP) => GadgetErrorKind::Unsupported,
            _ => match e.kind() {
                K::NotFound => GadgetErrorKind::NotFound,
                K::PermissionDenied => GadgetErrorKind::PermissionDenied,
                K::ResourceBusy | K::AlreadyExists | K::AddrInUse => GadgetErrorKind::Busy,
                K::WouldBlock => GadgetErrorKind::NotReady,
                K::BrokenPipe | K::NotConnected | K::ConnectionReset => GadgetErrorKind::Disconnected,
                K::TimedOut => GadgetErrorKind::TimedOut,
                K::InvalidInput | K::InvalidData => GadgetErrorKind::InvalidInput,
                K::Unsupported => GadgetErrorKind::Unsupported,
                _ => GadgetErrorKind::Other,
            },
        };
        GadgetException { kind, message: e.to_string(), os_error }
    }
}
