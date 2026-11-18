//! Functions implemented by Linux kernel drivers.

use flutter_rust_bridge::frb;
use usb_gadget::function::{audio, hid, loopback, midi, msd, net, other, printer, serial, sourcesink, util, video};

use super::error::{GadgetErrorKind, GadgetException};
use super::gadget::FunctionHandle;
use super::{path_string, ClassCodes};

/// Registration state of a function.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FunctionState {
    /// Not part of a registered gadget yet.
    Unregistered,
    /// Registered, but the gadget isn't bound to a UDC.
    Registered,
    /// Registered and bound to a UDC.
    Bound,
    /// The gadget was removed.
    Removed,
}

impl From<util::State> for FunctionState {
    fn from(s: util::State) -> Self {
        match s {
            util::State::Unregistered => Self::Unregistered,
            util::State::Registered => Self::Registered,
            util::State::Bound => Self::Bound,
            util::State::Removed => Self::Removed,
        }
    }
}

pub(crate) enum Kind {
    Hid(hid::Hid),
    Msd(msd::Msd),
    Net(net::Net),
    Serial(serial::Serial),
    Midi(midi::Midi),
    Printer(printer::Printer),
    Loopback(loopback::Loopback),
    SourceSink(sourcesink::SourceSink),
    Uac1(audio::Uac1),
    Uac2(audio::Uac2),
    Uvc(video::Uvc),
    Other(other::Other),
}

/// A function implemented by a kernel driver.
#[frb(opaque)]
pub struct KernelFunction {
    kind: Kind,
    handle: usb_gadget::function::Handle,
}

fn unsupported<T>(what: &str) -> Result<T, GadgetException> {
    Err(GadgetException::new(GadgetErrorKind::Unsupported, format!("{what} is not available for this function")))
}

// --- Settings ---------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct HidSpec {
    pub sub_class: u8,
    pub protocol: u8,
    pub report_descriptor: Vec<u8>,
    pub report_length: u8,
    pub no_out_endpoint: bool,
}

