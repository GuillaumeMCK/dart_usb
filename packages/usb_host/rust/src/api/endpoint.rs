//! Bulk and interrupt endpoints, and nusb's buffered reader and writer.
//!
//! nusb's endpoints are generic over their type; each wrapper holds one of
//! the concrete types in a private enum.
//!
//! Methods taking `&mut self` lock the endpoint while they run, so a long
//! wait blocks other calls on the same endpoint (including `cancelAll`).
//! Use timeouts to bound waits.

use std::io::{BufRead, Read, Write};
use chrono::Duration;

use flutter_rust_bridge::frb;
use nusb::io::{EndpointRead, EndpointWrite};
use nusb::transfer::{Buffer, Bulk, Completion, In, Interrupt, Out};
use nusb::Endpoint;

use super::error::UsbException;

pub(crate) enum InKind {
    Bulk(Endpoint<Bulk, In>),
    Interrupt(Endpoint<Interrupt, In>),
}

pub(crate) enum OutKind {
    Bulk(Endpoint<Bulk, Out>),
    Interrupt(Endpoint<Interrupt, Out>),
}

/// Runs the same code on whichever concrete endpoint type is inside.
macro_rules! each {
    ($kind:ident, $value:expr, |$ep:ident| $body:expr) => {
        match $value {
            $kind::Bulk($ep) => $body,
            $kind::Interrupt($ep) => $body,
        }
    };
}

fn wait_for(timeout: Option<Duration>) -> std::time::Duration {
    timeout.map_or(std::time::Duration::MAX, super::types::std_duration)
}

/// A completed IN transfer.
#[frb(dart_code = r#"
  @override
  String toString() => 'InCompletion(${data.length} bytes${error == null ? '' : ', $error'})';
"#)]
pub struct InCompletion {
    /// The bytes received, possibly fewer than requested.
    pub data: Vec<u8>,
    /// Set if the transfer failed; [data] may still hold a partial transfer.
    pub error: Option<UsbException>,
}

impl From<Completion> for InCompletion {
    fn from(c: Completion) -> Self {
        InCompletion { error: c.status.err().map(Into::into), data: c.buffer.into_vec() }
    }
}

/// A completed OUT transfer.
#[frb(dart_code = r#"
  @override
  String toString() => 'OutCompletion($actualLength bytes${error == null ? '' : ', $error'})';
"#)]
pub struct OutCompletion {
    pub actual_length: u32,
    pub error: Option<UsbException>,
}

impl From<Completion> for OutCompletion {
    fn from(c: Completion) -> Self {
        OutCompletion { actual_length: c.actual_len as u32, error: c.status.err().map(Into::into) }
    }
}

/// A bulk or interrupt IN (device-to-host) endpoint.
///
/// Submit transfers with [submit] and collect them in order with
/// [nextComplete]; keeping several in flight gives full throughput. For
/// one-off reads use [transfer], and for a buffered stream use [reader].
#[frb(opaque)]
pub struct InEndpoint(pub(crate) InKind);

impl InEndpoint {
    #[frb(sync, getter)]
    pub fn address(&self) -> u8 {
        each!(InKind, &self.0, |ep| ep.endpoint_address())
    }

    #[frb(sync, getter)]
    pub fn max_packet_size(&self) -> u32 {
        each!(InKind, &self.0, |ep| ep.max_packet_size() as u32)
    }

    /// Transfers submitted and not yet returned by [nextComplete].
    #[frb(sync, getter)]
    pub fn pending(&self) -> u32 {
        each!(InKind, &self.0, |ep| ep.pending() as u32)
    }

    /// Starts a transfer of [length] bytes, which must be a nonzero multiple
    /// of [maxPacketSize]. Does not wait.
    #[frb(sync, positional)]
    pub fn submit(&mut self, length: u32) {
        each!(InKind, &mut self.0, |ep| {
            let buf = ep.allocate(length as usize);
            ep.submit(buf)
        })
    }

    /// Waits for the next transfer to complete, or returns `null` after
    /// [timeout] (the transfer stays pending). Waits forever if [timeout] is
    /// `null`. Throws if nothing is pending.
    pub fn next_complete(&mut self, timeout: Option<Duration>) -> Result<Option<InCompletion>, UsbException> {
        each!(InKind, &mut self.0, |ep| {
            if ep.pending() == 0 {
                return Err(no_pending());
            }
            Ok(ep.wait_next_complete(wait_for(timeout)).map(Into::into))
        })
    }

