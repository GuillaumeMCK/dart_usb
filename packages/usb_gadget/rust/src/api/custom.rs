//! Custom functions implemented in Dart through FunctionFS.
//!
//! The crate answers a control request through a value that borrows the
//! function until the reply is sent, which can't cross into Dart. So each
//! function's events are read by a Rust thread (the pump): it forwards each
//! event to Dart and, for a control request, waits for Dart's reply before
//! reading the next event.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use flutter_rust_bridge::frb;
use usb_gadget::function::custom;

use super::endpoint::{EndpointReceiver, EndpointSender};
use super::error::{GadgetErrorKind, GadgetException};
use super::function::FunctionState;
use super::gadget::FunctionHandle;
use super::{localized, path_string, std_duration, ClassCodes, LocalizedString};

/// How long a control request waits for Dart's reply before it is stalled.
/// Hosts give up after 5 seconds.
const REPLY_TIMEOUT: Duration = Duration::from_millis(4500);

/// How often blocked waits check whether they were stopped.
const POLL: Duration = Duration::from_millis(100);

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
    fn simple(kind: CustomEventKind) -> Self {
        CustomEvent { kind, id: 0, setup: Vec::new(), code: 0 }
    }
}

enum Action {
    Send(Vec<u8>),
    Receive,
    Halt,
}

enum Outcome {
    Sent(usize),
    Received(Vec<u8>),
    Halted,
}

struct Reply {
    id: u32,
    action: Action,
    done: mpsc::Sender<Result<Outcome, GadgetException>>,
}

struct Pump {
    events: Mutex<mpsc::Receiver<Result<CustomEvent, GadgetException>>>,
    replies: mpsc::Sender<Reply>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Pump {
    fn start(custom: Arc<Mutex<custom::Custom>>) -> Pump {
        let (events_tx, events_rx) = mpsc::channel();
        let (replies_tx, replies_rx) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let stop = stop.clone();
            std::thread::Builder::new()
                .name("usb_gadget events".into())
                .spawn(move || run_pump(&custom, &events_tx, &replies_rx, &stop))
                .expect("spawning the event thread")
        };
        Pump { events: Mutex::new(events_rx), replies: replies_tx, stop, thread: Some(thread) }
    }
}

