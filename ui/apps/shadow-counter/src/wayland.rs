#![cfg(target_os = "linux")]

use std::{convert::TryInto, time::Duration};

use font8x8::{UnicodeFonts, BASIC_FONTS};
use smithay_client_toolkit::reexports::calloop::EventLoop;
use smithay_client_toolkit::reexports::calloop_wayland_source::WaylandSource;
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_output, delegate_pointer, delegate_registry, delegate_seat,
    delegate_shm, delegate_xdg_shell, delegate_xdg_window,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        pointer::{PointerEvent, PointerEventKind, PointerHandler},
        Capability, SeatHandler, SeatState,
    },
    shell::{
        xdg::{
            window::{Window, WindowConfigure, WindowDecorations, WindowHandler},
            XdgShell,
        },
        WaylandSurface,
    },
    shm::{
        slot::{Buffer, SlotPool},
        Shm, ShmHandler,
    },
};
use wayland_client::{
    globals::registry_queue_init,
    protocol::{wl_output, wl_pointer, wl_seat, wl_shm, wl_surface},
    Connection, QueueHandle,
};

use crate::{color, model::CounterModel};

const WINDOW_WIDTH: u32 = 360;
const WINDOW_HEIGHT: u32 = 420;

pub fn run() {
    eprintln!("[shadow-counter] connecting");
    let connection = Connection::connect_to_env().expect("connect to compositor");
    let (globals, event_queue) = registry_queue_init(&connection).expect("load globals");
    let queue_handle = event_queue.handle();

    let mut event_loop: EventLoop<CounterWaylandApp> =
        EventLoop::try_new().expect("create event loop");
    WaylandSource::new(connection.clone(), event_queue)
        .insert(event_loop.handle())
        .expect("insert wayland source");

    let compositor = CompositorState::bind(&globals, &queue_handle).expect("bind compositor");
    let xdg_shell = XdgShell::bind(&globals, &queue_handle).expect("bind xdg shell");
    let shm = Shm::bind(&globals, &queue_handle).expect("bind shm");
    let surface = compositor.create_surface(&queue_handle);
    let window = xdg_shell.create_window(surface, WindowDecorations::RequestServer, &queue_handle);
    window.set_title("Shadow Counter");
    window.set_app_id("sh.shadow.counter");
    window.set_min_size(Some((WINDOW_WIDTH, WINDOW_HEIGHT)));
    window.commit();
    eprintln!("[shadow-counter] surface-committed");

    let pool =
        SlotPool::new((WINDOW_WIDTH * WINDOW_HEIGHT * 4) as usize, &shm).expect("create shm pool");

    let mut app = CounterWaylandApp {
        registry_state: RegistryState::new(&globals),
        seat_state: SeatState::new(&globals, &queue_handle),
        output_state: OutputState::new(&globals, &queue_handle),
        shm,
        exit: false,
        first_configure: true,
        pool,
        width: WINDOW_WIDTH,
        height: WINDOW_HEIGHT,
        buffer: None,
        window,
        pointer: None,
        model: CounterModel::new(),
        frame_pending: false,
        needs_redraw: false,
    };

    while !app.exit {
        event_loop
            .dispatch(Duration::from_millis(16), &mut app)
            .expect("dispatch");
    }

    eprintln!("[shadow-counter] exiting");
}

struct CounterWaylandApp {
    registry_state: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    shm: Shm,
    exit: bool,
    first_configure: bool,
    pool: SlotPool,
    width: u32,
    height: u32,
    buffer: Option<Buffer>,
    window: Window,
    pointer: Option<wl_pointer::WlPointer>,
    model: CounterModel,
    frame_pending: bool,
    needs_redraw: bool,
}

impl CounterWaylandApp {
    fn request_redraw(&mut self, qh: &QueueHandle<Self>) {
        self.needs_redraw = true;
        if !self.frame_pending {
            self.draw(qh);
        }
    }