    /// Reads one transfer of up to [length] bytes, cancelling it after
    /// [timeout] (or waiting forever if `null`). No other transfer may be
    /// pending.
    pub fn transfer(&mut self, length: u32, timeout: Option<Duration>) -> Result<Vec<u8>, UsbException> {
        each!(InKind, &mut self.0, |ep| {
            if ep.pending() != 0 {
                return Err(UsbException::new(super::error::UsbErrorKind::Busy, "a transfer is already pending"));
            }
            Ok(ep.transfer_blocking(Buffer::new(length as usize), wait_for(timeout)).into_result()?.into_vec())
        })
    }

    /// Requests cancellation of all pending transfers. They still complete,
    /// with a `transferCancelled` error.
    #[frb(sync)]
    pub fn cancel_all(&mut self) {
        each!(InKind, &mut self.0, |ep| ep.cancel_all())
    }

    /// Clears a halt (stall) condition. No transfers may be pending.
    pub fn clear_halt(&mut self) -> Result<(), UsbException> {
        each!(InKind, &mut self.0, |ep| Ok(nusb::MaybeFuture::wait(ep.clear_halt())?))
    }

    /// Turns the endpoint into a buffered [EndpointReader] with
    /// [numTransfers] (default 1) transfers of [transferSize] bytes in
    /// flight; more transfers give more throughput. Reads time out after
    /// [readTimeout], or never if `null`.
    #[frb(sync)]
    pub fn reader(self, transfer_size: u32, num_transfers: Option<u32>, read_timeout: Option<Duration>) -> EndpointReader {
        let size = transfer_size as usize;
        let n = num_transfers.unwrap_or(1).max(1) as usize;
        let timeout = wait_for(read_timeout);
        EndpointReader(match self.0 {
            InKind::Bulk(ep) => ReaderKind::Bulk(ep.reader(size).with_num_transfers(n).with_read_timeout(timeout)),
            InKind::Interrupt(ep) => {
                ReaderKind::Interrupt(ep.reader(size).with_num_transfers(n).with_read_timeout(timeout))
            }
        })
    }
}

/// A bulk or interrupt OUT (host-to-device) endpoint.
#[frb(opaque)]
pub struct OutEndpoint(pub(crate) OutKind);

impl OutEndpoint {
    #[frb(sync, getter)]
    pub fn address(&self) -> u8 {
        each!(OutKind, &self.0, |ep| ep.endpoint_address())
    }

    #[frb(sync, getter)]
    pub fn max_packet_size(&self) -> u32 {
        each!(OutKind, &self.0, |ep| ep.max_packet_size() as u32)
    }

    /// Transfers submitted and not yet returned by [nextComplete].
    #[frb(sync, getter)]
    pub fn pending(&self) -> u32 {
        each!(OutKind, &self.0, |ep| ep.pending() as u32)
    }

    /// Starts sending [data]. Does not wait.
    #[frb(sync, positional)]
    pub fn submit(&mut self, data: Vec<u8>) {
        each!(OutKind, &mut self.0, |ep| ep.submit(data.into()))
    }

    /// Waits for the next transfer to complete, or returns `null` after
    /// [timeout] (the transfer stays pending). Waits forever if [timeout] is
    /// `null`. Throws if nothing is pending.
    pub fn next_complete(&mut self, timeout: Option<Duration>) -> Result<Option<OutCompletion>, UsbException> {
        each!(OutKind, &mut self.0, |ep| {
            if ep.pending() == 0 {
                return Err(no_pending());
            }
            Ok(ep.wait_next_complete(wait_for(timeout)).map(Into::into))
        })
    }

    /// Sends [data] in one transfer, cancelling it after [timeout] (or
    /// waiting forever if `null`). Returns the number of bytes sent. No other
    /// transfer may be pending.
    pub fn transfer(&mut self, data: Vec<u8>, timeout: Option<Duration>) -> Result<u32, UsbException> {
        each!(OutKind, &mut self.0, |ep| {
            if ep.pending() != 0 {
                return Err(UsbException::new(super::error::UsbErrorKind::Busy, "a transfer is already pending"));
            }
            let c = ep.transfer_blocking(data.into(), wait_for(timeout));
            let sent = c.actual_len as u32;
            c.status?;
            Ok(sent)
        })
    }

    /// Requests cancellation of all pending transfers.
    #[frb(sync)]
    pub fn cancel_all(&mut self) {
        each!(OutKind, &mut self.0, |ep| ep.cancel_all())
    }

    /// Clears a halt (stall) condition. No transfers may be pending.
    pub fn clear_halt(&mut self) -> Result<(), UsbException> {
        each!(OutKind, &mut self.0, |ep| Ok(nusb::MaybeFuture::wait(ep.clear_halt())?))
    }

