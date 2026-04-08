use std::{
    env, fs,
    path::PathBuf,
    sync::mpsc::{channel, Receiver, Sender},
    task::{Context, Waker},
    thread,
    time::{Duration, Instant},
};

use blitz_dom::{DocGuard, DocGuardMut, Document};
use blitz_html::HtmlDocument;
use blitz_traits::events::UiEvent;
use serde::{Deserialize, Serialize};
use shadow_ui_core::scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX};

use crate::frame::template_document;
use crate::log::{runtime_log, runtime_wall_ms};
use crate::runtime_session::{RuntimeDispatchEvent, RuntimePointerEvent, RuntimeSession};

const STYLE_SELECTOR: &str = "#shadow-blitz-style";
const ROOT_SELECTOR: &str = "#shadow-blitz-root";
const DEBUG_SELECTOR: &str = "#shadow-blitz-debug";
const DEFAULT_SURFACE_WIDTH: u32 = APP_VIEWPORT_WIDTH_PX;
const DEFAULT_SURFACE_HEIGHT: u32 = APP_VIEWPORT_HEIGHT_PX;
const CLICK_CANCEL_DISTANCE_PX: f32 = 8.0;
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct RuntimeDocumentPayload {
    pub html: String,
    pub css: Option<String>,
}

pub struct RuntimeDocument {
    inner: HtmlDocument,
    payload: RuntimeDocumentPayload,
    frame_nodes: FrameNodes,
    debug_state: DebugOverlayState,
    debug_overlay_enabled: bool,
    touch_signal_path: Option<PathBuf>,
    last_touch_signal_token: Option<String>,
    runtime_session: Option<RuntimeSession>,
    pending_runtime_event: Option<RuntimeDispatchEvent>,
    touch_anywhere_target_id: Option<String>,
    armed_pointer_target_id: Option<String>,
    armed_pointer_press_position: Option<(f32, f32)>,
    armed_pointer_dragged: bool,
    skip_next_raw_pointer_release: bool,
    skip_next_ui_pointer_release: bool,
    should_exit: bool,
    timer_started: bool,
    touch_signal_timer_started: bool,
    redraw_requested: bool,
    activate_on_pointer_down: bool,
    timer_tx: Sender<RuntimeTimerEvent>,
    timer_rx: Receiver<RuntimeTimerEvent>,
    #[cfg(test)]
    last_dispatched_runtime_event: Option<RuntimeDispatchEvent>,
}

impl RuntimeDocument {
    pub fn from_env() -> Self {
        match RuntimeSession::from_env() {
            Ok(Some(mut runtime_session)) => {
                let payload = runtime_session
                    .render_document()
                    .unwrap_or_else(|error| panic!("render initial runtime document: {error}"));
                runtime_log("runtime-session-ready");
                Self::with_runtime(payload, Some(runtime_session))
            }
            Ok(None) => panic!(
                "configure runtime session: missing SHADOW_RUNTIME_APP_BUNDLE_PATH and SHADOW_RUNTIME_HOST_BINARY_PATH"
            ),
            Err(error) => panic!("configure runtime session: {error}"),
        }
    }