    fn draw(&mut self, qh: &QueueHandle<Self>) {
        let stride = self.width as i32 * 4;
        let buffer = self.buffer.get_or_insert_with(|| {
            self.pool
                .create_buffer(
                    self.width as i32,
                    self.height as i32,
                    stride,
                    wl_shm::Format::Argb8888,
                )
                .expect("create shm buffer")
                .0
        });

        let canvas = match self.pool.canvas(buffer) {
            Some(canvas) => canvas,
            None => {
                let (next_buffer, canvas) = self
                    .pool
                    .create_buffer(
                        self.width as i32,
                        self.height as i32,
                        stride,
                        wl_shm::Format::Argb8888,
                    )
                    .expect("create secondary shm buffer");
                *buffer = next_buffer;
                canvas
            }
        };

        render_ui(canvas, self.width, self.height, &self.model);

        self.window
            .wl_surface()
            .damage_buffer(0, 0, self.width as i32, self.height as i32);
        self.window
            .wl_surface()
            .frame(qh, self.window.wl_surface().clone());
        buffer
            .attach_to(self.window.wl_surface())
            .expect("attach buffer");
        self.window.commit();
        self.frame_pending = true;
        self.needs_redraw = false;
    }
}

impl CompositorHandler for CounterWaylandApp {
    fn scale_factor_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _new_factor: i32,
    ) {
    }

    fn transform_changed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _new_transform: wl_output::Transform,
    ) {
    }

    fn frame(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _time: u32,
    ) {
        self.frame_pending = false;
        if self.needs_redraw {
            self.draw(qh);
        }
    }

    fn surface_enter(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }

    fn surface_leave(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _surface: &wl_surface::WlSurface,
        _output: &wl_output::WlOutput,
    ) {
    }
}

impl OutputHandler for CounterWaylandApp {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.output_state
    }

    fn new_output(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _output: wl_output::WlOutput,
    ) {
    }

    fn update_output(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _output: wl_output::WlOutput,
    ) {
    }

    fn output_destroyed(
        &mut self,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
        _output: wl_output::WlOutput,
    ) {
    }
}

impl SeatHandler for CounterWaylandApp {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seat_state
    }

    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}

    fn new_capability(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        seat: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Pointer && self.pointer.is_none() {
            let pointer = self
                .seat_state
                .get_pointer(qh, &seat)
                .expect("create pointer");
            self.pointer = Some(pointer);
        }
    }

    fn remove_capability(
        &mut self,
        _conn: &Connection,
        _: &QueueHandle<Self>,
        _: wl_seat::WlSeat,
        capability: Capability,
    ) {
        if capability == Capability::Pointer {
            if let Some(pointer) = self.pointer.take() {
                pointer.release();
            }
        }
    }

    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl WindowHandler for CounterWaylandApp {
    fn request_close(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &Window) {
        self.exit = true;
    }

    fn configure(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        _window: &Window,
        configure: WindowConfigure,
        _serial: u32,
    ) {
        let first_configure = self.first_configure;
        self.first_configure = false;
        self.buffer = None;
        self.width = configure
            .new_size
            .0
            .map(|value| value.get())
            .unwrap_or(WINDOW_WIDTH);
        self.height = configure
            .new_size
            .1
            .map(|value| value.get())
            .unwrap_or(WINDOW_HEIGHT);
        if first_configure {
            eprintln!("[shadow-counter] configured");
        }
        self.request_redraw(qh);
    }
}

impl PointerHandler for CounterWaylandApp {
    fn pointer_frame(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        _pointer: &wl_pointer::WlPointer,
        events: &[PointerEvent],
    ) {
        for event in events {
            if &event.surface != self.window.wl_surface() {
                continue;
            }

            match event.kind {
                PointerEventKind::Press { .. } => {
                    self.model.press();
                    self.request_redraw(qh);
                }
                PointerEventKind::Release { .. } => {
                    self.model.release();
                    self.request_redraw(qh);
                }
                PointerEventKind::Leave { .. } => {
                    self.model.cancel_press();
                    self.request_redraw(qh);
                }
                _ => {}
            }
        }
    }
}

impl ShmHandler for CounterWaylandApp {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

delegate_compositor!(CounterWaylandApp);
delegate_output!(CounterWaylandApp);
delegate_shm!(CounterWaylandApp);
delegate_seat!(CounterWaylandApp);
delegate_pointer!(CounterWaylandApp);
delegate_xdg_shell!(CounterWaylandApp);
delegate_xdg_window!(CounterWaylandApp);
delegate_registry!(CounterWaylandApp);

impl ProvidesRegistryState for CounterWaylandApp {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry_state
    }