impl Drop for Pump {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn setup_bytes(r: &custom::CtrlReq) -> Vec<u8> {
    let mut b = vec![r.request_type, r.request];
    b.extend_from_slice(&r.value.to_le_bytes());
    b.extend_from_slice(&r.index.to_le_bytes());
    b.extend_from_slice(&r.length.to_le_bytes());
    b
}

/// Waits for Dart's reply to request [id]; none if it timed out or the pump
/// is stopping.
fn wait_reply(replies: &mpsc::Receiver<Reply>, id: u32, stop: &AtomicBool) -> Option<Reply> {
    let deadline = Instant::now() + REPLY_TIMEOUT;
    while !stop.load(Ordering::Relaxed) {
        let left = deadline.checked_duration_since(Instant::now())?;
        match replies.recv_timeout(left.min(POLL)) {
            Ok(reply) if reply.id == id => return Some(reply),
            Ok(stale) => {
                let _ = stale.done.send(Err(GadgetException::new(
                    GadgetErrorKind::TimedOut,
                    "the control request was already stalled",
                )));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return None,
        }
    }
    None
}

fn wrong_direction() -> GadgetException {
    GadgetException::new(GadgetErrorKind::InvalidInput, "wrong reply for this control request's direction")
}

fn run_pump(
    custom: &Mutex<custom::Custom>,
    events: &mpsc::Sender<Result<CustomEvent, GadgetException>>,
    replies: &mpsc::Receiver<Reply>,
    stop: &AtomicBool,
) {
    let mut next_id = 0u32;
    while !stop.load(Ordering::Relaxed) {
        let mut function = custom.lock().unwrap();
        let keep_going = match function.event_timeout(POLL) {
            Ok(Some(event)) => dispatch(event, events, replies, stop, &mut next_id),
            Ok(None) => true,
            // FunctionFS isn't mounted until the gadget is registered.
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(POLL);
                true
            }
            Err(e) => {
                let _ = events.send(Err(e.into()));
                false
            }
        };
        if !keep_going {
            return;
        }
    }
}

/// Forwards [event] to Dart, and answers control requests with Dart's
/// reply. Returns false once Dart stopped listening.
fn dispatch(
    event: custom::Event<'_>,
    events: &mpsc::Sender<Result<CustomEvent, GadgetException>>,
    replies: &mpsc::Receiver<Reply>,
    stop: &AtomicBool,
    next_id: &mut u32,
) -> bool {
    let simple = |kind| events.send(Ok(CustomEvent::simple(kind))).is_ok();
    match event {
        custom::Event::Bind => simple(CustomEventKind::Bind),
        custom::Event::Unbind => simple(CustomEventKind::Unbind),
        custom::Event::Enable => simple(CustomEventKind::Enable),
        custom::Event::Disable => simple(CustomEventKind::Disable),
        custom::Event::Suspend => simple(CustomEventKind::Suspend),
        custom::Event::Resume => simple(CustomEventKind::Resume),
        custom::Event::SetupDeviceToHost(sender) => {
            *next_id = next_id.wrapping_add(1);
            let event = CustomEvent {
                kind: CustomEventKind::SetupDeviceToHost,
                id: *next_id,
                setup: setup_bytes(sender.ctrl_req()),
                code: 0,
            };
            if events.send(Ok(event)).is_err() {
                return false;
            }
            match wait_reply(replies, *next_id, stop) {
                Some(Reply { action: Action::Send(data), done, .. }) => {
                    let _ = done.send(sender.send(&data).map(Outcome::Sent).map_err(Into::into));
                }
                Some(Reply { action: Action::Halt, done, .. }) => {
                    let _ = done.send(sender.halt().map(|_| Outcome::Halted).map_err(Into::into));
                }
                Some(Reply { action: Action::Receive, done, .. }) => {
                    let _ = sender.halt();
                    let _ = done.send(Err(wrong_direction()));
                }
                None => {
                    let _ = sender.halt();
                }
            }
            true
        }
        custom::Event::SetupHostToDevice(receiver) => {
            *next_id = next_id.wrapping_add(1);
            let event = CustomEvent {
                kind: CustomEventKind::SetupHostToDevice,
                id: *next_id,
                setup: setup_bytes(receiver.ctrl_req()),
                code: 0,
            };
            if events.send(Ok(event)).is_err() {
                return false;
            }
            match wait_reply(replies, *next_id, stop) {
                Some(Reply { action: Action::Receive, done, .. }) => {
                    let _ = done.send(receiver.recv_all().map(Outcome::Received).map_err(Into::into));
                }
                Some(Reply { action: Action::Halt, done, .. }) => {
                    let _ = done.send(receiver.halt().map(|_| Outcome::Halted).map_err(Into::into));
                }
                Some(Reply { action: Action::Send(_), done, .. }) => {
                    let _ = receiver.halt();
                    let _ = done.send(Err(wrong_direction()));
                }
                None => {
                    let _ = receiver.halt();
                }
            }
            true
        }
        custom::Event::Unknown(code) => {
            events.send(Ok(CustomEvent { code, ..CustomEvent::simple(CustomEventKind::Unknown) })).is_ok()
        }
        _ => true,
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
    custom: Arc<Mutex<custom::Custom>>,
    status: Option<usb_gadget::function::util::Status>,
    endpoints: Mutex<Vec<Option<EndpointIo>>>,
    pump: Mutex<Option<Pump>>,
}

impl CustomFunction {
    /// Builds the function. Its endpoints, in declaration order across
    /// interfaces, are taken with [take_sender] and [take_receiver].
    #[frb(sync)]
    pub fn new(spec: CustomSpec) -> Result<CustomFunction, GadgetException> {
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
            custom: Arc::new(Mutex::new(custom)),
            endpoints: Mutex::new(endpoints),
            pump: Mutex::new(None),
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

    /// The address the host sees for interface number [interface] of this
    /// function. Available once bound.
    #[frb(positional)]
    pub fn real_interface_number(&self, interface: u8) -> Result<u8, GadgetException> {
        Ok(self.custom.lock().unwrap().real_address(interface)?)
    }

    /// Where FunctionFS is mounted. Available once registered.
    pub fn ffs_dir(&self) -> Result<String, GadgetException> {
        Ok(path_string(self.custom.lock().unwrap().ffs_dir()?))
    }

    /// The next event, waiting up to [timeout]; none if it elapses. Starts
    /// reading events on first call.
    #[frb(positional)]
    pub fn next_event(&self, timeout: chrono::Duration) -> Result<Option<CustomEvent>, GadgetException> {
        let mut pump = self.pump.lock().unwrap();
        let pump = pump.get_or_insert_with(|| Pump::start(self.custom.clone()));
        let events = pump.events.lock().unwrap();
        match events.recv_timeout(std_duration(timeout)) {
            Ok(event) => event.map(Some),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Err(GadgetException::new(GadgetErrorKind::Disconnected, "event reading stopped"))
            }
        }
    }

    /// Stops reading events. Pending control requests are stalled.
    #[frb(sync)]
    pub fn stop_events(&self) {
        self.pump.lock().unwrap().take();
    }

    fn reply(&self, id: u32, action: Action) -> Result<Outcome, GadgetException> {
        let replies = match self.pump.lock().unwrap().as_ref() {
            Some(pump) => pump.replies.clone(),
            None => return Err(GadgetException::new(GadgetErrorKind::Disconnected, "event reading stopped")),
        };
        let (done, result) = mpsc::channel();
        replies
            .send(Reply { id, action, done })
            .map_err(|_| GadgetException::new(GadgetErrorKind::Disconnected, "event reading stopped"))?;
        result
            .recv()
            .map_err(|_| GadgetException::new(GadgetErrorKind::TimedOut, "the control request was already stalled"))?
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

impl Drop for CustomFunction {
    fn drop(&mut self) {
        // Stop the pump before the function's files close.
        self.pump.get_mut().unwrap().take();
    }
}
