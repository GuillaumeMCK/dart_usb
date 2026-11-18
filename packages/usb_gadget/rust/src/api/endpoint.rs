//! Data endpoints of custom functions, using the crate's asynchronous IO:
//! several transfers are queued in the kernel at once.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use bytes::{Bytes, BytesMut};
use flutter_rust_bridge::frb;
use usb_gadget::function::custom;

use super::error::{GadgetErrorKind, GadgetException};
use super::std_duration;

/// How often blocked waits check for cancellation.
const SLICE: Duration = Duration::from_millis(50);

/// Polls [step] in [SLICE]s until it yields, [deadline] passes, or [cancel]
/// moves past [generation].
fn wait<T>(
    cancel: &AtomicU64,
    generation: u64,
    timeout: Option<chrono::Duration>,
    mut step: impl FnMut(Duration) -> std::io::Result<Option<T>>,
) -> Result<T, GadgetException> {
    let deadline = timeout.map(|t| Instant::now() + std_duration(t));
    loop {
        if cancel.load(Ordering::Acquire) != generation {
            return Err(GadgetException::new(GadgetErrorKind::Cancelled, "cancelled"));
        }
        let slice = match deadline {
            Some(d) => match d.checked_duration_since(Instant::now()) {
                Some(left) => left.min(SLICE),
                None => return Err(GadgetException::new(GadgetErrorKind::TimedOut, "timed out")),
            },
            None => SLICE,
        };
        if let Some(value) = step(slice)? {
            return Ok(value);
        }
    }
}

fn timed_out(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::TimedOut
}

/// The device-to-host side of an IN endpoint.
#[frb(opaque)]
pub struct EndpointSender {
    inner: Mutex<custom::EndpointSender>,
    cancel: AtomicU64,
}

impl EndpointSender {
    pub(crate) fn new(inner: custom::EndpointSender) -> Self {
        EndpointSender { inner: Mutex::new(inner), cancel: AtomicU64::new(0) }
    }

    /// Queues [data] for sending, first waiting up to [timeout] for queue
    /// space. Completion is reported by [flush].
    #[frb(positional)]
    pub fn send(&self, data: Vec<u8>, timeout: Option<chrono::Duration>) -> Result<(), GadgetException> {
        let generation = self.cancel.load(Ordering::Acquire);
        let mut ep = self.inner.lock().unwrap();
        wait(&self.cancel, generation, timeout, |slice| match ep.ready_timeout(slice) {
            Ok(()) => Ok(Some(())),
            Err(e) if timed_out(&e) => Ok(None),
            Err(e) => Err(e),
        })?;
        Ok(ep.try_send(Bytes::from(data))?)
    }

    /// Waits up to [timeout] for every queued transfer to complete. On
    /// timeout or cancellation the queued transfers are cancelled.
    #[frb(positional)]
    pub fn flush(&self, timeout: Option<chrono::Duration>) -> Result<(), GadgetException> {
        let generation = self.cancel.load(Ordering::Acquire);
        let mut ep = self.inner.lock().unwrap();
        let result = wait(&self.cancel, generation, timeout, |slice| match ep.flush_timeout(slice) {
            Ok(()) => Ok(Some(())),
            Err(e) if timed_out(&e) => Ok(None),
            Err(e) => Err(e),
        });
        if result.is_err() {
            let _ = ep.cancel();
        }
        result
    }

    /// Cancels pending [send] and [flush] calls and queued transfers.
    #[frb(sync)]
    pub fn cancel(&self) {
        self.cancel.fetch_add(1, Ordering::AcqRel);
        if let Ok(mut ep) = self.inner.try_lock() {
            let _ = ep.cancel();
        }
    }

    /// Maximum packet size negotiated with the host.
    pub fn max_packet_size(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().unwrap().max_packet_size()? as u32)
    }

    /// Stalls the endpoint.
    pub fn halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.halt()?)
    }

    /// Clears a stall.
    pub fn clear_halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.clear_halt()?)
    }

    /// The endpoint address the host sees.
    pub fn real_address(&self) -> Result<u8, GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.real_address()?)
    }

    /// Bytes written but not yet sent by the controller.
    pub fn unclaimed_fifo(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.unclaimed_fifo()? as u32)
    }

    /// Discards bytes written but not yet sent.
    pub fn discard_fifo(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.discard_fifo()?)
    }
}

/// The host-to-device side of an OUT endpoint.
#[frb(opaque)]
pub struct EndpointReceiver {
    inner: Mutex<custom::EndpointReceiver>,
    cancel: AtomicU64,
}

impl EndpointReceiver {
    pub(crate) fn new(inner: custom::EndpointReceiver) -> Self {
        EndpointReceiver { inner: Mutex::new(inner), cancel: AtomicU64::new(0) }
    }

    /// Returns the next completed transfer, waiting up to [timeout].
    ///
    /// Buffers of [capacity] bytes (a multiple of the max packet size) are
    /// queued first: one if none is, or as many as fit when [fill_queue] is
    /// set, which keeps the endpoint busy while Dart processes data. A
    /// timeout leaves queued buffers in place for the next call;
    /// cancellation cancels them.
    #[frb(positional)]
    pub fn receive(
        &self,
        capacity: u32,
        fill_queue: bool,
        timeout: Option<chrono::Duration>,
    ) -> Result<Vec<u8>, GadgetException> {
        let generation = self.cancel.load(Ordering::Acquire);
        let mut ep = self.inner.lock().unwrap();
        if fill_queue {
            while ep.is_ready() {
                ep.try_recv(BytesMut::with_capacity(capacity as usize))?;
            }
        } else if ep.is_empty() {
            ep.try_recv(BytesMut::with_capacity(capacity as usize))?;
        }
        let result = wait(&self.cancel, generation, timeout, |slice| Ok(ep.fetch_timeout(slice)?.map(Vec::from)));
        if matches!(&result, Err(e) if e.kind == GadgetErrorKind::Cancelled) {
            let _ = ep.cancel();
        }
        result
    }

    /// Cancels a pending [receive] and the queued buffers.
    #[frb(sync)]
    pub fn cancel(&self) {
        self.cancel.fetch_add(1, Ordering::AcqRel);
        if let Ok(mut ep) = self.inner.try_lock() {
            let _ = ep.cancel();
        }
    }

    /// Maximum packet size negotiated with the host.
    pub fn max_packet_size(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().unwrap().max_packet_size()? as u32)
    }

    /// Stalls the endpoint.
    pub fn halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.halt()?)
    }

    /// Clears a stall.
    pub fn clear_halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.clear_halt()?)
    }

    /// The endpoint address the host sees.
    pub fn real_address(&self) -> Result<u8, GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.real_address()?)
    }

    /// Bytes received but not yet read.
    pub fn unclaimed_fifo(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.unclaimed_fifo()? as u32)
    }

    /// Discards bytes received but not yet read.
    pub fn discard_fifo(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().unwrap().control()?.discard_fifo()?)
    }
}
