//! Custom functions implemented in Dart through FunctionFS. Each function
//! is owned by its own thread; see `crate::event_thread`.

use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{mpsc, Mutex};

use flutter_rust_bridge::frb;
use usb_gadget::function::custom;

use super::endpoint::{EndpointReceiver, EndpointSender};
use super::error::{GadgetErrorKind, GadgetException};
use super::function::FunctionState;
use super::gadget::FunctionHandle;
use super::{localized, path_string, std_duration, ClassCodes, LocalizedString};
use crate::event_thread::{Action, EventThread, Outcome, Reply, REPLY_TIMEOUT};

// --- Settings ---------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct EndpointSpec {
    /// Device to host (an IN endpoint) when true.
    pub device_to_host: bool,
    /// Transfers queued in the kernel at once.
    pub queue_length: u32,
    /// `bmAttributes` transfer type: 0 control, 1 isochronous, 2 bulk,
    /// 3 interrupt.
    pub transfer_type: u8,
    /// Isochronous only: 0 none, 1 async, 2 adaptive, 3 sync.
    pub sync_type: u8,
    /// Isochronous only: 0 data, 1 feedback, 2 implicit feedback.
    pub usage_type: u8,
    pub max_packet_size_hs: u16,
    pub max_packet_size_ss: u16,
    pub max_burst_ss: u8,
    pub bytes_per_interval_ss: u16,
    /// None for the crate's default.
    pub interval: Option<u8>,
    /// Audio endpoints: `bRefresh` and `bSynchAddress`.
    pub audio_refresh: Option<u8>,
    pub audio_synch_address: Option<u8>,
}

