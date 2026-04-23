use std::{
    fs, thread,
    time::{Duration, Instant},
};

use shadow_ui_core::{
    app::AppId,
    scene::{HEIGHT, WIDTH},
    shell::ShellEvent,
};
use smithay::{
    backend::input::{Axis, AxisSource, ButtonState},
    input::pointer::{AxisFrame, ButtonEvent, MotionEvent},
    reexports::calloop::{channel, EventLoop},
    utils::{Logical, Point, SERIAL_COUNTER},
};

use crate::touch;

use super::{
    wall_millis, AppTouchGesture, PendingTouchTrace, ScrollBenchmarkSample, ShadowGuestCompositor,
    APP_TOUCH_SCROLL_THRESHOLD, BTN_LEFT,
};

impl ShadowGuestCompositor {
    fn log_touch_handle_latency(&self, event: &touch::TouchInputEvent) {
        if !self.touch_latency_trace {
            return;
        }

        tracing::info!(
            "[shadow-guest-compositor] touch-latency-handle seq={} phase={:?} queue_us={} wall_ms={} normalized={:.3},{:.3}",
            event.sequence,
            event.phase,
            event.captured_at.elapsed().as_micros(),
            wall_millis(),
            event.normalized_x,
            event.normalized_y
        );
    }

    fn finish_touch_dispatch(
        &mut self,
        event: &touch::TouchInputEvent,
        route: &'static str,
        dispatch_started_at: Instant,
    ) {
        if !self.touch_latency_trace {
            return;
        }

        let dispatch_wall_msec = wall_millis();
        let pending = PendingTouchTrace {
            sequence: event.sequence,
            phase: event.phase,
            route,
            input_captured_at: event.captured_at,
            input_wall_msec: event.wall_msec,
            dispatch_started_at,
            dispatch_wall_msec,
            commit_at: None,
        };
        if let Some(previous) = self.pending_touch_trace.replace(pending) {
            tracing::info!(
                "[shadow-guest-compositor] touch-latency-replaced prev_seq={} prev_route={} seq={} route={}",
                previous.sequence,
                previous.route,
                event.sequence,
                route
            );
        }
        tracing::info!(
            "[shadow-guest-compositor] touch-latency-dispatch seq={} route={} phase={:?} handle_to_flush_us={} input_wall_ms={} dispatch_wall_ms={}",
            event.sequence,
            route,
            event.phase,
            dispatch_started_at.elapsed().as_micros(),
            event.wall_msec,
            dispatch_wall_msec
        );
    }

    fn note_scroll_benchmark_sample(
        &mut self,
        event: &touch::TouchInputEvent,
        route: &'static str,
        dispatch_started_at: Instant,
    ) {
        if !self.touch_latency_trace || route != "app-scroll" {
            return;
        }

        self.scroll_benchmark_generation = self.scroll_benchmark_generation.saturating_add(1);
        self.latest_scroll_benchmark_sample = Some(ScrollBenchmarkSample {
            sequence: event.sequence,
            phase: event.phase,
            route,
            generation: self.scroll_benchmark_generation,
            input_captured_at: event.captured_at,
            input_wall_msec: event.wall_msec,
            dispatch_started_at,
        });
    }

