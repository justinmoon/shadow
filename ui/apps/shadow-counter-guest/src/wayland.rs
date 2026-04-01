use std::{
    env,
    fs::File,
    os::fd::{AsFd, OwnedFd},
    time::Duration,
};

use rustix::fs::{ftruncate, memfd_create, MemfdFlags};
use tracing::info;
use wayland_client::{
    delegate_noop,
    globals::{registry_queue_init, GlobalList},
    protocol::{wl_buffer, wl_compositor, wl_registry, wl_shm, wl_shm_pool, wl_surface},
    Connection, Dispatch, EventQueue, QueueHandle,
};
use wayland_protocols::xdg::shell::client::{xdg_surface, xdg_toplevel, xdg_wm_base};

const DEFAULT_WIDTH: i32 = 220;
const DEFAULT_HEIGHT: i32 = 120;
const BYTES_PER_PIXEL: i32 = 4;
const FULLSCREEN_BORDER_PX: i32 = 24;

fn init_logging() {
    if let Ok(filter) = tracing_subscriber::EnvFilter::try_from_default_env() {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    } else {
        tracing_subscriber::fmt()
            .with_env_filter("shadow_counter_guest=info")
            .init();
    }
}

struct AppState {
    config: CounterConfig,
    globals: GlobalList,
    compositor: wl_compositor::WlCompositor,
    shm: wl_shm::WlShm,
    wm_base: xdg_wm_base::XdgWmBase,
    surface: wl_surface::WlSurface,
    xdg_surface: xdg_surface::XdgSurface,
    xdg_toplevel: xdg_toplevel::XdgToplevel,
    pool: Option<wl_shm_pool::WlShmPool>,
    buffer: Option<wl_buffer::WlBuffer>,
    buffer_checksum: Option<u64>,
    file: Option<File>,
    done: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CounterPattern {
    Checker,
    Quadrants,
}

#[derive(Clone, Copy, Debug)]
struct CounterConfig {
    width: i32,
    height: i32,
    fullscreen: bool,
    exit_on_configure: bool,
    linger_ms: u64,
    pattern: CounterPattern,
}

impl CounterConfig {
    fn from_env() -> Self {
        Self {
            width: parse_positive_i32_env("SHADOW_GUEST_COUNTER_WIDTH").unwrap_or(DEFAULT_WIDTH),
            height: parse_positive_i32_env("SHADOW_GUEST_COUNTER_HEIGHT").unwrap_or(DEFAULT_HEIGHT),
            fullscreen: env::var_os("SHADOW_GUEST_COUNTER_FULLSCREEN").is_some(),
            exit_on_configure: env::var_os("SHADOW_GUEST_COUNTER_EXIT_ON_CONFIGURE").is_some(),
            linger_ms: env::var("SHADOW_GUEST_COUNTER_LINGER_MS")
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .unwrap_or(250),
            pattern: parse_pattern_env("SHADOW_GUEST_COUNTER_PATTERN")
                .unwrap_or(CounterPattern::Checker),
        }
    }

    fn stride(self) -> i32 {
        self.width * BYTES_PER_PIXEL
    }

    fn buffer_size(self) -> usize {
        usize::try_from(
            self.stride()
                .checked_mul(self.height)
                .expect("guest counter buffer size overflow"),
        )
        .expect("guest counter buffer size should be positive")
    }
}

impl AppState {
    fn ensure_buffer(&mut self, qh: &QueueHandle<Self>) {
        if self.buffer.is_some() {
            return;
        }

        let fd: OwnedFd =
            memfd_create("shadow-counter-guest", MemfdFlags::empty()).expect("memfd_create");
        ftruncate(&fd, self.config.buffer_size() as u64).expect("ftruncate");
        let file = File::from(fd);
        file.set_len(self.config.buffer_size() as u64)
            .expect("set_len");

        let mut mapping =
            unsafe { memmap2::MmapMut::map_mut(&file).expect("mmap guest wayland buffer") };
        paint_buffer(
            mapping.as_mut(),
            self.config.width,
            self.config.height,
            self.config.pattern,
        );
        let checksum = frame_checksum(mapping.as_ref());

        let pool = self
            .shm
            .create_pool(file.as_fd(), self.config.buffer_size() as i32, qh, ());
        let buffer = pool.create_buffer(
            0,
            self.config.width,
            self.config.height,
            self.config.stride(),
            wl_shm::Format::Argb8888,
            qh,
            (),
        );

        self.file = Some(file);
        self.pool = Some(pool);
        self.buffer = Some(buffer);
        self.buffer_checksum = Some(checksum);
    }

