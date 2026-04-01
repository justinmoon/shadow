#![cfg(target_os = "linux")]

use std::{convert::TryInto, time::Duration};

use font8x8::{UnicodeFonts, BASIC_FONTS};
use shadow_ui_core::app;
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_keyboard, delegate_output, delegate_pointer, delegate_registry,
    delegate_seat, delegate_shm, delegate_xdg_shell, delegate_xdg_window,
    output::{OutputHandler, OutputState},
    reexports::{calloop::EventLoop, calloop_wayland_source::WaylandSource},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RawModifiers},
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
    protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_shm, wl_surface},
    Connection, QueueHandle,
};

use crate::{
    color, layout,
    model::{CounterAction, CounterButtonState, CounterModel},
};

const WINDOW_WIDTH: u32 = layout::WINDOW_WIDTH;
const WINDOW_HEIGHT: u32 = layout::WINDOW_HEIGHT;

pub fn run() {
    let connection = Connection::connect_to_env().expect("connect to wayland compositor");
    let (globals, event_queue) = registry_queue_init(&connection).expect("init registry");
    let qh = event_queue.handle();
    let mut event_loop: EventLoop<CounterWaylandApp> =
        EventLoop::try_new().expect("create wayland event loop");
    let loop_handle = event_loop.handle();
    WaylandSource::new(connection, event_queue)
        .insert(loop_handle.clone())
        .expect("insert wayland source");

    let compositor = CompositorState::bind(&globals, &qh).expect("bind wl_compositor");
    let xdg_shell = XdgShell::bind(&globals, &qh).expect("bind xdg shell");
    let shm = Shm::bind(&globals, &qh).expect("bind wl_shm");

    let surface = compositor.create_surface(&qh);
    let window = xdg_shell.create_window(surface, WindowDecorations::RequestServer, &qh);
    window.set_title("Shadow Counter");
    window.set_app_id(app::COUNTER_WAYLAND_APP_ID);
    window.set_min_size(Some((WINDOW_WIDTH, WINDOW_HEIGHT)));
    window.set_max_size(Some((WINDOW_WIDTH, WINDOW_HEIGHT)));
    window.commit();

    let pool =
        SlotPool::new(buffer_len(WINDOW_WIDTH, WINDOW_HEIGHT), &shm).expect("create shm slot pool");

    let mut app = CounterWaylandApp {
        registry_state: RegistryState::new(&globals),
        seat_state: SeatState::new(&globals, &qh),
        output_state: OutputState::new(&globals, &qh),
        shm,
        pool,
        width: WINDOW_WIDTH,
        height: WINDOW_HEIGHT,
        buffer: None,
        window,
        keyboard: None,
        pointer: None,
        loop_handle,
        model: CounterModel::new(),
        frame_pending: false,
        needs_redraw: false,
        exit: false,
    };

    while !app.exit {
        event_loop
            .dispatch(Duration::from_millis(16), &mut app)
            .expect("dispatch wayland events");
    }
}

struct CounterWaylandApp {
    registry_state: RegistryState,
    seat_state: SeatState,
    output_state: OutputState,
    shm: Shm,
    pool: SlotPool,
    width: u32,
    height: u32,
    buffer: Option<Buffer>,
    window: Window,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    loop_handle: smithay_client_toolkit::reexports::calloop::LoopHandle<'static, Self>,
    model: CounterModel,
    frame_pending: bool,
    needs_redraw: bool,
    exit: bool,
}

impl CounterWaylandApp {
    fn request_redraw(&mut self, qh: &QueueHandle<Self>) {
        if self.width == 0 || self.height == 0 {
            self.needs_redraw = false;
            return;
        }

        self.needs_redraw = true;
        if !self.frame_pending {
            self.draw(qh);
        }
    }