    fn with_runtime(
        payload: RuntimeDocumentPayload,
        runtime_session: Option<RuntimeSession>,
    ) -> Self {
        let (timer_tx, timer_rx) = channel();
        let inner = template_document();
        let frame_nodes = FrameNodes::resolve(&inner);
        let pending_runtime_event = auto_click_event_from_env(runtime_session.is_some());
        let mut document = Self {
            inner,
            payload,
            frame_nodes,
            debug_state: DebugOverlayState::default(),
            debug_overlay_enabled: debug_overlay_enabled(),
            touch_signal_path: env::var_os("SHADOW_BLITZ_TOUCH_SIGNAL_PATH")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from),
            last_touch_signal_token: None,
            pending_runtime_event,
            runtime_session,
            touch_anywhere_target_id: env::var("SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET")
                .ok()
                .filter(|value| !value.is_empty()),
            armed_pointer_target_id: None,
            armed_pointer_press_position: None,
            armed_pointer_dragged: false,
            skip_next_raw_pointer_release: false,
            skip_next_ui_pointer_release: false,
            should_exit: false,
            timer_started: false,
            touch_signal_timer_started: false,
            redraw_requested: false,
            activate_on_pointer_down: env::var_os("SHADOW_BLITZ_TOUCH_ACTIVATE_ON_DOWN").is_some(),
            timer_tx,
            timer_rx,
            #[cfg(test)]
            last_dispatched_runtime_event: None,
        };
        document.apply_render();
        document.prime_touch_signal();
        if let Some(path) = document.touch_signal_path.as_ref() {
            runtime_log(format!("touch-signal-ready path={}", path.display()));
        }
        runtime_log("runtime-document-ready");
        document
    }

    pub fn should_exit(&self) -> bool {
        self.should_exit
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn replace_document(&mut self, payload: RuntimeDocumentPayload) {
        self.payload = payload;
        self.apply_render();
    }

    fn apply_render(&mut self) {
        let render_start = Instant::now();
        let debug_overlay_html = self.debug_overlay_html();
        let mut mutator = self.inner.mutate();
        mutator.set_inner_html(
            self.frame_nodes.style_id,
            self.payload.css.as_deref().unwrap_or(""),
        );
        mutator.set_inner_html(self.frame_nodes.root_id, &self.payload.html);
        if self.debug_overlay_enabled {
            mutator.set_inner_html(self.frame_nodes.debug_id, &debug_overlay_html);
        } else {
            mutator.set_inner_html(self.frame_nodes.debug_id, "");
        }
        drop(mutator);
        runtime_log(format!(
            "apply-render-dom-updated elapsed_ms={}",
            render_start.elapsed().as_millis()
        ));
        if debug_target_hitmap_enabled() {
            self.log_target_hitmap(&self.touch_signal_target_id());
            runtime_log(format!(
                "apply-render-target-hitmap elapsed_ms={}",
                render_start.elapsed().as_millis()
            ));
        }
        self.debug_dump_render_state();
        runtime_log(format!(
            "apply-render-complete elapsed_ms={}",
            render_start.elapsed().as_millis()
        ));
    }

    fn handle_runtime_ui_event(&mut self, event: UiEvent) {
        match &event {
            UiEvent::PointerDown(pointer) => {
                self.skip_next_raw_pointer_release = false;
                self.debug_state.ui_seen = true;
                eprintln!(
                    "[shadow-runtime-demo] ui-pointer-down x={} y={} primary={}",
                    pointer.client_x(),
                    pointer.client_y(),
                    pointer.is_primary
                );
            }
            UiEvent::PointerMove(pointer) => {
                self.debug_state.ui_seen = true;
                if pointer.is_primary {
                    self.note_pointer_move(pointer.client_x(), pointer.client_y(), "ui");
                }
                eprintln!(
                    "[shadow-runtime-demo] ui-pointer-move x={} y={} primary={}",
                    pointer.client_x(),
                    pointer.client_y(),
                    pointer.is_primary
                );
            }
            UiEvent::PointerUp(pointer) => {
                if self.skip_next_ui_pointer_release {
                    self.skip_next_ui_pointer_release = false;
                    self.skip_next_raw_pointer_release = true;
                    self.clear_armed_pointer_state();
                    self.debug_state.ui_seen = true;
                    eprintln!(
                        "[shadow-runtime-demo] ui-pointer-up-skipped x={} y={} primary={}",
                        pointer.client_x(),
                        pointer.client_y(),
                        pointer.is_primary
                    );
                    return;
                }
                self.skip_next_raw_pointer_release = true;
                self.debug_state.ui_seen = true;
                eprintln!(
                    "[shadow-runtime-demo] ui-pointer-up x={} y={} primary={}",
                    pointer.client_x(),
                    pointer.client_y(),
                    pointer.is_primary
                );
            }
            _ => {}
        }
        let Some(runtime_event) = self.runtime_event_for_ui_event(&event) else {
            return;
        };
        if let Err(error) = self.dispatch_runtime_event(runtime_event, "ui") {
            eprintln!("[shadow-runtime-demo] runtime-event-error: {error}");
        }
    }

    fn runtime_event_for_ui_event(&mut self, event: &UiEvent) -> Option<RuntimeDispatchEvent> {
        match event {
            UiEvent::PointerDown(pointer) => {
                if pointer.is_primary {
                    self.arm_pointer_target(
                        self.arm_target_for_pointer(pointer.client_x(), pointer.client_y(), "ui"),
                        pointer.client_x(),
                        pointer.client_y(),
                    );
                    if self.armed_pointer_target_id.is_some() {
                        self.debug_state.hit_seen = true;
                    }
                    eprintln!(
                        "[shadow-runtime-demo] ui-pointer-armed x={} y={} target={}",
                        pointer.client_x(),
                        pointer.client_y(),
                        self.armed_pointer_target_id.as_deref().unwrap_or("<none>")
                    );
                    if self.activate_on_pointer_down {
                        let Some(target_id) = self.armed_pointer_target_id.take() else {
                            return None;
                        };
                        self.armed_pointer_press_position = None;
                        self.armed_pointer_dragged = false;
                        self.skip_next_ui_pointer_release = true;
                        self.skip_next_raw_pointer_release = true;
                        eprintln!(
                            "[shadow-runtime-demo] ui-pointer-down-activate x={} y={} target={}",
                            pointer.client_x(),
                            pointer.client_y(),
                            target_id
                        );
                        return Some(RuntimeDispatchEvent {
                            target_id,
                            event_type: String::from("click"),
                            value: None,
                            checked: None,
                            selection: None,
                            pointer: Some(RuntimePointerEvent {
                                client_x: Some(pointer.client_x()),
                                client_y: Some(pointer.client_y()),
                                is_primary: Some(pointer.is_primary),
                            }),
                            keyboard: None,
                        });
                    }
                }
                None
            }
            UiEvent::PointerUp(pointer) => {
                if !pointer.is_primary {
                    return None;
                }

                if self.armed_pointer_dragged {
                    eprintln!(
                        "[shadow-runtime-demo] ui-pointer-up-cancelled x={} y={} reason=dragged",
                        pointer.client_x(),
                        pointer.client_y()
                    );
                    self.clear_armed_pointer_state();
                    return None;
                }

                let armed_target_id = self.armed_pointer_target_id.take();
                self.armed_pointer_press_position = None;
                self.armed_pointer_dragged = false;
                let released_target_id =
                    self.shadow_target_id_at(pointer.client_x(), pointer.client_y());
                let Some(target_id) =
                    self.resolve_click_target(armed_target_id.clone(), released_target_id.clone())
                else {
                    eprintln!(
                        "[shadow-runtime-demo] runtime-hit-miss x={} y={} armed={} target={}",
                        pointer.client_x(),
                        pointer.client_y(),
                        armed_target_id.as_deref().unwrap_or("<none>"),
                        released_target_id.as_deref().unwrap_or("<none>")
                    );
                    return None;
                };

                Some(RuntimeDispatchEvent {
                    target_id,
                    event_type: String::from("click"),
                    value: None,
                    checked: None,
                    selection: None,
                    pointer: Some(RuntimePointerEvent {
                        client_x: Some(pointer.client_x()),
                        client_y: Some(pointer.client_y()),
                        is_primary: Some(pointer.is_primary),
                    }),
                    keyboard: None,
                })
            }
            _ => None,
        }
    }

    pub fn handle_raw_pointer_button(
        &mut self,
        pressed: bool,
        is_primary: bool,
        client_x: f32,
        client_y: f32,
    ) {
        if !is_primary {
            return;
        }

        if pressed {
            self.skip_next_raw_pointer_release = false;
            self.debug_state.raw_seen = true;
            self.arm_pointer_target(
                self.arm_target_for_pointer(client_x, client_y, "raw"),
                client_x,
                client_y,
            );
            if self.armed_pointer_target_id.is_some() {
                self.debug_state.hit_seen = true;
            }
            eprintln!(
                "[shadow-runtime-demo] raw-pointer-down x={client_x} y={client_y} target={}",
                self.armed_pointer_target_id.as_deref().unwrap_or("<none>")
            );
            return;
        }

        if self.skip_next_raw_pointer_release {
            self.skip_next_raw_pointer_release = false;
            self.clear_armed_pointer_state();
            eprintln!("[shadow-runtime-demo] raw-pointer-up-skipped x={client_x} y={client_y}");
            return;
        }

        let armed_target_id = self.armed_pointer_target_id.take();
        self.armed_pointer_press_position = None;
        self.armed_pointer_dragged = false;
        let released_target_id = self.shadow_target_id_at(client_x, client_y);
        eprintln!(
            "[shadow-runtime-demo] raw-pointer-up x={client_x} y={client_y} armed={} target={}",
            armed_target_id.as_deref().unwrap_or("<none>"),
            released_target_id.as_deref().unwrap_or("<none>")
        );

        let Some(target_id) =
            self.resolve_click_target(armed_target_id, released_target_id.clone())
        else {
            return;
        };

        let runtime_event = RuntimeDispatchEvent {
            target_id,
            event_type: String::from("click"),
            value: None,
            checked: None,
            selection: None,
            pointer: Some(RuntimePointerEvent {
                client_x: Some(client_x),
                client_y: Some(client_y),
                is_primary: Some(is_primary),
            }),
            keyboard: None,
        };

        if let Err(error) = self.dispatch_runtime_event(runtime_event, "raw") {
            eprintln!("[shadow-runtime-demo] runtime-event-error: {error}");
        }
    }

    fn shadow_target_id_at(&self, x: f32, y: f32) -> Option<String> {
        let hit = self.inner.hit(x, y)?;
        let mut node_id = Some(hit.node_id);

        while let Some(id) = node_id {
            let node = self.inner.get_node(id)?;
            if let Some(target_id) = node.attrs().and_then(|attrs| {
                attrs.iter().find_map(|attr| {
                    (attr.name.local.as_ref() == "data-shadow-id").then_some(attr.value.to_string())
                })
            }) {
                return Some(target_id);
            }
            node_id = node.parent;
        }

        None
    }

    fn dispatch_runtime_event(
        &mut self,
        event: RuntimeDispatchEvent,
        source: &str,
    ) -> Result<bool, String> {
        #[cfg(test)]
        {
            self.last_dispatched_runtime_event = Some(event.clone());
        }

        let Some(runtime_session) = self.runtime_session.as_mut() else {
            return Ok(false);
        };

        runtime_log(format!(
            "runtime-dispatch-start source={} type={} target={} wall_ms={}",
            source,
            event.event_type,
            event.target_id,
            runtime_wall_ms()
        ));
        let payload = runtime_session.dispatch(event.clone())?;
        self.replace_document(payload);
        self.debug_state.click_seen = true;
        self.refresh_debug_overlay();
        self.redraw_requested = true;
        runtime_log(format!(
            "runtime-event-dispatched source={} type={} target={} wall_ms={}",
            source,
            event.event_type,
            event.target_id,
            runtime_wall_ms()
        ));
        Ok(true)
    }

    fn arm_pointer_target(&mut self, target_id: Option<String>, client_x: f32, client_y: f32) {
        self.armed_pointer_target_id = target_id;
        self.armed_pointer_press_position = Some((client_x, client_y));
        self.armed_pointer_dragged = false;
    }

    fn clear_armed_pointer_state(&mut self) {
        self.armed_pointer_target_id = None;
        self.armed_pointer_press_position = None;
        self.armed_pointer_dragged = false;
    }

    fn note_pointer_move(&mut self, client_x: f32, client_y: f32, source: &str) {
        if self.armed_pointer_dragged || self.armed_pointer_target_id.is_none() {
            return;
        }

        let Some((start_x, start_y)) = self.armed_pointer_press_position else {
            return;
        };
        let delta_x = client_x - start_x;
        let delta_y = client_y - start_y;
        if delta_x * delta_x + delta_y * delta_y < CLICK_CANCEL_DISTANCE_PX.powi(2) {
            return;
        }

        self.armed_pointer_dragged = true;
        eprintln!(
            "[shadow-runtime-demo] {source}-pointer-drag-cancelled start={} {} current={} {}",
            start_x, start_y, client_x, client_y
        );
    }

    fn arm_target_for_pointer(&self, client_x: f32, client_y: f32, source: &str) -> Option<String> {
        let hit_target_id = self.shadow_target_id_at(client_x, client_y);
        if hit_target_id.is_some() {
            return hit_target_id;
        }

        let fallback_target_id = self.touch_anywhere_target_id.clone();
        if let Some(target_id) = fallback_target_id.as_deref() {
            eprintln!(
                "[shadow-runtime-demo] {}-pointer-anywhere-fallback x={} y={} target={}",
                source, client_x, client_y, target_id
            );
        }
        fallback_target_id
    }

    fn resolve_click_target(
        &self,
        armed_target_id: Option<String>,
        released_target_id: Option<String>,
    ) -> Option<String> {
        let armed_target_id = armed_target_id?;
        if self.touch_anywhere_target_id.as_deref() == Some(armed_target_id.as_str()) {
            return Some(armed_target_id);
        }
        match released_target_id {
            Some(released_target_id) if released_target_id != armed_target_id => None,
            _ => Some(armed_target_id),
        }
    }

    fn refresh_debug_overlay(&mut self) {
        if !self.debug_overlay_enabled {
            return;
        }
        let debug_overlay_html = self.debug_overlay_html();
        let mut mutator = self.inner.mutate();
        mutator.set_inner_html(self.frame_nodes.debug_id, &debug_overlay_html);
    }

    fn debug_overlay_html(&self) -> String {
        let lane = |name: &str, enabled: bool| {
            format!(
                r#"<span class="shadow-debug-lane {name}{}"></span>"#,
                if enabled { " is-on" } else { "" }
            )
        };

        format!(
            "{}{}{}{}{}",
            lane("signal", self.debug_state.signal_seen),
            lane("raw", self.debug_state.raw_seen),
            lane("ui", self.debug_state.ui_seen),
            lane("hit", self.debug_state.hit_seen),
            lane("click", self.debug_state.click_seen),
        )
    }

    fn log_target_hitmap(&mut self, target_id: &str) {
        let (surface_width, surface_height) = runtime_surface_size();
        let mut inner = self.inner_mut();
        inner.set_viewport(blitz_traits::shell::Viewport::new(
            surface_width,
            surface_height,
            1.0,
            blitz_traits::shell::ColorScheme::Dark,
        ));
        inner.resolve(0.0);
        drop(inner);

        let mut hit_count = 0_u32;
        let mut min_x = u32::MAX;
        let mut min_y = u32::MAX;
        let mut max_x = 0_u32;
        let mut max_y = 0_u32;
        let mut sample = None;

        for y in (0..surface_height).step_by(4) {
            for x in (0..surface_width).step_by(4) {
                if self.shadow_target_id_at(x as f32, y as f32).as_deref() == Some(target_id) {
                    hit_count += 1;
                    min_x = min_x.min(x);
                    min_y = min_y.min(y);
                    max_x = max_x.max(x);
                    max_y = max_y.max(y);
                    sample.get_or_insert((x, y));
                }
            }
        }

        match sample {
            Some((sample_x, sample_y)) => eprintln!(
                "[shadow-runtime-demo] target-hitmap id={} hits={} bbox={}..{},{}..{} sample={},{}",
                target_id, hit_count, min_x, max_x, min_y, max_y, sample_x, sample_y
            ),
            None => eprintln!(
                "[shadow-runtime-demo] target-hitmap id={} hits=0",
                target_id
            ),
        }
    }

    fn ensure_exit_timer_started(&mut self, task_context: Option<&Context<'_>>) {
        let Some(task_context) = task_context else {
            return;
        };

        if self.timer_started {
            return;
        }

        self.timer_started = true;
        let Some(delay) = optional_duration_from_env("SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS") else {
            return;
        };

        spawn_timer(
            self.timer_tx.clone(),
            task_context.waker().clone(),
            delay,
            RuntimeTimerEvent::RequestExit,
        );
    }

    fn ensure_touch_signal_timer_started(&mut self, task_context: Option<&Context<'_>>) {
        if self.touch_signal_timer_started
            || self.touch_signal_path.is_none()
            || !touch_signal_timer_enabled()
        {
            return;
        }
        let Some(task_context) = task_context else {
            return;
        };

        self.touch_signal_timer_started = true;
        spawn_repeating_timer(
            self.timer_tx.clone(),
            task_context.waker().clone(),
            Duration::from_millis(40),
            RuntimeTimerEvent::CheckTouchSignal,
        );
    }

    fn handle_timer_event(&mut self, event: RuntimeTimerEvent) -> bool {
        match event {
            RuntimeTimerEvent::RequestExit => {
                self.should_exit = true;
                eprintln!("[shadow-runtime-demo] exit-requested");
                false
            }
            RuntimeTimerEvent::CheckTouchSignal => self.handle_touch_signal_tick(),
        }
    }

    fn handle_touch_signal_tick(&mut self) -> bool {
        let Some(token) = self.read_touch_signal_token() else {
            return false;
        };
        if self.last_touch_signal_token.as_deref() == Some(token.as_str()) {
            return false;
        }

        self.last_touch_signal_token = Some(token.clone());
        self.debug_state.signal_seen = true;
        self.debug_state.hit_seen = true;
        self.refresh_debug_overlay();
        runtime_log(format!("touch-signal-detected token={token}"));

        let runtime_event = RuntimeDispatchEvent {
            target_id: self.touch_signal_target_id(),
            event_type: String::from("click"),
            value: None,
            checked: None,
            selection: None,
            pointer: None,
            keyboard: None,
        };

        match self.dispatch_runtime_event(runtime_event, "touch-signal") {
            Ok(did_update) => did_update,
            Err(error) => {
                eprintln!("[shadow-runtime-demo] runtime-event-error: {error}");
                false
            }
        }
    }

    pub fn check_touch_signal(&mut self) -> bool {
        self.handle_touch_signal_tick()
    }

    pub fn take_redraw_requested(&mut self) -> bool {
        let redraw_requested = self.redraw_requested;
        self.redraw_requested = false;
        redraw_requested
    }

    fn prime_touch_signal(&mut self) {
        self.last_touch_signal_token = self.read_touch_signal_token();
    }

    fn read_touch_signal_token(&self) -> Option<String> {
        let path = self.touch_signal_path.as_ref()?;
        let token = fs::read_to_string(path).ok()?;
        let token = token.trim();
        (!token.is_empty()).then(|| token.to_string())
    }

    fn touch_signal_target_id(&self) -> String {
        self.touch_anywhere_target_id
            .clone()
            .unwrap_or_else(|| String::from("counter"))
    }
    fn node_outer_html(&self, selector: &str) -> String {
        let node_id = self
            .inner
            .query_selector(selector)
            .expect("parse selector")
            .expect("matching node");
        self.inner
            .get_node(node_id)
            .expect("node by selector")
            .outer_html()
    }

    fn node_text_content(&self, selector: &str) -> String {
        let node_id = self
            .inner
            .query_selector(selector)
            .expect("parse selector")
            .expect("matching node");
        self.inner
            .get_node(node_id)
            .expect("node by selector")
            .text_content()
    }

    fn debug_dump_render_state(&self) {
        if env::var_os("SHADOW_BLITZ_RUNTIME_DEBUG_DUMP").is_none() {
            return;
        }

        let root_html = self.node_outer_html(ROOT_SELECTOR);
        let root_text = self.node_text_content(ROOT_SELECTOR);
        let style_text = self.node_text_content(STYLE_SELECTOR);

        eprintln!(
            "[shadow-runtime-demo] render-debug css_len={} root_html_len={} root_text_len={} root_text_excerpt={:?} root_html_excerpt={:?}",
            style_text.len(),
            root_html.len(),
            root_text.len(),
            truncate_debug(&root_text, 160),
            truncate_debug(&root_html, 200),
        );

        self.debug_dump_node_layout("h1");
        self.debug_dump_node_layout("p");
        self.debug_dump_node_layout("button");
    }

    fn debug_dump_node_layout(&self, selector: &str) {
        let Ok(Some(node_id)) = self.inner.query_selector(selector) else {
            eprintln!("[shadow-runtime-demo] node-layout selector={selector:?} missing");
            return;
        };
        eprintln!(
            "[shadow-runtime-demo] node-layout selector={selector:?} node_id={} text={:?}",
            node_id,
            self.inner.get_node(node_id).map(|node| node.text_content()),
        );
        self.inner.debug_log_node(node_id);
    }

    #[cfg(test)]
    fn point_for_target(&mut self, target_id: &str) -> (f32, f32) {
        let (surface_width, surface_height) = runtime_surface_size();
        let mut inner = self.inner_mut();
        inner.set_viewport(blitz_traits::shell::Viewport::new(
            surface_width,
            surface_height,
            1.0,
            blitz_traits::shell::ColorScheme::Dark,
        ));
        inner.resolve(0.0);
        drop(inner);

        for y in (0..surface_height).step_by(4) {
            for x in (0..surface_width).step_by(4) {
                if self.shadow_target_id_at(x as f32, y as f32).as_deref() == Some(target_id) {
                    return (x as f32, y as f32);
                }
            }
        }

        panic!("no hittable point found for target {target_id}");
    }

    #[cfg(test)]
    fn target_at(&mut self, x: f32, y: f32) -> Option<String> {
        let (surface_width, surface_height) = runtime_surface_size();
        let mut inner = self.inner_mut();
        inner.set_viewport(blitz_traits::shell::Viewport::new(
            surface_width,
            surface_height,
            1.0,
            blitz_traits::shell::ColorScheme::Dark,
        ));
        inner.resolve(0.0);
        drop(inner);

        self.shadow_target_id_at(x, y)
    }

    #[cfg(test)]
    fn scroll_top_for_target(&self, target_id: &str) -> Option<f64> {
        let selector = format!(r#"[data-shadow-id="{target_id}"]"#);
        let node_id = self.inner.query_selector(&selector).ok().flatten()?;
        Some(self.inner.get_node(node_id)?.scroll_offset.y)
    }

    #[cfg(test)]
    fn root_scroll_top(&self) -> Option<f64> {
        let node_id = self.inner.query_selector(ROOT_SELECTOR).ok().flatten()?;
        Some(self.inner.get_node(node_id)?.scroll_offset.y)
    }

    #[cfg(test)]
    fn take_last_runtime_event(&mut self) -> Option<RuntimeDispatchEvent> {
        self.last_dispatched_runtime_event.take()
    }
}

impl Document for RuntimeDocument {
    fn inner(&self) -> DocGuard<'_> {
        self.inner.inner()
    }

    fn inner_mut(&mut self) -> DocGuardMut<'_> {
        self.inner.inner_mut()
    }

    fn handle_ui_event(&mut self, event: UiEvent) {
        self.inner.handle_ui_event(event.clone());
        self.handle_runtime_ui_event(event);
    }

    fn poll(&mut self, task_context: Option<std::task::Context<'_>>) -> bool {
        let task_context = task_context.as_ref();
        self.ensure_exit_timer_started(task_context);
        self.ensure_touch_signal_timer_started(task_context);

        let mut changed = false;
        if let Some(event) = self.pending_runtime_event.take() {
            match self.dispatch_runtime_event(event, "auto") {
                Ok(did_update) => {
                    changed |= did_update;
                }
                Err(error) => {
                    eprintln!("[shadow-runtime-demo] runtime-event-error: {error}");
                }
            }
        }
        while let Ok(event) = self.timer_rx.try_recv() {
            changed |= self.handle_timer_event(event);
        }
        let dirty_payload = if let Some(runtime_session) = self.runtime_session.as_mut() {
            match runtime_session.render_if_dirty() {
                Ok(payload) => payload,
                Err(error) => {
                    eprintln!("[shadow-runtime-demo] runtime-event-error: {error}");
                    None
                }
            }
        } else {
            None
        };
        if let Some(payload) = dirty_payload {
            self.replace_document(payload);
            self.refresh_debug_overlay();
            self.redraw_requested = true;
            runtime_log("runtime-dirty-render-applied");
            changed = true;
        }
        changed
    }
}