#[derive(Debug, Clone)]
pub struct LunSpec {
    /// Backing file or block device; none for an empty removable medium.
    pub file: Option<String>,
    pub read_only: bool,
    pub cdrom: bool,
    pub no_fua: bool,
    pub removable: bool,
    pub inquiry_string: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetClassSpec {
    Ecm,
    EcmSubset,
    Eem,
    Ncm,
    Rndis,
}

#[derive(Debug, Clone)]
pub struct NetSpec {
    pub class: NetClassSpec,
    /// 6-byte MAC address of the device end.
    pub device_address: Option<Vec<u8>>,
    /// 6-byte MAC address of the host end.
    pub host_address: Option<Vec<u8>>,
    pub qmult: Option<u32>,
    /// RNDIS only.
    pub interface_class: Option<ClassCodes>,
}

#[derive(Debug, Clone)]
pub struct MidiSpec {
    pub buffer_length: Option<u16>,
    pub id: Option<String>,
    pub in_ports: Option<u8>,
    pub out_ports: Option<u8>,
    pub index: Option<u8>,
    pub queue_length: Option<u8>,
    pub interface_string: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SourceSinkSpec {
    pub pattern: Option<u32>,
    pub isoc_interval: Option<u32>,
    pub isoc_max_packet: Option<u32>,
    pub isoc_mult: Option<u32>,
    pub isoc_max_burst: Option<u32>,
    pub bulk_buffer_length: Option<u32>,
    pub bulk_queue_length: Option<u32>,
    pub isoc_queue_length: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct AudioChannelSpec {
    pub channel_mask: Option<u32>,
    pub sample_rate: Option<u32>,
    pub sample_size: Option<u32>,
}

/// Capture or playback settings; fields marked UAC2 are ignored for UAC1.
#[derive(Debug, Clone)]
pub struct AudioStreamSpec {
    pub channel: AudioChannelSpec,
    /// UAC2.
    pub sync_type: Option<u32>,
    /// UAC2.
    pub hs_interval: Option<u8>,
    pub mute_present: Option<bool>,
    /// UAC2.
    pub terminal_type: Option<u8>,
    pub volume_present: Option<bool>,
    pub volume_min: Option<i16>,
    pub volume_max: Option<i16>,
    pub volume_resolution: Option<i16>,
    pub volume_name: Option<String>,
    pub input_terminal_name: Option<String>,
    pub input_terminal_channel_name: Option<String>,
    pub output_terminal_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AudioSpec {
    /// 1 for UAC1, 2 for UAC2.
    pub version: u8,
    pub capture: AudioStreamSpec,
    pub playback: AudioStreamSpec,
    pub request_number: Option<u32>,
    pub function_name: Option<String>,
    /// UAC2.
    pub fb_max: Option<u32>,
    /// UAC2.
    pub control_name: Option<String>,
    /// UAC2.
    pub clock_source_in_name: Option<String>,
    /// UAC2.
    pub clock_source_out_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoFormatKind {
    Yuyv,
    Mjpeg,
    Framebased,
}

#[derive(Debug, Clone)]
pub struct VideoFormatSpec {
    pub kind: VideoFormatKind,
    /// Framebased: 16-byte GUID of the pixel format.
    pub guid: Vec<u8>,
    /// Framebased: configfs directory name, such as `nv12`.
    pub name: String,
    /// Framebased: 0 for compressed formats.
    pub bits_per_pixel: u8,
}

#[derive(Debug, Clone)]
pub struct ColorMatchingSpec {
    pub color_primaries: u8,
    pub transfer_characteristics: u8,
    pub matrix_coefficients: u8,
}

#[derive(Debug, Clone)]
pub struct VideoFrameSpec {
    pub width: u32,
    pub height: u32,
    pub format: VideoFormatSpec,
    /// Frame intervals in 100 ns units.
    pub intervals: Vec<u32>,
    pub color_matching: Option<ColorMatchingSpec>,
}

#[derive(Debug, Clone)]
pub struct VideoSpec {
    pub frames: Vec<VideoFrameSpec>,
    pub streaming_interval: Option<u8>,
    pub streaming_max_burst: Option<u8>,
    pub streaming_max_packet: Option<u32>,
    pub function_name: Option<String>,
    pub processing_controls: Option<u8>,
    pub camera_controls: Option<u8>,
}

#[derive(Debug, Clone)]
pub struct PropertySpec {
    pub name: String,
    pub value: Vec<u8>,
}

fn mac(bytes: Option<Vec<u8>>) -> Result<Option<macaddr::MacAddr6>, GadgetException> {
    bytes
        .map(|b| {
            <[u8; 6]>::try_from(b.as_slice())
                .map(macaddr::MacAddr6::from)
                .map_err(|_| GadgetException::new(GadgetErrorKind::InvalidInput, "a MAC address is 6 bytes"))
        })
        .transpose()
}

fn video_format(f: VideoFormatSpec) -> Result<video::Format, GadgetException> {
    Ok(match f.kind {
        VideoFormatKind::Yuyv => video::Format::Yuyv,
        VideoFormatKind::Mjpeg => video::Format::Mjpeg,
        VideoFormatKind::Framebased => video::Format::Framebased {
            guid: f
                .guid
                .try_into()
                .map_err(|_| GadgetException::new(GadgetErrorKind::InvalidInput, "a format GUID is 16 bytes"))?,
            // The crate takes a static name; formats live as long as the
            // gadget, and there are few of them.
            name: Box::leak(f.name.into_boxed_str()),
            bpp: f.bits_per_pixel,
        },
    })
}

macro_rules! audio_stream {
    ($target:expr, $s:expr) => {{
        let s = $s;
        $target.channel.channel_mask = s.channel.channel_mask;
        $target.channel.sample_rate = s.channel.sample_rate;
        $target.channel.sample_size = s.channel.sample_size;
        $target.mute_present = s.mute_present;
        $target.volume_present = s.volume_present;
        $target.volume_min = s.volume_min;
        $target.volume_max = s.volume_max;
        $target.volume_resolution = s.volume_resolution;
        $target.volume_name = s.volume_name;
        $target.input_terminal_name = s.input_terminal_name;
        $target.input_terminal_channel_name = s.input_terminal_channel_name;
        $target.output_terminal_name = s.output_terminal_name;
    }};
}

// --- Constructors -----------------------------------------------------------

impl KernelFunction {
    fn new((function, handle): (impl Into<KindOf>, usb_gadget::function::Handle)) -> Self {
        KernelFunction { kind: function.into().0, handle }
    }

    #[frb(sync)]
    pub fn hid(spec: HidSpec) -> KernelFunction {
        let mut b = hid::Hid::builder();
        b.sub_class = spec.sub_class;
        b.protocol = spec.protocol;
        b.report_desc = spec.report_descriptor;
        b.report_len = spec.report_length;
        b.no_out_endpoint = spec.no_out_endpoint;
        Self::new(b.build())
    }

    #[frb(sync)]
    pub fn mass_storage(stall: Option<bool>, luns: Vec<LunSpec>) -> Result<KernelFunction, GadgetException> {
        let mut b = msd::Msd::builder();
        b.stall = stall;
        for spec in luns {
            let mut lun = match spec.file {
                Some(file) => msd::Lun::new(file)?,
                None => msd::Lun::empty(),
            };
            lun.read_only = spec.read_only;
            lun.cdrom = spec.cdrom;
            lun.no_fua = spec.no_fua;
            lun.removable = spec.removable;
            lun.inquiry_string = spec.inquiry_string;
            b.add_lun(lun);
        }
        Ok(Self::new(b.build()))
    }

    #[frb(sync)]
    pub fn net(spec: NetSpec) -> Result<KernelFunction, GadgetException> {
        let mut b = net::Net::builder(match spec.class {
            NetClassSpec::Ecm => net::NetClass::Ecm,
            NetClassSpec::EcmSubset => net::NetClass::EcmSubset,
            NetClassSpec::Eem => net::NetClass::Eem,
            NetClassSpec::Ncm => net::NetClass::Ncm,
            NetClassSpec::Rndis => net::NetClass::Rndis,
        });
        b.dev_addr = mac(spec.device_address)?;
        b.host_addr = mac(spec.host_address)?;
        b.qmult = spec.qmult;
        b.interface_class = spec.interface_class.map(Into::into);
        Ok(Self::new(b.build()))
    }

    /// [acm] selects CDC ACM; otherwise the generic serial driver.
    #[frb(sync)]
    pub fn serial(acm: bool, console: Option<bool>) -> KernelFunction {
        let mut b = serial::Serial::builder(if acm { serial::SerialClass::Acm } else { serial::SerialClass::Generic });
        b.console = console;
        Self::new(b.build())
    }

    #[frb(sync)]
    pub fn midi(spec: MidiSpec) -> KernelFunction {
        let mut b = midi::Midi::builder();
        b.buflen = spec.buffer_length;
        b.id = spec.id;
        b.in_ports = spec.in_ports;
        b.out_ports = spec.out_ports;
        b.index = spec.index;
        b.qlen = spec.queue_length;
        b.interface_string = spec.interface_string;
        Self::new(b.build())
    }

    #[frb(sync)]
    pub fn printer(pnp_string: Option<String>, queue_length: Option<u8>) -> KernelFunction {
        let mut b = printer::Printer::builder();
        b.pnp_string = pnp_string;
        b.qlen = queue_length;
        Self::new(b.build())
    }

    #[frb(sync)]
    pub fn loopback(queue_length: Option<u32>, bulk_buffer_length: Option<u32>) -> KernelFunction {
        let mut b = loopback::Loopback::builder();
        b.qlen = queue_length;
        b.bulk_buflen = bulk_buffer_length;
        Self::new(b.build())
    }

    #[frb(sync)]
    pub fn source_sink(spec: SourceSinkSpec) -> KernelFunction {
        let mut b = sourcesink::SourceSink::builder();
        b.pattern = spec.pattern;
        b.isoc_interval = spec.isoc_interval;
        b.isoc_maxpacket = spec.isoc_max_packet;
        b.isoc_mult = spec.isoc_mult;
        b.isoc_maxburst = spec.isoc_max_burst;
        b.bulk_buflen = spec.bulk_buffer_length;
        b.bulk_qlen = spec.bulk_queue_length;
        b.iso_qlen = spec.isoc_queue_length;
        Self::new(b.build())
    }

    #[frb(sync)]
    pub fn audio(spec: AudioSpec) -> Result<KernelFunction, GadgetException> {
        match spec.version {
            1 => {
                let mut b = audio::Uac1::builder();
                audio_stream!(b.capture, spec.capture);
                audio_stream!(b.playback, spec.playback);
                b.request_number = spec.request_number;
                b.function_name = spec.function_name;
                Ok(Self::new(b.build()))
            }
            2 => {
                let mut b = audio::Uac2::builder();
                b.capture.sync_type = spec.capture.sync_type;
                b.capture.hs_interval = spec.capture.hs_interval;
                b.capture.terminal_type = spec.capture.terminal_type;
                audio_stream!(b.capture, spec.capture);
                b.playback.sync_type = spec.playback.sync_type;
                b.playback.hs_interval = spec.playback.hs_interval;
                b.playback.terminal_type = spec.playback.terminal_type;
                audio_stream!(b.playback, spec.playback);
                b.request_number = spec.request_number;
                b.function_name = spec.function_name;
                b.fb_max = spec.fb_max;
                b.control_name = spec.control_name;
                b.clock_source_in_name = spec.clock_source_in_name;
                b.clock_source_out_name = spec.clock_source_out_name;
                Ok(Self::new(b.build()))
            }
            v => Err(GadgetException::new(GadgetErrorKind::InvalidInput, format!("unknown UAC version {v}"))),
        }
    }

    #[frb(sync)]
    pub fn video(spec: VideoSpec) -> Result<KernelFunction, GadgetException> {
        let mut b = video::Uvc::builder();
        for f in spec.frames {
            let mut frame = video::UvcFrame::new(f.width, f.height, video_format(f.format)?, f.intervals);
            frame.color_matching = f.color_matching.map(|c| {
                video::ColorMatching::new(c.color_primaries, c.transfer_characteristics, c.matrix_coefficients)
            });
            b.add_frame(frame);
        }
        b.streaming_interval = spec.streaming_interval;
        b.streaming_max_burst = spec.streaming_max_burst;
        b.streaming_max_packet = spec.streaming_max_packet;
        b.function_name = spec.function_name;
        b.processing_controls = spec.processing_controls;
        b.camera_controls = spec.camera_controls;
        Ok(Self::new(b.build()))
    }

    /// Any configfs function driver, with raw attribute values.
    #[frb(sync)]
    pub fn other(driver: String, properties: Vec<PropertySpec>) -> Result<KernelFunction, GadgetException> {
        let mut b = other::Other::builder(driver)?;
        for p in properties {
            b.set(p.name, p.value)?;
        }
        Ok(Self::new(b.build()))
    }
}

/// Lets [KernelFunction::new] take any function type.
pub(crate) struct KindOf(Kind);

macro_rules! kind_of {
    ($($ty:ty => $variant:ident),* $(,)?) => {
        $(impl From<$ty> for KindOf {
            fn from(f: $ty) -> Self {
                KindOf(Kind::$variant(f))
            }
        })*
    };
}

kind_of! {
    hid::Hid => Hid,
    msd::Msd => Msd,
    net::Net => Net,
    serial::Serial => Serial,
    midi::Midi => Midi,
    printer::Printer => Printer,
    loopback::Loopback => Loopback,
    sourcesink::SourceSink => SourceSink,
    audio::Uac1 => Uac1,
    audio::Uac2 => Uac2,
    video::Uvc => Uvc,
    other::Other => Other,
}

// --- Queries ----------------------------------------------------------------

impl KernelFunction {
    fn status(&self) -> util::Status {
        match &self.kind {
            Kind::Hid(f) => f.status(),
            Kind::Msd(f) => f.status(),
            Kind::Net(f) => f.status(),
            Kind::Serial(f) => f.status(),
            Kind::Midi(f) => f.status(),
            Kind::Printer(f) => f.status(),
            Kind::Loopback(f) => f.status(),
            Kind::SourceSink(f) => f.status(),
            Kind::Uac1(f) => f.status(),
            Kind::Uac2(f) => f.status(),
            Kind::Uvc(f) => f.status(),
            Kind::Other(f) => f.status(),
        }
    }

    /// A handle for adding this function to a configuration.
    #[frb(sync)]
    pub fn handle(&self) -> FunctionHandle {
        FunctionHandle(self.handle.clone())
    }

    #[frb(sync, getter)]
    pub fn state(&self) -> FunctionState {
        self.status().state().into()
    }

    /// The function's configfs directory, once registered.
    #[frb(sync, getter)]
    pub fn path(&self) -> Option<String> {
        self.status().path().map(path_string)
    }

    /// The device file: `/dev/hidgN` for HID, the tty for serial.
    #[frb(sync)]
    pub fn device_path(&self) -> Result<String, GadgetException> {
        match &self.kind {
            Kind::Hid(f) => Ok(path_string(f.device_path()?)),
            Kind::Serial(f) => Ok(path_string(f.tty()?)),
            _ => unsupported("a device file"),
        }
    }

    /// Network interface name, such as `usb0`.
    #[frb(sync)]
    pub fn interface_name(&self) -> Result<String, GadgetException> {
        match &self.kind {
            Kind::Net(f) => Ok(f.ifname()?.to_string_lossy().into_owned()),
            _ => unsupported("a network interface"),
        }
    }

    /// MAC address of the device end.
    #[frb(sync)]
    pub fn device_address(&self) -> Result<Vec<u8>, GadgetException> {
        match &self.kind {
            Kind::Net(f) => Ok(f.dev_addr()?.as_bytes().to_vec()),
            _ => unsupported("a MAC address"),
        }
    }

    /// MAC address of the host end.
    #[frb(sync)]
    pub fn host_address(&self) -> Result<Vec<u8>, GadgetException> {
        match &self.kind {
            Kind::Net(f) => Ok(f.host_addr()?.as_bytes().to_vec()),
            _ => unsupported("a MAC address"),
        }
    }

    /// Ejects the medium of logical unit [lun], even if the host locked it.
    #[frb(positional)]
    pub fn force_eject(&self, lun: u32) -> Result<(), GadgetException> {
        match &self.kind {
            Kind::Msd(f) => Ok(f.force_eject(lun as usize)?),
            _ => unsupported("ejecting"),
        }
    }

    /// Changes the backing file of logical unit [lun]; none ejects it.
    #[frb(positional)]
    pub fn set_file(&self, lun: u32, file: Option<String>) -> Result<(), GadgetException> {
        match &self.kind {
            Kind::Msd(f) => Ok(f.set_file(lun as usize, file)?),
            _ => unsupported("a backing file"),
        }
    }

    /// Reads a configfs attribute.
    #[frb(positional)]
    pub fn property(&self, name: String) -> Result<Vec<u8>, GadgetException> {
        match &self.kind {
            Kind::Other(f) => Ok(f.get(name)?),
            _ => unsupported("reading attributes"),
        }
    }
}