    fn commit_frame(&mut self, qh: &QueueHandle<Self>) {
        self.ensure_buffer(qh);
        let buffer = self.buffer.as_ref().expect("guest buffer");
        self.surface.attach(Some(buffer), 0, 0);
        self.surface
            .damage_buffer(0, 0, self.config.width, self.config.height);
        self.surface.commit();
        let checksum = self.buffer_checksum.expect("guest buffer checksum");
        info!(
            "[shadow-guest-counter] frame-committed checksum={checksum:016x} size={}x{}",
            self.config.width, self.config.height
        );
    }
}

fn parse_positive_i32_env(name: &str) -> Option<i32> {
    let value = env::var(name).ok()?;
    match value.parse::<i32>() {
        Ok(parsed) if parsed > 0 => Some(parsed),
        Ok(_) => {
            tracing::warn!("[shadow-guest-counter] ignoring non-positive {name}={value}");
            None
        }
        Err(error) => {
            tracing::warn!("[shadow-guest-counter] ignoring invalid {name}={value}: {error}");
            None
        }
    }
}

fn parse_pattern_env(name: &str) -> Option<CounterPattern> {
    let value = env::var(name).ok()?;
    match value.as_str() {
        "checker" => Some(CounterPattern::Checker),
        "quadrants" => Some(CounterPattern::Quadrants),
        other => {
            tracing::warn!("[shadow-guest-counter] ignoring unknown {name}={other}");
            None
        }
    }
}

fn paint_buffer(bytes: &mut [u8], width: i32, height: i32, pattern: CounterPattern) {
    for (index, pixel) in bytes.chunks_exact_mut(4).enumerate() {
        let x = (index as i32) % width;
        let y = (index as i32) / width;
        let (red, green, blue) = match pattern {
            CounterPattern::Checker => {
                let red = if (x / 20) % 2 == 0 { 0xE6 } else { 0x24 };
                let green = if (y / 20) % 2 == 0 { 0x5C } else { 0xC7 };
                let blue = 0xD8;
                (red, green, blue)
            }
            CounterPattern::Quadrants => {
                let border = x < FULLSCREEN_BORDER_PX
                    || y < FULLSCREEN_BORDER_PX
                    || x >= width.saturating_sub(FULLSCREEN_BORDER_PX)
                    || y >= height.saturating_sub(FULLSCREEN_BORDER_PX);
                if border {
                    (0xFF, 0xFF, 0xFF)
                } else if x < width / 2 && y < height / 2 {
                    (0xFF, 0xD6, 0x00)
                } else if x >= width / 2 && y < height / 2 {
                    (0x08, 0xE8, 0xFF)
                } else if x < width / 2 {
                    (0xFF, 0x2D, 0x55)
                } else {
                    (0x32, 0xD7, 0x4B)
                }
            }
        };
        pixel[0] = blue;
        pixel[1] = green;
        pixel[2] = red;
        pixel[3] = 0xFF;
    }
}

fn frame_checksum(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

impl Dispatch<wl_registry::WlRegistry, wayland_client::globals::GlobalListContents> for AppState {
    fn event(
        _state: &mut Self,
        _proxy: &wl_registry::WlRegistry,
        _event: wl_registry::Event,
        _data: &wayland_client::globals::GlobalListContents,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<xdg_wm_base::XdgWmBase, ()> for AppState {
    fn event(
        _state: &mut Self,
        proxy: &xdg_wm_base::XdgWmBase,
        event: xdg_wm_base::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        if let xdg_wm_base::Event::Ping { serial } = event {
            proxy.pong(serial);
        }
    }
}

impl Dispatch<xdg_surface::XdgSurface, ()> for AppState {
    fn event(
        state: &mut Self,
        _proxy: &xdg_surface::XdgSurface,
        event: xdg_surface::Event,
        _data: &(),
        conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let xdg_surface::Event::Configure { serial } = event {
            state.xdg_surface.ack_configure(serial);
            info!("[shadow-guest-counter] configured");
            state.commit_frame(qh);
            conn.flush().expect("flush guest frame commit");
            if state.config.exit_on_configure {
                std::thread::sleep(Duration::from_millis(state.config.linger_ms));
                state.done = true;
            }
        }
    }
}

impl Dispatch<xdg_toplevel::XdgToplevel, ()> for AppState {
    fn event(
        _state: &mut Self,
        _proxy: &xdg_toplevel::XdgToplevel,
        event: xdg_toplevel::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        if let xdg_toplevel::Event::Close = event {
            info!("[shadow-guest-counter] close");
        }
    }
}

delegate_noop!(AppState: ignore wl_compositor::WlCompositor);
delegate_noop!(AppState: ignore wl_surface::WlSurface);
delegate_noop!(AppState: ignore wl_shm::WlShm);
delegate_noop!(AppState: ignore wl_shm_pool::WlShmPool);
delegate_noop!(AppState: ignore wl_buffer::WlBuffer);

pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    init_logging();
    let config = CounterConfig::from_env();

    let connection = Connection::connect_to_env()?;
    let (globals, mut event_queue): (GlobalList, EventQueue<AppState>) =
        registry_queue_init(&connection)?;
    let qh = event_queue.handle();
    let compositor = globals.bind::<wl_compositor::WlCompositor, _, _>(&qh, 4..=6, ())?;
    let shm = globals.bind::<wl_shm::WlShm, _, _>(&qh, 1..=1, ())?;
    let wm_base = globals.bind::<xdg_wm_base::XdgWmBase, _, _>(&qh, 1..=6, ())?;
    let surface = compositor.create_surface(&qh, ());
    let xdg_surface = wm_base.get_xdg_surface(&surface, &qh, ());
    let xdg_toplevel = xdg_surface.get_toplevel(&qh, ());
    xdg_toplevel.set_title("Shadow Guest Counter".into());
    if config.fullscreen {
        xdg_toplevel.set_fullscreen(None);
    }
    surface.commit();

    let mut state = AppState {
        config,
        globals,
        compositor,
        shm,
        wm_base,
        surface,
        xdg_surface,
        xdg_toplevel,
        pool: None,
        buffer: None,
        buffer_checksum: None,
        file: None,
        done: false,
    };

    let _ = &state.globals;
    let _ = &state.compositor;
    let _ = &state.wm_base;
    let _ = &state.xdg_toplevel;

    info!(
        "[shadow-guest-counter] mode size={}x{} pattern={:?} fullscreen={} exit_on_configure={} linger_ms={}",
        state.config.width,
        state.config.height,
        state.config.pattern,
        state.config.fullscreen,
        state.config.exit_on_configure,
        state.config.linger_ms
    );
    info!("[shadow-guest-counter] connecting");
    while !state.done {
        event_queue.blocking_dispatch(&mut state)?;
    }
    info!("[shadow-guest-counter] exiting");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        frame_checksum, paint_buffer, CounterPattern, BYTES_PER_PIXEL, DEFAULT_HEIGHT,
        DEFAULT_WIDTH, FULLSCREEN_BORDER_PX,
    };

    #[test]
    fn guest_frame_pattern_checksum_is_stable() {
        let mut bytes = vec![0_u8; (DEFAULT_WIDTH * DEFAULT_HEIGHT * BYTES_PER_PIXEL) as usize];
        paint_buffer(
            &mut bytes,
            DEFAULT_WIDTH,
            DEFAULT_HEIGHT,
            CounterPattern::Checker,
        );
        assert_eq!(frame_checksum(&bytes), 0xdd64a1693b87ade5);
    }

    #[test]
    fn fullscreen_quadrants_use_white_border_and_distinct_corner_colors() {
        let width = (FULLSCREEN_BORDER_PX * 2) + 4;
        let height = (FULLSCREEN_BORDER_PX * 2) + 4;
        let mut bytes = vec![0_u8; (width * height * BYTES_PER_PIXEL) as usize];
        paint_buffer(&mut bytes, width, height, CounterPattern::Quadrants);

        let pixel = |x: i32, y: i32| {
            let offset = ((y * width) + x) as usize * BYTES_PER_PIXEL as usize;
            &bytes[offset..offset + BYTES_PER_PIXEL as usize]
        };

        assert_eq!(pixel(0, 0), &[0xFF, 0xFF, 0xFF, 0xFF]);
        assert_eq!(
            pixel(FULLSCREEN_BORDER_PX, FULLSCREEN_BORDER_PX),
            &[0x00, 0xD6, 0xFF, 0xFF]
        );
        assert_eq!(
            pixel(width - FULLSCREEN_BORDER_PX - 1, FULLSCREEN_BORDER_PX),
            &[0xFF, 0xE8, 0x08, 0xFF]
        );
        assert_eq!(
            pixel(FULLSCREEN_BORDER_PX, height - FULLSCREEN_BORDER_PX - 1),
            &[0x55, 0x2D, 0xFF, 0xFF]
        );
        assert_eq!(
            pixel(
                width - FULLSCREEN_BORDER_PX - 1,
                height - FULLSCREEN_BORDER_PX - 1
            ),
            &[0x4B, 0xD7, 0x32, 0xFF]
        );
    }
}