    fn draw(&mut self, qh: &QueueHandle<Self>) {
        if self.width == 0 || self.height == 0 {
            self.needs_redraw = false;
            return;
        }

        self.ensure_pool_capacity();

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

    fn ensure_pool_capacity(&mut self) {
        let required = buffer_len(self.width, self.height);
        if self.pool.len() < required {
            self.pool.resize(required).expect("resize shm slot pool");
        }
    }
}

fn handle_action(app: &mut CounterWaylandApp, action: CounterAction) {
    let CounterAction::Close = action;
    app.exit = true;
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
        let next_width = configure
            .new_size
            .0
            .map(|value| value.get())
            .unwrap_or(self.width);
        let next_height = configure
            .new_size
            .1
            .map(|value| value.get())
            .unwrap_or(self.height);

        if next_width != self.width || next_height != self.height {
            self.width = next_width;
            self.height = next_height;
            self.buffer = None;
        }

        self.request_redraw(qh);
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
        if capability == Capability::Keyboard && self.keyboard.is_none() {
            let keyboard = self
                .seat_state
                .get_keyboard_with_repeat(
                    qh,
                    &seat,
                    None,
                    self.loop_handle.clone(),
                    Box::new(|_, _, _| {}),
                )
                .expect("create keyboard");
            self.keyboard = Some(keyboard);
        }

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
        if capability == Capability::Keyboard {
            if let Some(keyboard) = self.keyboard.take() {
                keyboard.release();
            }
        }

        if capability == Capability::Pointer {
            if let Some(pointer) = self.pointer.take() {
                pointer.release();
            }
        }
    }

    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

impl KeyboardHandler for CounterWaylandApp {
    fn enter(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: &wl_surface::WlSurface,
        _: u32,
        _: &[u32],
        _: &[Keysym],
    ) {
    }

    fn leave(
        &mut self,
        _: &Connection,
        qh: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: &wl_surface::WlSurface,
        _: u32,
    ) {
        self.model.cancel_press();
        self.request_redraw(qh);
    }

    fn press_key(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        event: KeyEvent,
    ) {
        match event.keysym {
            Keysym::Escape => {
                let action = self.model.close_action();
                handle_action(self, action);
            }
            Keysym::space | Keysym::Return | Keysym::KP_Enter => {
                self.model.activate_pressed();
                self.request_redraw(qh);
            }
            _ => {}
        }
    }

    fn repeat_key(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        _: KeyEvent,
    ) {
    }

    fn release_key(
        &mut self,
        _conn: &Connection,
        qh: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        event: KeyEvent,
    ) {
        match event.keysym {
            Keysym::space | Keysym::Return | Keysym::KP_Enter => {
                self.model.activate_released();
                self.request_redraw(qh);
            }
            _ => {}
        }
    }

    fn update_modifiers(
        &mut self,
        _: &Connection,
        _: &QueueHandle<Self>,
        _: &wl_keyboard::WlKeyboard,
        _: u32,
        _: Modifiers,
        _: RawModifiers,
        _: u32,
    ) {
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
                PointerEventKind::Enter { .. }
                | PointerEventKind::Motion { .. }
                | PointerEventKind::Press { .. }
                | PointerEventKind::Release { .. } => {
                    self.model.pointer_moved(
                        event.position.0 as f32,
                        event.position.1 as f32,
                        self.width as f32,
                        self.height as f32,
                    );
                }
                PointerEventKind::Leave { .. } | PointerEventKind::Axis { .. } => {}
            }

