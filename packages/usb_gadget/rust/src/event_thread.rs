//! The thread that owns a custom function.
//!
//! The crate answers a control request through a value that mutably borrows
//! the function until the answer is sent, so nothing else may touch the
//! function meanwhile, and the answer has to come from Dart. One thread per
//! function therefore owns it outright: it reads events, forwards them to
//! Dart, applies Dart's answers, and publishes what Dart may ask about (the
//! mount path, real interface numbers) in [Info]. Dart never waits on a lock
//! this thread holds; everything crosses through channels.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use usb_gadget::function::custom::{self, Custom};

use crate::api::custom::{CustomEvent, CustomEventKind};
use crate::api::error::{GadgetErrorKind, GadgetException};

/// How long a control request waits for Dart's answer before it is stalled.
/// Hosts give up after 5 seconds.
pub(crate) const REPLY_TIMEOUT: Duration = Duration::from_millis(4500);

/// How often the thread checks for stop requests and stale answers.
const POLL: Duration = Duration::from_millis(100);

pub(crate) enum Action {
    Send(Vec<u8>),
    Receive,
    Halt,
}

pub(crate) enum Outcome {
    Sent(usize),
    Received(Vec<u8>),
    Halted,
}

/// Dart's answer to control request [id].
pub(crate) struct Reply {
    pub id: u32,
    pub action: Action,
    pub done: mpsc::Sender<Result<Outcome, GadgetException>>,
}

/// What Dart may read without involving the thread.
#[derive(Default)]
pub(crate) struct Info {
    /// FunctionFS mount point, once registered.
    pub ffs_dir: Option<PathBuf>,
    /// Interface number the host sees, per interface of the function, once
    /// bound.
    pub interface_numbers: Vec<Option<u8>>,
}

pub(crate) struct Shared {
    /// Whether Dart is listening; control requests nobody listens to are
    /// stalled at once instead of after [REPLY_TIMEOUT].
    pub listening: AtomicBool,
    pub stop: AtomicBool,
    pub info: Mutex<Info>,
}

/// Handle to the thread. Dropping it stops the thread, which then drops the
/// function (closing its files) within [POLL]; nothing waits for that.
pub(crate) struct EventThread {
    /// Read by Dart's single event poller.
    pub events: Mutex<mpsc::Receiver<Result<CustomEvent, GadgetException>>>,
    pub replies: mpsc::Sender<Reply>,
    pub shared: Arc<Shared>,
}

impl EventThread {
    pub fn spawn(custom: Custom, interfaces: usize) -> std::io::Result<Self> {
        let (events_tx, events_rx) = mpsc::channel();
        let (replies_tx, replies_rx) = mpsc::channel();
        let shared = Arc::new(Shared {
            listening: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            info: Mutex::new(Info { ffs_dir: None, interface_numbers: vec![None; interfaces] }),
        });
        let thread = Pump { custom, events: events_tx, replies: replies_rx, shared: shared.clone(), next_id: 0 };
        std::thread::Builder::new().name("usb_gadget events".into()).spawn(move || thread.run())?;
        Ok(EventThread { events: Mutex::new(events_rx), replies: replies_tx, shared })
    }
}

impl Drop for EventThread {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
    }
}

struct Pump {
    custom: Custom,
    events: mpsc::Sender<Result<CustomEvent, GadgetException>>,
    replies: mpsc::Receiver<Reply>,
    shared: Arc<Shared>,
    next_id: u32,
}

fn stale(reply: Reply) {
    let _ = reply.done.send(Err(GadgetException::new(
        GadgetErrorKind::TimedOut,
        "the control request was already answered or stalled",
    )));
}

fn wrong_direction() -> GadgetException {
    GadgetException::new(GadgetErrorKind::InvalidInput, "wrong answer for this control request's direction")
}

impl Pump {
    fn stopped(&self) -> bool {
        self.shared.stop.load(Ordering::Relaxed)
    }