struct FrameNodes {
    style_id: usize,
    root_id: usize,
    debug_id: usize,
}

impl FrameNodes {
    fn resolve(document: &HtmlDocument) -> Self {
        let style_id = document
            .query_selector(STYLE_SELECTOR)
            .expect("parse style selector")
            .expect("style node");
        let root_id = document
            .query_selector(ROOT_SELECTOR)
            .expect("parse root selector")
            .expect("root node");
        let debug_id = document
            .query_selector(DEBUG_SELECTOR)
            .expect("parse debug selector")
            .expect("debug node");
        Self {
            style_id,
            root_id,
            debug_id,
        }
    }
}

#[derive(Debug, Default)]
struct DebugOverlayState {
    signal_seen: bool,
    raw_seen: bool,
    ui_seen: bool,
    hit_seen: bool,
    click_seen: bool,
}

#[derive(Clone, Copy, Debug)]
enum RuntimeTimerEvent {
    RequestExit,
    CheckTouchSignal,
}

fn spawn_timer(
    timer_tx: Sender<RuntimeTimerEvent>,
    waker: Waker,
    delay: Duration,
    event: RuntimeTimerEvent,
) {
    thread::spawn(move || {
        thread::sleep(delay);
        let _ = timer_tx.send(event);
        waker.wake_by_ref();
    });
}