    registry_handlers![OutputState, SeatState];
}

fn render_ui(canvas: &mut [u8], width: u32, height: u32, model: &CounterModel) {
    let background = pack_color(color::BACKGROUND);
    let surface_top = pack_color(color::SURFACE_TOP);
    let surface_card = pack_color(color::SURFACE_CARD);
    let accent = pack_color(if model.pressed() {
        color::ACCENT_PRESSED
    } else {
        color::ACCENT
    });
    let primary = pack_color(color::TEXT_PRIMARY);
    let muted = pack_color(color::TEXT_MUTED);

    fill(canvas, background);
    fill_rect(
        canvas,
        width,
        height,
        24,
        24,
        width as i32 - 48,
        84,
        surface_top,
    );
    fill_rect(
        canvas,
        width,
        height,
        26,
        134,
        width as i32 - 52,
        470,
        surface_card,
    );
    fill_rect(
        canvas,
        width,
        height,
        92,
        if model.pressed() { 438 } else { 430 },
        width as i32 - 184,
        74,
        accent,
    );

    draw_centered_text(
        canvas,
        width,
        height,
        238,
        8,
        &model.count().to_string(),
        primary,
    );
    draw_centered_text(
        canvas,
        width,
        height,
        352,
        2,
        "CLICK OR SPACE / ENTER",
        muted,
    );
    draw_centered_text(
        canvas,
        width,
        height,
        if model.pressed() { 466 } else { 458 },
        3,
        if model.pressed() { "RELEASE" } else { "TAP" },
        primary,
    );
    draw_centered_text(
        canvas,
        width,
        height,
        650,
        2,
        "SMITHAY CLIENT TOOLKIT",
        muted,
    );
}

fn fill(canvas: &mut [u8], color: u32) {
    for chunk in canvas.chunks_exact_mut(4) {
        let array: &mut [u8; 4] = chunk.try_into().expect("pixel chunk");
        *array = color.to_le_bytes();
    }
}

fn fill_rect(
    canvas: &mut [u8],
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    rect_width: i32,
    rect_height: i32,
    color: u32,
) {
    let x0 = x.max(0) as u32;
    let y0 = y.max(0) as u32;
    let x1 = (x + rect_width).min(width as i32).max(0) as u32;
    let y1 = (y + rect_height).min(height as i32).max(0) as u32;

    for row in y0..y1 {
        for col in x0..x1 {
            let index = ((row * width + col) * 4) as usize;
            canvas[index..index + 4].copy_from_slice(&color.to_le_bytes());
        }
    }
}

fn draw_centered_text(
    canvas: &mut [u8],
    width: u32,
    height: u32,
    y: i32,
    scale: i32,
    text: &str,
    color: u32,
) {
    let glyph_width = 8 * scale;
    let spacing = scale.max(1);
    let total_width = text.chars().count() as i32 * glyph_width
        + (text.chars().count() as i32 - 1).max(0) * spacing;
    let start_x = ((width as i32 - total_width) / 2).max(0);
    draw_text(canvas, width, height, start_x, y, scale, text, color);
}

fn draw_text(
    canvas: &mut [u8],
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    scale: i32,
    text: &str,
    color: u32,
) {
    let mut cursor_x = x;
    let spacing = scale.max(1);

    for character in text.chars() {
        if character == ' ' {
            cursor_x += 8 * scale + spacing;
            continue;
        }

        if let Some(glyph) = BASIC_FONTS.get(character) {
            draw_glyph(canvas, width, height, cursor_x, y, scale, glyph, color);
        }
        cursor_x += 8 * scale + spacing;
    }
}

fn draw_glyph(
    canvas: &mut [u8],
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    scale: i32,
    glyph: [u8; 8],
    color: u32,
) {
    for (row, bits) in glyph.iter().enumerate() {
        for col in 0..8 {
            if bits & (1 << col) == 0 {
                continue;
            }

            let px = x + (col * scale);
            let py = y + (row as i32 * scale);
            fill_rect(canvas, width, height, px, py, scale, scale, color);
        }
    }
}

fn pack_color(color: shadow_ui_core::color::Color) -> u32 {
    let [r, g, b, a] = color.rgba8();
    ((a as u32) << 24) | ((r as u32) << 16) | ((g as u32) << 8) | b as u32
}