#[derive(Debug, Clone)]
pub struct AssociationSpec {
    /// Interfaces with the same id share one association.
    pub id: u32,
    pub class: ClassCodes,
    pub name: Vec<LocalizedString>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsRegValueKind {
    Sz,
    ExpandSz,
    Binary,
    DwordLe,
    DwordBe,
    Link,
    MultiSz,
}

/// A Windows registry value; only the field for [kind] is used.
#[derive(Debug, Clone)]
pub struct OsExtPropSpec {
    pub name: String,
    pub kind: OsRegValueKind,
    pub text: String,
    pub binary: Vec<u8>,
    pub dword: u32,
    pub strings: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct OsExtCompatSpec {
    /// 8 bytes, such as `WINUSB` padded with zeros.
    pub compatible_id: Vec<u8>,
    pub sub_compatible_id: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct CustomDescriptorSpec {
    pub descriptor_type: u8,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct InterfaceSpec {
    pub class: ClassCodes,
    pub name: Vec<LocalizedString>,
    pub endpoints: Vec<EndpointSpec>,
    pub association: Option<AssociationSpec>,
    pub os_ext_compat: Vec<OsExtCompatSpec>,
    pub os_ext_props: Vec<OsExtPropSpec>,
    pub custom_descriptors: Vec<CustomDescriptorSpec>,
}

#[derive(Debug, Clone)]
pub struct CustomSpec {
    pub interfaces: Vec<InterfaceSpec>,
    /// Receive control requests for any recipient, not just this function's
    /// interfaces and endpoints.
    pub all_ctrl_recipient: bool,
    /// Receive control requests while the device is unconfigured.
    pub config0_setup: bool,
    /// Mount FunctionFS here instead of a temporary directory.
    pub ffs_dir: Option<String>,
    pub ffs_root_mode: Option<u32>,
    pub ffs_file_mode: Option<u32>,
    pub ffs_uid: Option<u32>,
    pub ffs_gid: Option<u32>,
    pub ffs_no_disconnect: bool,
    pub ffs_no_init: bool,
    pub ffs_no_mount: bool,
}

fn eight_bytes(v: Vec<u8>) -> Result<[u8; 8], GadgetException> {
    let mut out = [0; 8];
    if v.len() > 8 {
        return Err(GadgetException::new(GadgetErrorKind::InvalidInput, "compatible IDs are at most 8 bytes"));
    }
    out[..v.len()].copy_from_slice(&v);
    Ok(out)
}

fn endpoint(spec: EndpointSpec) -> Result<(custom::Endpoint, EndpointIo), GadgetException> {
    let (direction, io) = if spec.device_to_host {
        let (sender, dir) = custom::EndpointDirection::device_to_host();
        (dir, EndpointIo::Sender(sender))
    } else {
        let (receiver, dir) = custom::EndpointDirection::host_to_device();
        (dir, EndpointIo::Receiver(receiver))
    };
    let transfer = match spec.transfer_type {
        0 => custom::TransferType::Control,
        1 => custom::TransferType::Isochronous {
            sync: match spec.sync_type {
                1 => custom::SyncType::Async,
                2 => custom::SyncType::Adaptive,
                3 => custom::SyncType::Sync,
                _ => custom::SyncType::NoSync,
            },
            usage: match spec.usage_type {
                1 => custom::UsageType::Feedback,
                2 => custom::UsageType::ImplicitFeedback,
                _ => custom::UsageType::Data,
            },
        },
        2 => custom::TransferType::Bulk,
        3 => custom::TransferType::Interrupt,
        t => return Err(GadgetException::new(GadgetErrorKind::InvalidInput, format!("unknown transfer type {t}"))),
    };
    let mut ep = custom::Endpoint::custom(direction.with_queue_len(spec.queue_length), transfer);
    ep.max_packet_size_hs = spec.max_packet_size_hs;
    ep.max_packet_size_ss = spec.max_packet_size_ss;
    ep.max_burst_ss = spec.max_burst_ss;
    ep.bytes_per_interval_ss = spec.bytes_per_interval_ss;
    if let Some(interval) = spec.interval {
        ep.interval = interval;
    }
    if spec.audio_refresh.is_some() || spec.audio_synch_address.is_some() {
        ep.audio = Some(custom::EndpointAudio {
            refresh: spec.audio_refresh.unwrap_or(0),
            synch_address: spec.audio_synch_address.unwrap_or(0),
        });
    }
    Ok((ep, io))
}

fn reg_value(p: OsExtPropSpec) -> custom::OsRegValue {
    use custom::OsRegValue as V;
    match p.kind {
        OsRegValueKind::Sz => V::Sz(p.text),
        OsRegValueKind::ExpandSz => V::ExpandSz(p.text),
        OsRegValueKind::Binary => V::Binary(p.binary),
        OsRegValueKind::DwordLe => V::DwordLe(p.dword),
        OsRegValueKind::DwordBe => V::DwordBe(p.dword),
        OsRegValueKind::Link => V::Link(p.text),
        OsRegValueKind::MultiSz => V::MultiSz(p.strings),
    }
}

// --- Events -----------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CustomEventKind {
    Bind,
    Unbind,
    Enable,
    Disable,
    Suspend,
    Resume,
    /// A control request whose data stage goes to the host: reply with
    /// `replySend` or `replyHalt`.
    SetupDeviceToHost,
    /// A control request whose data stage comes from the host: reply with
    /// `replyReceive` or `replyHalt`.
    SetupHostToDevice,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct CustomEvent {
    pub kind: CustomEventKind,
    /// Identifies a control request in replies.
    pub id: u32,
    /// The 8-byte SETUP packet, for control requests.
    pub setup: Vec<u8>,
    /// The FunctionFS event type, for `unknown` events.
    pub code: u8,
}

impl CustomEvent {
    pub(crate) fn simple(kind: CustomEventKind) -> Self {
        CustomEvent { kind, id: 0, setup: Vec::new(), code: 0 }
    }
}

// --- The function -----------------------------------------------------------

pub(crate) enum EndpointIo {
    Sender(custom::EndpointSender),
    Receiver(custom::EndpointReceiver),
}

/// A custom function: interfaces and endpoints implemented in Dart.
#[frb(opaque)]
pub struct CustomFunction {
    handle: usb_gadget::function::Handle,
    status: Option<usb_gadget::function::util::Status>,
    endpoints: Mutex<Vec<Option<EndpointIo>>>,
    thread: EventThread,
}

impl CustomFunction {
    /// Builds the function and starts its event thread. Its endpoints, in
    /// declaration order across interfaces, are taken with [take_sender] and
    /// [take_receiver].
    #[frb(sync)]
    pub fn new(spec: CustomSpec) -> Result<CustomFunction, GadgetException> {
        let interface_count = spec.interfaces.len();
        let mut builder = custom::Custom::builder();
        let mut endpoints = Vec::new();
        let mut associations = HashMap::new();
        for i in spec.interfaces {
            let mut interface = custom::Interface::new(i.class.into(), "");
            interface.name = localized(i.name);
            for e in i.endpoints {
                let (ep, io) = endpoint(e)?;
                interface.endpoints.push(ep);
                endpoints.push(Some(io));
            }
            if let Some(a) = i.association {
                let association = associations.entry(a.id).or_insert_with(|| {
                    let mut association = custom::Association::new(a.class.into(), "");
                    association.name = localized(a.name);
                    association
                });
                interface.association = Some(association.clone());
            }
            for c in i.os_ext_compat {
                interface.os_ext_compat.push(custom::OsExtCompat::new(
                    eight_bytes(c.compatible_id)?,
                    eight_bytes(c.sub_compatible_id)?,
                ));
            }
            for p in i.os_ext_props {
                interface.os_ext_props.push(custom::OsExtProp::new(p.name.clone(), reg_value(p)));
            }
            for d in i.custom_descriptors {
                interface.custom_descs.push(custom::CustomDesc { descriptor_type: d.descriptor_type, data: d.data });
            }
            builder = builder.with_interface(interface);
        }
        builder.all_ctrl_recipient = spec.all_ctrl_recipient;
        builder.config0_setup = spec.config0_setup;
        builder.ffs_dir = spec.ffs_dir.map(Into::into);
        builder.ffs_root_mode = spec.ffs_root_mode;
        builder.ffs_file_mode = spec.ffs_file_mode;
        builder.ffs_uid = spec.ffs_uid;
        builder.ffs_gid = spec.ffs_gid;
        builder.ffs_no_disconnect = spec.ffs_no_disconnect;
        builder.ffs_no_init = spec.ffs_no_init;
        builder.ffs_no_mount = spec.ffs_no_mount;
        let (custom, handle) = builder.build();
        Ok(CustomFunction {
            handle,
            status: custom.status(),
            endpoints: Mutex::new(endpoints),
            thread: EventThread::spawn(custom, interface_count)?,
        })
    }

    /// A handle for adding this function to a configuration.
    #[frb(sync)]
    pub fn handle(&self) -> FunctionHandle {
        FunctionHandle(self.handle.clone())
    }

    #[frb(sync, getter)]
    pub fn state(&self) -> FunctionState {
        self.status.as_ref().map_or(FunctionState::Unregistered, |s| s.state().into())
    }

    /// The function's configfs directory, once registered.
    #[frb(sync, getter)]
    pub fn path(&self) -> Option<String> {
        self.status.as_ref().and_then(|s| s.path()).map(path_string)
    }

    fn take(&self, index: u32) -> Result<EndpointIo, GadgetException> {
        self.endpoints
            .lock()
            .unwrap()
            .get_mut(index as usize)
            .and_then(Option::take)
            .ok_or_else(|| GadgetException::new(GadgetErrorKind::NotFound, format!("no endpoint {index} to take")))
    }

    /// The sending side of device-to-host endpoint [index].
    #[frb(sync, positional)]
    pub fn take_sender(&self, index: u32) -> Result<EndpointSender, GadgetException> {
        match self.take(index)? {
            EndpointIo::Sender(s) => Ok(EndpointSender::new(s)),
            EndpointIo::Receiver(_) => Err(GadgetException::new(GadgetErrorKind::InvalidInput, "not an IN endpoint")),
        }
    }

    /// The receiving side of host-to-device endpoint [index].
    #[frb(sync, positional)]
    pub fn take_receiver(&self, index: u32) -> Result<EndpointReceiver, GadgetException> {
        match self.take(index)? {
            EndpointIo::Receiver(r) => Ok(EndpointReceiver::new(r)),
            EndpointIo::Sender(_) => Err(GadgetException::new(GadgetErrorKind::InvalidInput, "not an OUT endpoint")),
        }
    }

    /// The number the host sees for interface [index] of this function.
    /// Throws `notReady` until the function is bound. Never blocks, so it is
    /// safe while answering a control request.
    #[frb(sync, positional)]
    pub fn interface_number(&self, index: u32) -> Result<u8, GadgetException> {
        let info = self.thread.shared.info.lock().unwrap();
        match info.interface_numbers.get(index as usize) {
            Some(Some(number)) => Ok(*number),
            Some(None) => Err(GadgetException::new(GadgetErrorKind::NotReady, "the function is not bound yet")),
            None => Err(GadgetException::new(GadgetErrorKind::NotFound, format!("no interface {index}"))),
        }
    }

    /// Where FunctionFS is mounted. Throws `notReady` until registered.
    #[frb(sync, getter)]
    pub fn ffs_dir(&self) -> Result<String, GadgetException> {
        match &self.thread.shared.info.lock().unwrap().ffs_dir {
            Some(dir) => Ok(path_string(dir)),
            None => Err(GadgetException::new(GadgetErrorKind::NotReady, "the function is not registered yet")),
        }
    }

    /// Whether Dart is listening for events. While not, control requests
    /// are stalled at once; lifecycle events are kept for the next listener.
    #[frb(sync, positional)]
    pub fn set_listening(&self, listening: bool) {
        self.thread.shared.listening.store(listening, Ordering::Relaxed);
    }

    /// The next event, waiting up to [timeout]; none if it elapses. For a
    /// single poller.
    #[frb(positional)]
    pub fn next_event(&self, timeout: chrono::Duration) -> Result<Option<CustomEvent>, GadgetException> {
        let events = self.thread.events.lock().unwrap();
        match events.recv_timeout(std_duration(timeout)) {
            Ok(event) => event.map(Some),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Err(GadgetException::new(GadgetErrorKind::Disconnected, "the function is closed"))
            }
        }
    }

    fn reply(&self, id: u32, action: Action) -> Result<Outcome, GadgetException> {
        let closed = || GadgetException::new(GadgetErrorKind::Disconnected, "the function is closed");
        let (done, result) = mpsc::channel();
        self.thread.replies.send(Reply { id, action, done }).map_err(|_| closed())?;
        // The thread answers within REPLY_TIMEOUT plus one poll, even for a
        // stale id; the margin covers the transfer itself.
        match result.recv_timeout(REPLY_TIMEOUT * 2) {
            Ok(outcome) => outcome,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                Err(GadgetException::new(GadgetErrorKind::TimedOut, "no answer from the event thread"))
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(closed()),
        }
    }

    /// Answers device-to-host request [id] with [data]; returns the number
    /// of bytes sent.
    #[frb(positional)]
    pub fn reply_send(&self, id: u32, data: Vec<u8>) -> Result<u32, GadgetException> {
        match self.reply(id, Action::Send(data))? {
            Outcome::Sent(n) => Ok(n as u32),
            _ => unreachable!(),
        }
    }

    /// Accepts host-to-device request [id] and returns its data.
    #[frb(positional)]
    pub fn reply_receive(&self, id: u32) -> Result<Vec<u8>, GadgetException> {
        match self.reply(id, Action::Receive)? {
            Outcome::Received(data) => Ok(data),
            _ => unreachable!(),
        }
    }

    /// Rejects request [id] by stalling the control endpoint.
    #[frb(positional)]
    pub fn reply_halt(&self, id: u32) -> Result<(), GadgetException> {
        self.reply(id, Action::Halt).map(|_| ())
    }
}