fn spawn_repeating_timer(
    timer_tx: Sender<RuntimeTimerEvent>,
    waker: Waker,
    delay: Duration,
    event: RuntimeTimerEvent,
) {
    thread::spawn(move || loop {
        thread::sleep(delay);
        if timer_tx.send(event).is_err() {
            break;
        }
        waker.wake_by_ref();
    });
}

fn optional_duration_from_env(key: &str) -> Option<Duration> {
    let value = env::var(key).ok()?;
    if value.is_empty() {
        return None;
    }

    value.parse::<u64>().ok().map(Duration::from_millis)
}

fn debug_overlay_enabled() -> bool {
    !matches!(
        env::var("SHADOW_BLITZ_DEBUG_OVERLAY").ok().as_deref(),
        Some("0") | Some("false") | Some("off")
    )
}

fn debug_target_hitmap_enabled() -> bool {
    env::var_os("SHADOW_BLITZ_DEBUG_TARGET_HITMAP").is_some()
}

fn touch_signal_timer_enabled() -> bool {
    matches!(
        env::var("SHADOW_BLITZ_TOUCH_SIGNAL_TIMER").ok().as_deref(),
        Some("1") | Some("true") | Some("on")
    )
}

fn auto_click_event_from_env(runtime_session_enabled: bool) -> Option<RuntimeDispatchEvent> {
    if !runtime_session_enabled {
        return None;
    }

    let target_id = env::var("SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET").ok()?;
    if target_id.is_empty() {
        return None;
    }

    Some(RuntimeDispatchEvent {
        target_id,
        event_type: String::from("click"),
        value: None,
        checked: None,
        selection: None,
        pointer: None,
        keyboard: None,
    })
}

