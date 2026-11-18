//! Bridges the `usb-gadget` crate to Dart. `api` is what flutter_rust_bridge
//! exposes; the other modules are internal machinery behind it.

pub mod api;
mod event_thread;
mod frb_generated;
mod wait;
