//! Interruptible waits on endpoint I/O.
//!
//! A wait takes the endpoint's lock one slice at a time and hands it over
//! fairly in between, so queries and control operations on the same
//! endpoint (max packet size, halt, ...) are served within a slice instead
//! of waiting for data that may never come.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use parking_lot::{Mutex, MutexGuard};

use crate::api::error::{GadgetErrorKind, GadgetException};

/// Longest a wait holds the endpoint lock at once.
const SLICE: Duration = Duration::from_millis(50);

/// Cancellation for one endpoint: bumping the generation makes every wait
/// that started before it stop.
#[derive(Default)]
pub(crate) struct Cancel(AtomicU64);

impl Cancel {
    pub fn generation(&self) -> u64 {
        self.0.load(Ordering::Acquire)
    }

    pub fn cancel(&self) {
        self.0.fetch_add(1, Ordering::AcqRel);
    }
}

/// Why a wait ended without a value.
pub(crate) enum WaitError {
    Cancelled,
    TimedOut,
    Failed(GadgetException),
}

impl From<WaitError> for GadgetException {
    fn from(e: WaitError) -> Self {
        match e {
            WaitError::Cancelled => GadgetException::new(GadgetErrorKind::Cancelled, "cancelled"),
            WaitError::TimedOut => GadgetException::new(GadgetErrorKind::TimedOut, "timed out"),
            WaitError::Failed(e) => e,
        }
    }
}

/// Runs [step] on the locked endpoint, a slice at a time, until it yields,
/// [timeout] passes, or [cancel] moves past [generation].
pub(crate) fn wait<E, T>(
    endpoint: &Mutex<E>,
    cancel: &Cancel,
    generation: u64,
    timeout: Option<Duration>,
    mut step: impl FnMut(&mut E, Duration) -> std::io::Result<Option<T>>,
) -> Result<T, WaitError> {
    let deadline = timeout.map(|t| Instant::now() + t);
    loop {
        if cancel.generation() != generation {
            return Err(WaitError::Cancelled);
        }
        let slice = match deadline {
            Some(d) => match d.checked_duration_since(Instant::now()) {
                Some(left) => left.min(SLICE),
                None => return Err(WaitError::TimedOut),
            },
            None => SLICE,
        };
        let mut guard = endpoint.lock();
        let result = step(&mut guard, slice);
        MutexGuard::unlock_fair(guard);
        match result {
            Ok(Some(value)) => return Ok(value),
            Ok(None) => {}
            Err(e) => return Err(WaitError::Failed(e.into())),
        }
    }
}

pub(crate) fn timed_out(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::TimedOut
}
