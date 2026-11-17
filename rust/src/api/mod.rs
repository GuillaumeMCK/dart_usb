//! The API exposed to Dart. Thin wrappers over `nusb`, translated into types
//! flutter_rust_bridge can carry: plain structs and fieldless enums are
//! copied, and nusb's handles are opaque Dart objects.

pub mod descriptors;
pub mod device;
pub mod endpoint;
pub mod enumeration;
pub mod error;
pub mod types;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