            match event.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    self.request_redraw(qh);
                }
                PointerEventKind::Press { .. } => {
                    let action = self.model.pointer_button(
                        CounterButtonState::Pressed,
                        self.width as f32,
                        self.height as f32,
                    );
                    if let Some(action) = action {
                        handle_action(self, action);
                    }
                    self.request_redraw(qh);
                }
                PointerEventKind::Release { .. } => {
                    let action = self.model.pointer_button(
                        CounterButtonState::Released,
                        self.width as f32,
                        self.height as f32,
                    );
                    if let Some(action) = action {
                        handle_action(self, action);
                    }
                    self.request_redraw(qh);
                }
                PointerEventKind::Leave { .. } => {
                    self.model.pointer_left();
                    self.request_redraw(qh);
                }
                PointerEventKind::Axis { .. } => {}
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
delegate_keyboard!(CounterWaylandApp);
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

fn buffer_len(width: u32, height: u32) -> usize {
    (width as usize)
        .checked_mul(height as usize)
        .and_then(|value| value.checked_mul(4))
        .expect("buffer size overflow")
}

fn render_ui(canvas: &mut [u8], width: u32, height: u32, model: &CounterModel) {
    let width_f = width as f32;
    let height_f = height as f32;
    let hero_card = layout::hero_card_frame(width_f);
    let body_card = layout::count_card_frame(width_f, height_f);
    let accent_card = layout::accent_card_frame(width_f);
    let tap_button = layout::tap_button_frame(width_f, height_f);
    let background = pack_color(color::BACKGROUND);
    let surface_top = pack_color(color::SURFACE_TOP);
    let surface_card = pack_color(color::SURFACE_CARD);
    let accent_panel = pack_color(color::ACCENT_PANEL);
    let accent = pack_color(
        if model.pressed_target() == Some(layout::CounterTarget::Tap) {
            color::ACCENT_PRESSED
        } else if model.hovered_target() == Some(layout::CounterTarget::Tap) {
            color::ACCENT_HOVER
        } else {
            color::ACCENT
        },
    );
    let primary = pack_color(color::TEXT_PRIMARY);
    let muted = pack_color(color::TEXT_MUTED);

    fill(canvas, background);
    fill_rect(
        canvas,
        width,
        height,
        hero_card.x as i32,
        hero_card.y as i32,
        hero_card.w as i32,
        hero_card.h as i32,
        surface_top,
    );
    fill_rect(
        canvas,
        width,
        height,
        body_card.x as i32,
        body_card.y as i32,
        body_card.w as i32,
        body_card.h as i32,
        surface_card,
    );
    fill_rect(
        canvas,
        width,
        height,
        accent_card.x as i32,
        accent_card.y as i32,
        accent_card.w as i32,
        accent_card.h as i32,
        accent_panel,
    );
    fill_rect(
        canvas,
        width,
        height,
        tap_button.x as i32,
        tap_button.y as i32,
        tap_button.w as i32,
        tap_button.h as i32,
        accent,
    );

    draw_text(
        canvas,
        width,
        height,
        hero_card.x as i32 + 24,
        hero_card.y as i32 + 28,
        2,
        "COUNTER DEMO",
        muted,
    );
    draw_text(
        canvas,
        width,
        height,
        hero_card.x as i32 + 24,
        hero_card.y as i32 + 70,
        4,
        "COUNT",
        primary,
    );
    draw_text(
        canvas,
        width,
        height,
        hero_card.x as i32 + 24,
        hero_card.y as i32 + 118,
        2,
        "Inside the shell",
        muted,
    );
    draw_centered_text(canvas, width, height, 276, 2, "LIVE COUNT", muted);

    let count = model.count().to_string();
    draw_centered_text(canvas, width, height, 392, 10, &count, primary);
    draw_centered_text(
        canvas,
        width,
        height,
        598,
        2,
        if model.tap_pressed() {
            "RELEASE TO INCREMENT"
        } else {
            "TAP THE BUTTON TO COUNT"
        },
        muted,
    );
    draw_centered_text(
        canvas,
        width,
        height,
        tap_button.y as i32 + 27,
        4,
        if model.tap_pressed() {
            "RELEASE"
        } else {
            "TAP"
        },
        primary,
    );
    draw_centered_text(
        canvas,
        width,
        height,
        height as i32 - 168,
        2,
        "Shell pill returns home",
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
        let flipped_row = height.saturating_sub(1).saturating_sub(row);
        for col in x0..x1 {
            let index = ((flipped_row * width + col) * 4) as usize;
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