fn truncate_debug(value: &str, max_chars: usize) -> String {
    let mut chars = value.chars();
    let truncated: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{truncated}...")
    } else {
        truncated
    }
}

fn runtime_surface_size() -> (u32, u32) {
    (
        runtime_surface_dimension("SHADOW_BLITZ_SURFACE_WIDTH", DEFAULT_SURFACE_WIDTH),
        runtime_surface_dimension("SHADOW_BLITZ_SURFACE_HEIGHT", DEFAULT_SURFACE_HEIGHT),
    )
}

fn runtime_surface_dimension(key: &str, default: u32) -> u32 {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}
#[cfg(test)]
mod tests {
    use std::sync::{Mutex, MutexGuard};

    use blitz_dom::Document as _;
    use blitz_traits::events::{
        BlitzPointerEvent, BlitzPointerId, BlitzWheelDelta, BlitzWheelEvent, MouseEventButton,
        MouseEventButtons, PointerCoords, UiEvent,
    };

    use super::{RuntimeDocument, RuntimeDocumentPayload};
    use shadow_ui_core::scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX};

    fn test_guard() -> MutexGuard<'static, ()> {
        static TEST_MUTEX: Mutex<()> = Mutex::new(());
        TEST_MUTEX
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn pointer_coords(client_x: f32, client_y: f32) -> PointerCoords {
        PointerCoords {
            page_x: client_x,
            page_y: client_y,
            screen_x: client_x,
            screen_y: client_y,
            client_x,
            client_y,
        }
    }

    fn pointer_event(
        id: BlitzPointerId,
        button: MouseEventButton,
        buttons: MouseEventButtons,
        client_x: f32,
        client_y: f32,
    ) -> BlitzPointerEvent {
        BlitzPointerEvent {
            id,
            is_primary: true,
            coords: pointer_coords(client_x, client_y),
            button,
            buttons,
            mods: Default::default(),
            details: Default::default(),
        }
    }

    fn scrollable_payload() -> RuntimeDocumentPayload {
        RuntimeDocumentPayload {
            html: String::from(
                r#"<main style="width:100%;height:100%;display:block;background:#020617"><section data-shadow-id="scroller" style="width:100%;height:100%;overflow-y:auto;display:block"><div style="height:2400px;background:linear-gradient(180deg,#38bdf8 0%,#0f172a 100%)"></div></section></main>"#,
            ),
            css: None,
        }
    }

    fn root_scroll_payload() -> RuntimeDocumentPayload {
        RuntimeDocumentPayload {
            html: String::from(
                r#"<main style="width:100%;display:block;background:#020617"><div data-shadow-id="content" style="width:100%;height:2400px;background:linear-gradient(180deg,#38bdf8 0%,#0f172a 100%)"></div></main>"#,
            ),
            css: None,
        }
    }

    #[test]
    fn runtime_document_renders_initial_payload_into_fixed_frame() {
        let _guard = test_guard();
        let payload = RuntimeDocumentPayload {
            html: String::from(r#"<section class="screen"><h1>Hello</h1></section>"#),
            css: Some(String::from("body { color: red; }")),
        };
        let document = RuntimeDocument::with_runtime(payload.clone(), None);

        assert_eq!(
            document.node_text_content("#shadow-blitz-style"),
            "body { color: red; }"
        );
        assert_eq!(
            document.node_outer_html("#shadow-blitz-root"),
            format!(r#"<main id="shadow-blitz-root">{}</main>"#, payload.html)
        );
    }

    #[test]
    fn runtime_document_replaces_style_and_root_content() {
        let _guard = test_guard();
        let mut document = RuntimeDocument::with_runtime(
            RuntimeDocumentPayload {
                html: String::from("<p>Before</p>"),
                css: Some(String::from("body { color: red; }")),
            },
            None,
        );

        document.replace_document(RuntimeDocumentPayload {
            html: String::from(r#"<article data-app="next">After</article>"#),
            css: None,
        });

        assert_eq!(document.node_text_content("#shadow-blitz-style"), "");
        assert_eq!(
            document.node_outer_html("#shadow-blitz-root"),
            r#"<main id="shadow-blitz-root"><article data-app="next">After</article></main>"#
        );
    }

    #[test]
    fn raw_pointer_click_arms_on_press_and_disarms_on_release() {
        let _guard = test_guard();
        let mut document = RuntimeDocument::with_runtime(
            RuntimeDocumentPayload {
                html: String::from(r#"<button data-shadow-id="counter">Count 1</button>"#),
                css: None,
            },
            None,
        );
        let (client_x, client_y) = document.point_for_target("counter");

        document.handle_raw_pointer_button(true, true, client_x, client_y);
        assert_eq!(document.armed_pointer_target_id.as_deref(), Some("counter"));

        document.handle_raw_pointer_button(false, true, client_x, client_y);
        assert_eq!(document.armed_pointer_target_id, None);
    }

    #[test]
    fn release_target_none_still_clicks_armed_target() {
        let _guard = test_guard();
        assert_eq!(
            RuntimeDocument::with_runtime(
                RuntimeDocumentPayload {
                    html: String::new(),
                    css: None,
                },
                None
            )
            .resolve_click_target(Some(String::from("counter")), None),
            Some(String::from("counter"))
        );
    }

    #[test]
    fn release_target_mismatch_cancels_click() {
        let _guard = test_guard();
        assert_eq!(
            RuntimeDocument::with_runtime(
                RuntimeDocumentPayload {
                    html: String::new(),
                    css: None,
                },
                None
            )
            .resolve_click_target(Some(String::from("counter")), Some(String::from("other"))),
            None
        );
    }

    #[test]
    fn card_target_hits_multiple_points_inside_card() {
        let _guard = test_guard();
        let mut document = RuntimeDocument::with_runtime(
            RuntimeDocumentPayload {
                html: String::from(
                    r#"<main style="width:100%;height:100%;display:flex;justify-content:center;align-items:center;background:#10293a"><section data-shadow-id="counter" style="display:block;width:280px;height:240px;background:#2fb8ff"></section></main>"#,
                ),
                css: None,
            },
            None,
        );

        let surface_width = APP_VIEWPORT_WIDTH_PX as f32;
        let surface_height = APP_VIEWPORT_HEIGHT_PX as f32;
        let card_left = (surface_width - 280.0) / 2.0;
        let card_top = (surface_height - 240.0) / 2.0;

        for (x, y) in [
            (card_left + 32.0, card_top + 32.0),
            (card_left + 140.0, card_top + 120.0),
            (card_left + 248.0, card_top + 208.0),
        ] {
            assert_eq!(document.target_at(x, y).as_deref(), Some("counter"));
        }
    }

    #[test]
    fn wheel_scrolls_overflow_container_without_runtime_dispatch() {
        let _guard = test_guard();
        let mut document = RuntimeDocument::with_runtime(scrollable_payload(), None);
        let client_x = APP_VIEWPORT_WIDTH_PX as f32 / 2.0;
        let client_y = APP_VIEWPORT_HEIGHT_PX as f32 / 2.0;

        assert_eq!(
            document.target_at(client_x, client_y).as_deref(),
            Some("scroller")
        );
        document.handle_ui_event(UiEvent::PointerMove(pointer_event(
            BlitzPointerId::Mouse,
            MouseEventButton::Main,
            MouseEventButtons::None,
            client_x,
            client_y,
        )));

        document.handle_ui_event(UiEvent::Wheel(BlitzWheelEvent {
            delta: BlitzWheelDelta::Pixels(0.0, -180.0),
            coords: pointer_coords(client_x, client_y),
            buttons: MouseEventButtons::None,
            mods: Default::default(),
        }));

        assert!(
            document
                .scroll_top_for_target("scroller")
                .unwrap_or_default()
                > 0.0,
            "wheel should advance the scroll container"
        );
        assert!(document.take_last_runtime_event().is_none());
    }

    #[test]
    fn finger_pan_scrolls_without_runtime_click() {
        let _guard = test_guard();
        let mut document = RuntimeDocument::with_runtime(scrollable_payload(), None);
        let client_x = APP_VIEWPORT_WIDTH_PX as f32 / 2.0;
        let client_y = APP_VIEWPORT_HEIGHT_PX as f32 / 2.0;

        assert_eq!(
            document.target_at(client_x, client_y).as_deref(),
            Some("scroller")
        );
        document.handle_ui_event(UiEvent::PointerDown(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::Primary,
            client_x,
            client_y,
        )));
        document.handle_ui_event(UiEvent::PointerMove(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::Primary,
            client_x,
            client_y - 96.0,
        )));
        document.handle_ui_event(UiEvent::PointerMove(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::Primary,
            client_x,
            client_y - 192.0,
        )));
        document.handle_ui_event(UiEvent::PointerUp(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::None,
            client_x,
            client_y - 192.0,
        )));

        assert!(
            document
                .scroll_top_for_target("scroller")
                .unwrap_or_default()
                > 0.0,
            "touch pan should advance the scroll container"
        );
        assert!(document.take_last_runtime_event().is_none());
    }

    #[test]
    fn finger_pan_scrolls_root_without_explicit_scroll_container() {
        let _guard = test_guard();
        let mut document = RuntimeDocument::with_runtime(root_scroll_payload(), None);
        let client_x = APP_VIEWPORT_WIDTH_PX as f32 / 2.0;
        let client_y = APP_VIEWPORT_HEIGHT_PX as f32 / 2.0;

        assert_eq!(
            document.target_at(client_x, client_y).as_deref(),
            Some("content")
        );
        document.handle_ui_event(UiEvent::PointerDown(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::Primary,
            client_x,
            client_y,
        )));
        document.handle_ui_event(UiEvent::PointerMove(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::Primary,
            client_x,
            client_y - 96.0,
        )));
        document.handle_ui_event(UiEvent::PointerMove(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::Primary,
            client_x,
            client_y - 192.0,
        )));
        document.handle_ui_event(UiEvent::PointerUp(pointer_event(
            BlitzPointerId::Finger(1),
            MouseEventButton::Main,
            MouseEventButtons::None,
            client_x,
            client_y - 192.0,
        )));

        assert!(
            document.root_scroll_top().unwrap_or_default() > 0.0,
            "touch pan should advance the root scroll container"
        );
        assert!(document.take_last_runtime_event().is_none());
    }

    #[test]
    fn pointer_tap_dispatches_runtime_click() {
        let _guard = test_guard();
        let mut document = RuntimeDocument::with_runtime(
            RuntimeDocumentPayload {
                html: String::from(r#"<button data-shadow-id="counter">Count 1</button>"#),
                css: None,
            },
            None,
        );
        let (client_x, client_y) = document.point_for_target("counter");

        document.handle_ui_event(UiEvent::PointerDown(pointer_event(
            BlitzPointerId::Mouse,
            MouseEventButton::Main,
            MouseEventButtons::Primary,
            client_x,
            client_y,
        )));
        document.handle_ui_event(UiEvent::PointerUp(pointer_event(
            BlitzPointerId::Mouse,
            MouseEventButton::Main,
            MouseEventButtons::None,
            client_x,
            client_y,
        )));

        let runtime_event = document.take_last_runtime_event().expect("runtime click");
        assert_eq!(runtime_event.event_type, "click");
        assert_eq!(runtime_event.target_id, "counter");
    }
}