    pub(crate) fn insert_hosted_touch_move_frame_source(
        &mut self,
        event_loop: &mut EventLoop<Self>,
    ) {
        let (sender, receiver) = channel::channel();
        self.hosted_touch_move_frame_sender = Some(sender);
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(()) => {
                    if !state.hosted_touch_move_frame_pending {
                        return;
                    }
                    state.hosted_touch_move_frame_pending = false;
                    if state.shell_overlay_visible() {
                        state.publish_visible_shell_frame("hosted-touch-move-frame");
                    }
                }
                channel::Event::Closed => {
                    tracing::warn!(
                        "[shadow-guest-compositor] hosted-touch-move-frame-source closed"
                    )
                }
            })
            .expect("insert hosted touch move frame source");
    }

    fn schedule_hosted_touch_move_frame(&mut self) {
        if !self.shell_overlay_visible() {
            return;
        }
        let Some(sender) = self.hosted_touch_move_frame_sender.clone() else {
            self.publish_visible_shell_frame("hosted-touch-move-frame");
            return;
        };
        if self.hosted_touch_move_frame_pending {
            return;
        }

        self.hosted_touch_move_frame_pending = true;
        if sender.send(()).is_err() {
            self.hosted_touch_move_frame_pending = false;
            tracing::warn!("[shadow-guest-compositor] hosted-touch-move-frame-send failed");
            self.publish_visible_shell_frame("hosted-touch-move-frame");
        }
    }

    fn hosted_app_local_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        self.hosted_app_local_point_with_clamp(position, false)
    }

    fn hosted_app_local_point_clamped(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        self.hosted_app_local_point_with_clamp(position, true)
    }

    fn hosted_app_local_point_with_clamp(
        &self,
        position: Point<f64, Logical>,
        clamp: bool,
    ) -> Option<(f32, f32)> {
        let (origin_x, origin_y) = self.app_window_location();
        let size = self.app_window_size();
        let width = f64::from(size.w.max(0));
        let height = f64::from(size.h.max(0));
        if width <= 0.0 || height <= 0.0 {
            return None;
        }

        let mut local_x = position.x - f64::from(origin_x);
        let mut local_y = position.y - f64::from(origin_y);
        if clamp {
            local_x = local_x.clamp(0.0, (width - 1.0).max(0.0));
            local_y = local_y.clamp(0.0, (height - 1.0).max(0.0));
        } else if !(0.0..=width).contains(&local_x) || !(0.0..=height).contains(&local_y) {
            return None;
        }

        Some((local_x as f32, local_y as f32))
    }

    pub(crate) fn focused_hosted_app(&self) -> Option<AppId> {
        self.focused_app
            .filter(|app_id| self.hosted_apps.contains_key(app_id))
    }

    pub(crate) fn apply_hosted_app_update(
        &mut self,
        app_id: AppId,
        result: std::io::Result<bool>,
    ) -> bool {
        match result {
            Ok(changed) => changed,
            Err(error) => {
                tracing::warn!(
                    "[shadow-guest-compositor] hosted-app-refresh-error app={} error={error}",
                    app_id.as_str()
                );
                self.terminate_app(app_id);
                false
            }
        }
    }

    fn shell_local_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        ((0.0..=WIDTH as f64).contains(&position.x) && (0.0..=HEIGHT as f64).contains(&position.y))
            .then_some((position.x as f32, position.y as f32))
    }

    fn shell_captures_point(&self, position: Point<f64, Logical>) -> Option<(f32, f32)> {
        if !self.shell_overlay_visible() {
            return None;
        }

        let (x, y) = self.shell_local_point(position)?;
        self.shell.captures_point(x, y).then_some((x, y))
    }

    pub(crate) fn handle_control_tap(&mut self, x: i32, y: i32) -> std::io::Result<String> {
        let position = Point::<f64, Logical>::from((f64::from(x), f64::from(y)));
        let time = self.start_time.elapsed().as_millis() as u32;

        if let Some((shell_x, shell_y)) = self
            .shell_captures_point(position)
            .and_then(|_| self.shell_local_point(position))
        {
            tracing::info!(
                "[shadow-guest-compositor] control-tap-shell x={} y={} local_x={:.1} local_y={:.1}",
                x,
                y,
                shell_x,
                shell_y
            );
            self.handle_shell_event(ShellEvent::PointerMoved {
                x: shell_x,
                y: shell_y,
            });
            self.handle_shell_event(ShellEvent::TouchTap {
                x: shell_x,
                y: shell_y,
            });
            self.publish_visible_shell_frame("control-tap-shell-frame");
            return Ok("ok\n".to_string());
        }

        if let Some(app_id) = self.focused_hosted_app() {
            let Some((local_x, local_y)) = self.hosted_app_local_point(position) else {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    format!("tap target {x},{y} is outside the current content"),
                ));
            };
            tracing::info!(
                "[shadow-guest-compositor] control-tap-app x={} y={} hosted=1 app={} local_x={:.1} local_y={:.1}",
                x,
                y,
                app_id.as_str(),
                local_x,
                local_y
            );
            let down = self
                .hosted_apps
                .get_mut(&app_id)
                .expect("hosted app present")
                .handle_pointer_down(local_x, local_y);
            let _ = self.apply_hosted_app_update(app_id, down);
            let up = self
                .hosted_apps
                .get_mut(&app_id)
                .expect("hosted app present")
                .handle_pointer_up(local_x, local_y);
            let _ = self.apply_hosted_app_update(app_id, up);
            self.publish_visible_shell_frame("control-tap-hosted-frame");
            return Ok("ok\n".to_string());
        }

        let Some(under) = self.surface_under(position) else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("tap target {x},{y} is outside the current content"),
            ));
        };

        tracing::info!(
            "[shadow-guest-compositor] control-tap-app x={} y={} surface=true",
            x,
            y
        );
        let serial = SERIAL_COUNTER.next_serial();
        let pointer = self.seat.get_pointer().expect("guest seat pointer");
        self.raise_window_for_pointer_focus(Some(&under.0));
        pointer.motion(
            self,
            Some(under.clone()),
            &MotionEvent {
                location: position,
                serial,
                time,
            },
        );
        pointer.button(
            self,
            &ButtonEvent {
                button: BTN_LEFT,
                state: ButtonState::Pressed,
                serial,
                time,
            },
        );
        pointer.button(
            self,
            &ButtonEvent {
                button: BTN_LEFT,
                state: ButtonState::Released,
                serial,
                time,
            },
        );
        pointer.frame(self);
        self.flush_wayland_clients();
        Ok("ok\n".to_string())
    }

    pub(crate) fn insert_touch_source(&mut self, event_loop: &mut EventLoop<Self>) {
        let touch_device = match touch::detect_touch_device() {
            Ok(device) => device,
            Err(error) => {
                tracing::warn!("[shadow-guest-compositor] touch-unavailable: {error}");
                return;
            }
        };

        tracing::info!(
            "[shadow-guest-compositor] touch-ready device={} name={} range={}..={}x{}..={}",
            touch_device.path.display(),
            touch_device.name,
            touch_device.x_min,
            touch_device.x_max,
            touch_device.y_min,
            touch_device.y_max
        );

        let (sender, receiver) = channel::channel();
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(event) => state.handle_touch_input(event),
                channel::Event::Closed => {
                    tracing::warn!("[shadow-guest-compositor] touch-source closed")
                }
            })
            .expect("insert touch source");
        touch::spawn_touch_reader(touch_device, sender);
    }

    pub(crate) fn insert_synthetic_touch_source(&mut self, event_loop: &mut EventLoop<Self>) {
        if self.synthetic_tap.is_none() {
            return;
        }

        let (sender, receiver) = channel::channel();
        self.synthetic_tap_sender = Some(sender);
        event_loop
            .handle()
            .insert_source(receiver, |event, _, state| match event {
                channel::Event::Msg(event) => {
                    tracing::info!(
                        "[shadow-guest-compositor] synthetic-touch-observed phase={:?} seq={} normalized={:.3},{:.3}",
                        event.phase,
                        event.sequence,
                        event.normalized_x,
                        event.normalized_y
                    );
                    state.handle_touch_input(event);
                }
                channel::Event::Closed => {
                    tracing::warn!("[shadow-guest-compositor] synthetic-touch-source closed")
                }
            })
            .expect("insert synthetic touch source");
    }

    pub(crate) fn schedule_synthetic_touch_after_frame(&mut self, frame_marker: &str) {
        let Some(tap) = self.synthetic_tap else {
            return;
        };
        if self.synthetic_tap_scheduled {
            return;
        }
        let Some(sender) = self.synthetic_tap_sender.clone() else {
            tracing::warn!("[shadow-guest-compositor] synthetic-touch-schedule missing sender");
            return;
        };

        self.synthetic_tap_scheduled = true;
        tracing::info!(
            "[shadow-guest-compositor] synthetic-touch-scheduled frame_marker={} delay_ms={} hold_ms={} normalized_millis={},{}",
            frame_marker,
            tap.after_first_frame_delay_ms,
            tap.hold_ms,
            tap.normalized_x_millis,
            tap.normalized_y_millis
        );
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(tap.after_first_frame_delay_ms));
            let down = touch::synthetic_touch_event(
                touch::TouchPhase::Down,
                tap.normalized_x_millis,
                tap.normalized_y_millis,
            );
            tracing::info!(
                "[shadow-guest-compositor] synthetic-touch-inject phase=Down seq={}",
                down.sequence
            );
            if sender.send(down).is_err() {
                return;
            }
            thread::sleep(Duration::from_millis(tap.hold_ms));
            let up = touch::synthetic_touch_event(
                touch::TouchPhase::Up,
                tap.normalized_x_millis,
                tap.normalized_y_millis,
            );
            tracing::info!(
                "[shadow-guest-compositor] synthetic-touch-inject phase=Up seq={}",
                up.sequence
            );
            let _ = sender.send(up);
        });
    }

    fn handle_touch_input(&mut self, event: touch::TouchInputEvent) {
        self.signal_touch_event(&event);
        self.log_touch_handle_latency(&event);
        let pointer = self.seat.get_pointer().expect("guest seat pointer");
        let serial = SERIAL_COUNTER.next_serial();

        match event.phase {
            touch::TouchPhase::Down | touch::TouchPhase::Move => {
                tracing::info!(
                    "[shadow-guest-compositor] touch-input phase={:?} normalized={:.3},{:.3}",
                    event.phase,
                    event.normalized_x,
                    event.normalized_y
                );
                let Some(position) = self.touch_position(event.normalized_x, event.normalized_y)
                else {
                    if self.shell_touch_active {
                        let dispatch_started_at = Instant::now();
                        self.handle_shell_event(ShellEvent::PointerLeft);
                        self.shell_touch_active = false;
                        self.finish_touch_dispatch(&event, "shell-pointer", dispatch_started_at);
                        self.publish_visible_shell_frame("shell-touch-frame");
                    }
                    if let Some(gesture) = self.app_touch_gesture.take() {
                        if gesture.scrolling {
                            let dispatch_started_at = Instant::now();
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                            pointer.frame(self);
                            self.flush_wayland_clients();
                            self.finish_touch_dispatch(
                                &event,
                                "app-scroll-stop",
                                dispatch_started_at,
                            );
                        }
                    }
                    tracing::info!(
                        "[shadow-guest-compositor] touch-outside-content normalized={:.3},{:.3}",
                        event.normalized_x,
                        event.normalized_y
                    );
                    return;
                };
                let shell_point = self.shell_captures_point(position);
                let shell_handles_touch = match event.phase {
                    touch::TouchPhase::Down => shell_point.is_some(),
                    touch::TouchPhase::Move => self.shell_touch_active,
                    touch::TouchPhase::Up => false,
                };
                if shell_handles_touch {
                    if let Some(gesture) = self.app_touch_gesture.take() {
                        if gesture.scrolling {
                            let dispatch_started_at = Instant::now();
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                            pointer.frame(self);
                            self.flush_wayland_clients();
                            self.finish_touch_dispatch(
                                &event,
                                "app-scroll-stop",
                                dispatch_started_at,
                            );
                        }
                    }
                    let (x, y) = self
                        .shell_local_point(position)
                        .unwrap_or((position.x as f32, position.y as f32));
                    tracing::info!(
                        "[shadow-guest-compositor] touch-shell phase={:?} x={:.1} y={:.1}",
                        event.phase,
                        x,
                        y
                    );
                    let dispatch_started_at = Instant::now();
                    self.handle_shell_event(ShellEvent::PointerMoved { x, y });
                    if matches!(event.phase, touch::TouchPhase::Down) {
                        self.shell_touch_active = true;
                    }
                    self.finish_touch_dispatch(&event, "shell-pointer", dispatch_started_at);
                    self.publish_visible_shell_frame("shell-touch-frame");
                    return;
                }
                self.shell_touch_active = false;
                self.handle_shell_event(ShellEvent::PointerLeft);
                if let Some(app_id) = self.focused_hosted_app() {
                    if self.handle_hosted_touch_input(app_id, &event, position) {
                        return;
                    }
                }
                let under = self.surface_under(position);
                tracing::info!(
                    "[shadow-guest-compositor] touch-pointer phase={:?} x={:.1} y={:.1} surface={}",
                    event.phase,
                    position.x,
                    position.y,
                    under.is_some()
                );
                if under.is_none() && matches!(event.phase, touch::TouchPhase::Down) {
                    self.log_window_state("touch-miss");
                }
                match event.phase {
                    touch::TouchPhase::Down => {
                        if under.is_none() {
                            return;
                        }
                        self.raise_window_for_pointer_focus(
                            under.as_ref().map(|(surface, _)| surface),
                        );
                        pointer.motion(
                            self,
                            under,
                            &MotionEvent {
                                location: position,
                                serial,
                                time: event.time_msec,
                            },
                        );
                        self.app_touch_gesture = Some(AppTouchGesture {
                            start: position,
                            last: position,
                            scrolling: false,
                        });
                        pointer.frame(self);
                        self.flush_wayland_clients();
                    }
                    touch::TouchPhase::Move => {
                        let Some(mut gesture) = self.app_touch_gesture.take() else {
                            return;
                        };
                        let dispatch_started_at = Instant::now();

                        pointer.motion(
                            self,
                            under,
                            &MotionEvent {
                                location: position,
                                serial,
                                time: event.time_msec,
                            },
                        );

                        if !gesture.scrolling
                            && gesture_exceeded_scroll_threshold(gesture.start, position)
                        {
                            gesture.scrolling = true;
                        }

                        if gesture.scrolling {
                            // Touch scrolling should move content with the finger:
                            // dragging up scrolls the page up, dragging down scrolls it down.
                            let delta_x = gesture.last.x - position.x;
                            let delta_y = gesture.last.y - position.y;
                            let mut axis =
                                AxisFrame::new(event.time_msec).source(AxisSource::Finger);
                            if delta_x.abs() > f64::EPSILON {
                                axis = axis.value(Axis::Horizontal, delta_x);
                            }
                            if delta_y.abs() > f64::EPSILON {
                                axis = axis.value(Axis::Vertical, delta_y);
                            }
                            pointer.axis(self, axis);
                        }

                        gesture.last = position;
                        let route = if gesture.scrolling {
                            Some("app-scroll")
                        } else {
                            None
                        };
                        if let Some(route) = route {
                            self.note_scroll_benchmark_sample(&event, route, dispatch_started_at);
                        }
                        self.app_touch_gesture = Some(gesture);
                        pointer.frame(self);
                        self.flush_wayland_clients();
                        if let Some(route) = route {
                            self.finish_touch_dispatch(&event, route, dispatch_started_at);
                        }
                    }
                    touch::TouchPhase::Up => unreachable!(),
                }
            }
            touch::TouchPhase::Up => {
                if self.shell_touch_active {
                    let dispatch_started_at = Instant::now();
                    if let Some(position) =
                        self.touch_position(event.normalized_x, event.normalized_y)
                    {
                        if let Some((x, y)) = self.shell_local_point(position) {
                            tracing::info!(
                                "[shadow-guest-compositor] touch-shell phase=Up x={:.1} y={:.1}",
                                x,
                                y
                            );
                            self.handle_shell_event(ShellEvent::TouchTap { x, y });
                            self.finish_touch_dispatch(&event, "shell-tap", dispatch_started_at);
                        } else {
                            self.handle_shell_event(ShellEvent::PointerLeft);
                            self.finish_touch_dispatch(
                                &event,
                                "shell-pointer",
                                dispatch_started_at,
                            );
                        }
                    } else {
                        self.handle_shell_event(ShellEvent::PointerLeft);
                        self.finish_touch_dispatch(&event, "shell-pointer", dispatch_started_at);
                    }
                    self.shell_touch_active = false;
                    self.publish_visible_shell_frame("shell-touch-frame");
                    return;
                } else {
                    self.handle_shell_event(ShellEvent::PointerLeft);
                }
                tracing::info!("[shadow-guest-compositor] touch-input phase=Up");
                if let Some(app_id) = self.focused_hosted_app() {
                    if let Some(position) =
                        self.touch_position(event.normalized_x, event.normalized_y)
                    {
                        if self.handle_hosted_touch_input(app_id, &event, position) {
                            return;
                        }
                    }
                }
                let mut route = None;
                let dispatch_started_at = Instant::now();
                if let Some(gesture) = self.app_touch_gesture.take() {
                    if let Some(position) =
                        self.touch_position(event.normalized_x, event.normalized_y)
                    {
                        let under = self.surface_under(position);
                        pointer.motion(
                            self,
                            under.clone(),
                            &MotionEvent {
                                location: position,
                                serial,
                                time: event.time_msec,
                            },
                        );
                        if gesture.scrolling {
                            pointer.axis(
                                self,
                                AxisFrame::new(event.time_msec)
                                    .source(AxisSource::Finger)
                                    .stop(Axis::Horizontal)
                                    .stop(Axis::Vertical),
                            );
                            route = Some("app-scroll-stop");
                        } else if under.is_some() {
                            tracing::info!(
                                "[shadow-guest-compositor] touch-app-tap-dispatch seq={} x={:.1} y={:.1}",
                                event.sequence,
                                position.x,
                                position.y
                            );
                            pointer.button(
                                self,
                                &ButtonEvent {
                                    button: BTN_LEFT,
                                    state: ButtonState::Pressed,
                                    serial,
                                    time: event.time_msec,
                                },
                            );
                            pointer.button(
                                self,
                                &ButtonEvent {
                                    button: BTN_LEFT,
                                    state: ButtonState::Released,
                                    serial,
                                    time: event.time_msec,
                                },
                            );
                            route = Some("app-tap");
                        }
                    } else if gesture.scrolling {
                        pointer.axis(
                            self,
                            AxisFrame::new(event.time_msec)
                                .source(AxisSource::Finger)
                                .stop(Axis::Horizontal)
                                .stop(Axis::Vertical),
                        );
                        route = Some("app-scroll-stop");
                    }
                }
                pointer.frame(self);
                self.flush_wayland_clients();
                if let Some(route) = route {
                    self.finish_touch_dispatch(&event, route, dispatch_started_at);
                }
            }
        }
    }

    fn handle_hosted_touch_input(
        &mut self,
        app_id: AppId,
        event: &touch::TouchInputEvent,
        position: Point<f64, Logical>,
    ) -> bool {
        match event.phase {
            touch::TouchPhase::Down => {
                let Some((local_x, local_y)) = self.hosted_app_local_point(position) else {
                    return false;
                };
                tracing::info!(
                    "[shadow-guest-compositor] touch-hosted phase=Down app={} x={:.1} y={:.1}",
                    app_id.as_str(),
                    local_x,
                    local_y
                );
                self.app_touch_gesture = Some(AppTouchGesture {
                    start: position,
                    last: position,
                    scrolling: false,
                });
                let frame = self
                    .hosted_apps
                    .get_mut(&app_id)
                    .expect("hosted app present")
                    .handle_pointer_down(local_x, local_y);
                if self.apply_hosted_app_update(app_id, frame) {
                    self.publish_visible_shell_frame("hosted-touch-down-frame");
                }
                true
            }
            touch::TouchPhase::Move => {
                let Some(mut gesture) = self.app_touch_gesture.take() else {
                    return false;
                };
                let Some((local_x, local_y)) = self.hosted_app_local_point_clamped(position) else {
                    self.app_touch_gesture = Some(gesture);
                    return false;
                };
                let dispatch_started_at = Instant::now();
                let frame = self
                    .hosted_apps
                    .get_mut(&app_id)
                    .expect("hosted app present")
                    .handle_pointer_move(local_x, local_y);
                let frame_changed = self.apply_hosted_app_update(app_id, frame);

                if !gesture.scrolling && gesture_exceeded_scroll_threshold(gesture.start, position)
                {
                    gesture.scrolling = true;
                }

                let route = gesture.scrolling.then_some("app-scroll");
                gesture.last = position;
                self.app_touch_gesture = Some(gesture);

                if let Some(route) = route {
                    self.note_scroll_benchmark_sample(event, route, dispatch_started_at);
                }
                if let Some(route) = route {
                    self.finish_touch_dispatch(event, route, dispatch_started_at);
                }
                if frame_changed {
                    self.schedule_hosted_touch_move_frame();
                }
                true
            }
            touch::TouchPhase::Up => {
                let Some(gesture) = self.app_touch_gesture.take() else {
                    return false;
                };
                let local = self
                    .hosted_app_local_point(position)
                    .or_else(|| self.hosted_app_local_point_clamped(gesture.last));
                let Some((local_x, local_y)) = local else {
                    return false;
                };
                let dispatch_started_at = Instant::now();
                let frame = self
                    .hosted_apps
                    .get_mut(&app_id)
                    .expect("hosted app present")
                    .handle_pointer_up(local_x, local_y);
                let frame_changed = self.apply_hosted_app_update(app_id, frame);
                let route = if gesture.scrolling {
                    Some("app-scroll-stop")
                } else {
                    Some("app-tap")
                };
                if frame_changed {
                    self.publish_visible_shell_frame("hosted-touch-up-frame");
                }
                if let Some(route) = route {
                    self.finish_touch_dispatch(event, route, dispatch_started_at);
                }
                true
            }
        }
    }

    fn touch_position(
        &mut self,
        normalized_x: f64,
        normalized_y: f64,
    ) -> Option<Point<f64, Logical>> {
        let (frame_width, frame_height) = self.last_frame_size?;
        let (panel_width, panel_height) = self.ensure_kms_display()?.dimensions();
        let (x, y) = touch::map_normalized_touch_to_frame(
            normalized_x,
            normalized_y,
            panel_width,
            panel_height,
            frame_width,
            frame_height,
        )?;
        if self.shell_enabled {
            Some(
                (
                    x * f64::from(WIDTH) / f64::from(frame_width),
                    y * f64::from(HEIGHT) / f64::from(frame_height),
                )
                    .into(),
            )
        } else {
            Some((x, y).into())
        }
    }

    fn signal_touch_event(&mut self, event: &touch::TouchInputEvent) {
        if !matches!(event.phase, touch::TouchPhase::Down) {
            return;
        }
        let Some(path) = self.touch_signal_path.as_ref() else {
            return;
        };

        self.touch_signal_counter = self.touch_signal_counter.saturating_add(1);
        let token = self.touch_signal_counter.to_string();
        match fs::write(path, &token) {
            Ok(()) => tracing::info!(
                "[shadow-guest-compositor] touch-signal-write counter={} seq={} wall_ms={} path={} normalized={:.3},{:.3}",
                token,
                event.sequence,
                wall_millis(),
                path.display(),
                event.normalized_x,
                event.normalized_y
            ),
            Err(error) => tracing::warn!(
                "[shadow-guest-compositor] touch-signal-write-failed path={} error={error}",
                path.display()
            ),
        }
    }
}

