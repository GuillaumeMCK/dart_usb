//! Data endpoints of custom functions, using the crate's asynchronous IO:
//! several transfers are queued in the kernel at once. Waits are
//! interruptible and share the endpoint fairly; see `crate::wait`.

use bytes::{Bytes, BytesMut};
use flutter_rust_bridge::frb;
use parking_lot::Mutex;
use usb_gadget::function::custom;

use super::error::{GadgetErrorKind, GadgetException};
use super::std_duration;
use crate::wait::{timed_out, wait, Cancel, WaitError};

/// The device-to-host side of an IN endpoint.
#[frb(opaque)]
pub struct EndpointSender {
    inner: Mutex<custom::EndpointSender>,
    cancel: Cancel,
}

impl EndpointSender {
    pub(crate) fn new(inner: custom::EndpointSender) -> Self {
        EndpointSender { inner: Mutex::new(inner), cancel: Cancel::default() }
    }

    /// Queues [data] for sending, first waiting up to [timeout] for queue
    /// space. Completion is reported by [flush].
    #[frb(positional)]
    pub fn send(&self, data: Vec<u8>, timeout: Option<chrono::Duration>) -> Result<(), GadgetException> {
        let generation = self.cancel.generation();
        let mut data = Some(Bytes::from(data));
        Ok(wait(&self.inner, &self.cancel, generation, timeout.map(std_duration), |ep, slice| {
            match ep.ready_timeout(slice) {
                // Enqueue in the same slice, so no other writer takes the space.
                Ok(()) => ep.try_send(data.take().unwrap_or_default()).map(Some),
                Err(e) if timed_out(&e) => Ok(None),
                Err(e) => Err(e),
            }
        })?)
    }

    /// Waits up to [timeout] for every queued transfer to complete. On
    /// timeout or cancellation the queued transfers are cancelled.
    #[frb(positional)]
    pub fn flush(&self, timeout: Option<chrono::Duration>) -> Result<(), GadgetException> {
        let generation = self.cancel.generation();
        let result = wait(&self.inner, &self.cancel, generation, timeout.map(std_duration), |ep, slice| {
            match ep.flush_timeout(slice) {
                Ok(()) => Ok(Some(())),
                Err(e) if timed_out(&e) => Ok(None),
                Err(e) => Err(e),
            }
        });
        if result.is_err() {
            let _ = self.inner.lock().cancel();
        }
        Ok(result?)
    }

    /// Cancels pending [send] and [flush] calls and queued transfers.
    #[frb(sync)]
    pub fn cancel(&self) {
        self.cancel.cancel();
        if let Some(mut ep) = self.inner.try_lock() {
            let _ = ep.cancel();
        }
    }

    /// Maximum packet size negotiated with the host.
    pub fn max_packet_size(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().max_packet_size()? as u32)
    }

    /// Stalls the endpoint.
    pub fn halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().control()?.halt()?)
    }

    /// Clears a stall.
    pub fn clear_halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().control()?.clear_halt()?)
    }

    /// The endpoint address the host sees.
    pub fn real_address(&self) -> Result<u8, GadgetException> {
        Ok(self.inner.lock().control()?.real_address()?)
    }

    /// Bytes written but not yet sent by the controller.
    pub fn unclaimed_fifo(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().control()?.unclaimed_fifo()? as u32)
    }

    /// Discards bytes written but not yet sent.
    pub fn discard_fifo(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().control()?.discard_fifo()?)
    }
}

/// The host-to-device side of an OUT endpoint.
#[frb(opaque)]
pub struct EndpointReceiver {
    inner: Mutex<custom::EndpointReceiver>,
    cancel: Cancel,
}

impl EndpointReceiver {
    pub(crate) fn new(inner: custom::EndpointReceiver) -> Self {
        EndpointReceiver { inner: Mutex::new(inner), cancel: Cancel::default() }
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
        if capacity == 0 {
            return Err(GadgetException::new(GadgetErrorKind::InvalidInput, "capacity must be positive"));
        }
        let buffer = || BytesMut::with_capacity(capacity as usize);
        let generation = self.cancel.generation();
        {
            let mut ep = self.inner.lock();
            if fill_queue {
                while ep.is_ready() {
                    ep.try_recv(buffer())?;
                }
            } else if ep.is_empty() {
                ep.try_recv(buffer())?;
            }
        }
        let result = wait(&self.inner, &self.cancel, generation, timeout.map(std_duration), |ep, slice| {
            // Another reader may have drained the queue meanwhile; never wait
            // on an empty one.
            if ep.is_empty() {
                ep.try_recv(buffer())?;
            }
            Ok(ep.fetch_timeout(slice)?.map(Vec::from))
        });
        if matches!(result, Err(WaitError::Cancelled)) {
            let _ = self.inner.lock().cancel();
        }
        Ok(result?)
    }

    /// Cancels a pending [receive] and the queued buffers.
    #[frb(sync)]
    pub fn cancel(&self) {
        self.cancel.cancel();
        if let Some(mut ep) = self.inner.try_lock() {
            let _ = ep.cancel();
        }
    }

    /// Maximum packet size negotiated with the host.
    pub fn max_packet_size(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().max_packet_size()? as u32)
    }

    /// Stalls the endpoint.
    pub fn halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().control()?.halt()?)
    }

    /// Clears a stall.
    pub fn clear_halt(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().control()?.clear_halt()?)
    }

    /// The endpoint address the host sees.
    pub fn real_address(&self) -> Result<u8, GadgetException> {
        Ok(self.inner.lock().control()?.real_address()?)
    }

    /// Bytes received but not yet read.
    pub fn unclaimed_fifo(&self) -> Result<u32, GadgetException> {
        Ok(self.inner.lock().control()?.unclaimed_fifo()? as u32)
    }

    /// Discards bytes received but not yet read.
    pub fn discard_fifo(&self) -> Result<(), GadgetException> {
        Ok(self.inner.lock().control()?.discard_fifo()?)
    }
}