    /// Turns the endpoint into a buffered [EndpointWriter] with transfers of
    /// [transferSize] bytes, up to [numTransfers] (default 1) in flight.
    /// Writes time out after [writeTimeout], or never if `null`.
    #[frb(sync)]
    pub fn writer(self, transfer_size: u32, num_transfers: Option<u32>, write_timeout: Option<Duration>) -> EndpointWriter {
        let size = transfer_size as usize;
        let n = num_transfers.unwrap_or(1).max(1) as usize;
        let timeout = wait_for(write_timeout);
        EndpointWriter(match self.0 {
            OutKind::Bulk(ep) => WriterKind::Bulk(ep.writer(size).with_num_transfers(n).with_write_timeout(timeout)),
            OutKind::Interrupt(ep) => {
                WriterKind::Interrupt(ep.writer(size).with_num_transfers(n).with_write_timeout(timeout))
            }
        })
    }
}

fn no_pending() -> UsbException {
    UsbException::new(super::error::UsbErrorKind::Other, "no transfer pending")
}

pub(crate) enum ReaderKind {
    Bulk(EndpointRead<Bulk>),
    Interrupt(EndpointRead<Interrupt>),
}

pub(crate) enum WriterKind {
    Bulk(EndpointWrite<Bulk>),
    Interrupt(EndpointWrite<Interrupt>),
}

/// Buffered reader over an IN endpoint, keeping transfers in flight.
#[frb(opaque)]
pub struct EndpointReader(pub(crate) ReaderKind);

impl EndpointReader {
    /// Reads up to [maxLength] bytes. Returns an empty list at end of stream
    /// (after [cancelAll]).
    #[frb(positional)]
    pub fn read(&mut self, max_length: u32) -> Result<Vec<u8>, UsbException> {
        each!(ReaderKind, &mut self.0, |r| {
            let mut buf = vec![0; max_length as usize];
            let n = r.read(&mut buf)?;
            buf.truncate(n);
            Ok(buf)
        })
    }

    /// Reads exactly [length] bytes.
    #[frb(positional)]
    pub fn read_exact(&mut self, length: u32) -> Result<Vec<u8>, UsbException> {
        each!(ReaderKind, &mut self.0, |r| {
            let mut buf = vec![0; length as usize];
            r.read_exact(&mut buf)?;
            Ok(buf)
        })
    }

    /// Reads one message, ending with a short (or zero-length) packet.
    pub fn read_packet(&mut self) -> Result<Vec<u8>, UsbException> {
        each!(ReaderKind, &mut self.0, |r| {
            let mut packet = r.until_short_packet();
            let mut buf = Vec::new();
            packet.read_to_end(&mut buf)?;
            packet
                .consume_end()
                .map_err(|e| UsbException::new(super::error::UsbErrorKind::EndOfStream, e.to_string()))?;
            Ok(buf)
        })
    }

    /// Bytes already received and not yet read, without waiting for more
    /// unless the buffer is empty.
    pub fn fill_buf(&mut self) -> Result<Vec<u8>, UsbException> {
        each!(ReaderKind, &mut self.0, |r| Ok(r.fill_buf()?.to_vec()))
    }

    /// Cancels pending transfers. Reads then return the remaining data and
    /// end of stream.
    #[frb(sync)]
    pub fn cancel_all(&mut self) {
        each!(ReaderKind, &mut self.0, |r| r.cancel_all())
    }
}

/// Buffered writer over an OUT endpoint.
#[frb(opaque)]
pub struct EndpointWriter(pub(crate) WriterKind);

impl EndpointWriter {
    /// Writes all of [data], submitting transfers as they fill.
    #[frb(positional)]
    pub fn write_all(&mut self, data: Vec<u8>) -> Result<(), UsbException> {
        each!(WriterKind, &mut self.0, |w| Ok(w.write_all(&data)?))
    }

    /// Submits buffered data and waits for every pending transfer.
    pub fn flush(&mut self) -> Result<(), UsbException> {
        each!(WriterKind, &mut self.0, |w| Ok(w.flush()?))
    }

    /// Like [flush], but ends the message with a short packet, adding a
    /// zero-length packet if needed.
    pub fn flush_end(&mut self) -> Result<(), UsbException> {
        each!(WriterKind, &mut self.0, |w| Ok(w.flush_end()?))
    }

    /// Submits buffered data without waiting.
    #[frb(sync)]
    pub fn submit(&mut self) {
        each!(WriterKind, &mut self.0, |w| w.submit())
    }

    /// Submits buffered data and the end of the message without waiting.
    #[frb(sync)]
    pub fn submit_end(&mut self) {
        each!(WriterKind, &mut self.0, |w| w.submit_end())
    }
}