fn gesture_exceeded_scroll_threshold(
    start: Point<f64, Logical>,
    position: Point<f64, Logical>,
) -> bool {
    let total_dx = position.x - start.x;
    let total_dy = position.y - start.y;
    total_dx.abs() >= APP_TOUCH_SCROLL_THRESHOLD || total_dy.abs() >= APP_TOUCH_SCROLL_THRESHOLD
}

#[cfg(test)]
mod tests {
    use smithay::utils::{Logical, Point};

    use super::gesture_exceeded_scroll_threshold;

    #[test]
    fn scroll_threshold_requires_sufficient_motion() {
        let start = Point::<f64, Logical>::from((10.0, 10.0));
        assert!(!gesture_exceeded_scroll_threshold(
            start,
            (27.9, 10.0).into()
        ));
        assert!(!gesture_exceeded_scroll_threshold(
            start,
            (10.0, 27.9).into()
        ));
    }

    #[test]
    fn scroll_threshold_triggers_on_horizontal_or_vertical_motion() {
        let start = Point::<f64, Logical>::from((10.0, 10.0));
        assert!(gesture_exceeded_scroll_threshold(
            start,
            (28.0, 10.0).into()
        ));
        assert!(gesture_exceeded_scroll_threshold(
            start,
            (10.0, 28.0).into()
        ));
    }
}