    fn run(mut self) {
        while !self.stopped() {
            // Answers that arrive after their request was stalled fail here
            // promptly, instead of waiting for the next request.
            while let Ok(reply) = self.replies.try_recv() {
                stale(reply);
            }
            let keep_going = match self.custom.event_timeout(POLL) {
                Ok(Some(event)) => {
                    dispatch(event, &self.events, &self.replies, &self.shared, &mut self.next_id)
                }
                Ok(None) => true,
                // FunctionFS isn't mounted until the gadget is registered.
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(POLL);
                    true
                }
                Err(e) => {
                    let _ = self.events.send(Err(e.into()));
                    false
                }
            };
            if !keep_going {
                return;
            }
            self.refresh_info();
        }
    }

    /// Fills in [Info] as it becomes available: the mount path once
    /// registered, interface numbers once bound.
    fn refresh_info(&mut self) {
        let mut info = self.shared.info.lock().unwrap();
        if info.ffs_dir.is_none() {
            info.ffs_dir = self.custom.ffs_dir().ok();
        }
        for (i, number) in info.interface_numbers.iter_mut().enumerate() {
            if number.is_none() {
                *number = self.custom.real_address(i as u8).ok();
            }
        }
    }
}

/// Waits for Dart's answer to request [id]; none if it timed out or the
/// thread is stopping.
fn wait_reply(replies: &mpsc::Receiver<Reply>, id: u32, shared: &Shared) -> Option<Reply> {
    let deadline = Instant::now() + REPLY_TIMEOUT;
    while !shared.stop.load(Ordering::Relaxed) {
        let left = deadline.checked_duration_since(Instant::now())?;
        match replies.recv_timeout(left.min(POLL)) {
            Ok(reply) if reply.id == id => return Some(reply),
            Ok(other) => stale(other),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return None,
        }
    }
    None
}

fn setup_bytes(r: &custom::CtrlReq) -> Vec<u8> {
    let mut b = vec![r.request_type, r.request];
    b.extend_from_slice(&r.value.to_le_bytes());
    b.extend_from_slice(&r.index.to_le_bytes());
    b.extend_from_slice(&r.length.to_le_bytes());
    b
}

/// Forwards [event] to Dart and, for a control request, applies Dart's
/// answer. A free function so the event's borrow of the function doesn't
/// conflict with the thread's other fields. Returns false once Dart is gone.
fn dispatch(
    event: custom::Event<'_>,
    events: &mpsc::Sender<Result<CustomEvent, GadgetException>>,
    replies: &mpsc::Receiver<Reply>,
    shared: &Shared,
    next_id: &mut u32,
) -> bool {
    let simple = |kind| events.send(Ok(CustomEvent::simple(kind))).is_ok();
    let listening = shared.listening.load(Ordering::Relaxed);
    let mut forward = |kind, setup: &custom::CtrlReq| {
        *next_id = next_id.wrapping_add(1);
        let event = CustomEvent { kind, id: *next_id, setup: setup_bytes(setup), code: 0 };
        events.send(Ok(event)).map(|_| *next_id)
    };
    match event {
        custom::Event::Bind => simple(CustomEventKind::Bind),
        custom::Event::Unbind => simple(CustomEventKind::Unbind),
        custom::Event::Enable => simple(CustomEventKind::Enable),
        custom::Event::Disable => simple(CustomEventKind::Disable),
        custom::Event::Suspend => simple(CustomEventKind::Suspend),
        custom::Event::Resume => simple(CustomEventKind::Resume),
        custom::Event::SetupDeviceToHost(sender) => {
            if !listening {
                let _ = sender.halt();
                return true;
            }
            let Ok(id) = forward(CustomEventKind::SetupDeviceToHost, sender.ctrl_req()) else { return false };
            match wait_reply(replies, id, shared) {
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
            if !listening {
                let _ = receiver.halt();
                return true;
            }
            let Ok(id) = forward(CustomEventKind::SetupHostToDevice, receiver.ctrl_req()) else { return false };
            match wait_reply(replies, id, shared) {
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
