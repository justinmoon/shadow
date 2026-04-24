use std::time::{Duration, Instant};

use chrono::{DateTime, Local};
use shadow_runtime_protocol::SystemPromptRequest;

use crate::{
    app::{find_app, find_app_by_str, home_apps, AppId},
    color::{
        BACKGROUND, SURFACE, SURFACE_ACCENT, SURFACE_GLASS, SURFACE_RAISED, TEXT_MUTED,
        TEXT_PRIMARY,
    },
    scene::{
        RoundedRect, Scene, TextAlign, TextBlock, TextWeight, APP_VIEWPORT_HEIGHT,
        APP_VIEWPORT_WIDTH, APP_VIEWPORT_X, APP_VIEWPORT_Y, HEIGHT, WIDTH,
    },
    system_chrome::{
        append_bottom_navigation_pill, append_top_chrome_strip, BottomNavigationPillState,
        TopChromeStripState, BOTTOM_NAVIGATION_PILL_HEIGHT, BOTTOM_NAVIGATION_PILL_WIDTH,
        BOTTOM_NAVIGATION_PILL_X, BOTTOM_NAVIGATION_PILL_Y, TOP_CHROME_STRIP_HEIGHT,
        TOP_CHROME_STRIP_WIDTH, TOP_CHROME_STRIP_X, TOP_CHROME_STRIP_Y,
    },
    system_prompt::{system_prompt_action_frame, system_prompt_scene},
};

const PRESS_FLASH: Duration = Duration::from_millis(160);
const CLOCK_CARD_X: f32 = 20.0;
const CLOCK_CARD_Y: f32 = 124.0;
const CLOCK_CARD_WIDTH: f32 = 236.0;
const CLOCK_CARD_HEIGHT: f32 = 250.0;
const RECENTS_PANEL_X: f32 = 268.0;
const RECENTS_PANEL_Y: f32 = CLOCK_CARD_Y;
const RECENTS_PANEL_WIDTH: f32 = 252.0;
const RECENTS_PANEL_HEIGHT: f32 = CLOCK_CARD_HEIGHT;
const APP_PANEL_Y: f32 = 420.0;
const APP_PANEL_HEIGHT: f32 = 640.0;
const SWITCHER_PANEL_X: f32 = 44.0;
const SWITCHER_PANEL_Y: f32 = 164.0;
const SWITCHER_PANEL_WIDTH: f32 = 452.0;
const SWITCHER_PANEL_HEIGHT: f32 = 346.0;
const SWITCHER_ROW_HEIGHT: f32 = 54.0;
const SWITCHER_ROW_GAP: f32 = 12.0;
const APP_ICON_SIZE: f32 = 96.0;
const APP_LABEL_HEIGHT: f32 = 24.0;
const APP_SUBTITLE_HEIGHT: f32 = 18.0;
const GRID_COLUMNS: usize = 4;
const APP_GRID_SPACING_X: f32 = 18.0;
const APP_GRID_STEP_X: f32 = APP_ICON_SIZE + APP_GRID_SPACING_X + 8.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NavAction {
    Left,
    Right,
    Up,
    Down,
    Next,
    Previous,
    Activate,
    Home,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointerButtonState {
    Pressed,
    Released,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ShellEvent {
    PointerMoved { x: f32, y: f32 },
    PointerLeft,
    PointerButton(PointerButtonState),
    TouchTap { x: f32, y: f32 },
    Navigate(NavAction),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShellAction {
    Launch { app_id: AppId },
    Home,
    SystemPromptResponse { action_id: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShellStatus {
    pub time_label: String,
    pub date_label: String,
    pub battery_percent: u8,
    pub wifi_strength: u8,
}

impl ShellStatus {
    pub fn demo(now: DateTime<Local>) -> Self {
        Self {
            time_label: now.format("%H:%M").to_string(),
            date_label: now.format("%A, %B %-d").to_string(),
            battery_percent: 78,
            wifi_strength: 3,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Point {
    x: f32,
    y: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Frame {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

impl Frame {
    fn contains(self, point: Point) -> bool {
        point.x >= self.x
            && point.x <= self.x + self.w
            && point.y >= self.y
            && point.y <= self.y + self.h
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Target {
    App(usize),
    Recent(AppId),
    HomeIndicator,
    SwitcherBackdrop,
    PromptAction(usize),
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct SystemPromptUiState {
    request: SystemPromptRequest,
    focused_action: usize,
}

pub struct ShellModel {
    cursor: Option<Point>,
    hovered_target: Option<Target>,
    pressed_target: Option<Target>,
    focused_tile: usize,
    last_activated: Option<(Target, Instant)>,
    running_apps: Vec<AppId>,
    recent_apps: Vec<AppId>,
    foreground_app: Option<AppId>,
    switcher_visible: bool,
    switcher_focus: usize,
    system_prompt: Option<SystemPromptUiState>,
}

impl Default for ShellModel {
    fn default() -> Self {
        Self {
            cursor: None,
            hovered_target: None,
            pressed_target: None,
            focused_tile: first_launchable_tile(),
            last_activated: None,
            running_apps: Vec::new(),
            recent_apps: Vec::new(),
            foreground_app: None,
            switcher_visible: false,
            switcher_focus: 0,
            system_prompt: None,
        }
    }
}

impl ShellModel {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn handle(&mut self, event: ShellEvent) -> Option<ShellAction> {
        match event {
            ShellEvent::PointerMoved { x, y } => {
                let point = Point { x, y };
                self.cursor = Some(point);
                self.hovered_target = self.hit_test(point);
                None
            }
            ShellEvent::PointerLeft => {
                self.cursor = None;
                self.hovered_target = None;
                self.pressed_target = None;
                None
            }
            ShellEvent::PointerButton(state) => self.pointer_button(state),
            ShellEvent::TouchTap { x, y } => self.touch_tap(Point { x, y }),
            ShellEvent::Navigate(action) => self.navigate(action),
        }
    }

    pub fn scene(&mut self, status: &ShellStatus) -> Scene {
        self.trim_expired_flash();
        let mut scene = self.current_scene(status, !self.switcher_overlay_active());
        if let Some(switcher_scene) = self.switcher_scene() {
            append_scene(&mut scene, switcher_scene);
        }
        if self.switcher_overlay_active() {
            append_top_chrome_strip(
                &mut scene.rects,
                &mut scene.texts,
                &self.top_chrome_strip_state(status),
            );
            append_bottom_navigation_pill(&mut scene.rects, self.bottom_navigation_pill_state());
        }
        if let Some(prompt_state) = self.system_prompt.as_ref() {
            append_scene(
                &mut scene,
                system_prompt_scene(
                    &prompt_state.request,
                    &self.system_prompt_app_label(prompt_state.request.source_app_id.as_str()),
                    prompt_state.focused_action,
                    self.hovered_prompt_action(),
                    self.pressed_prompt_action(),
                    self.last_activated_prompt_action(),
                ),
            );
        }
        scene
    }

    pub fn scene_without_compositor_chrome(&mut self, status: &ShellStatus) -> Scene {
        self.trim_expired_flash();

        let mut scene = self.current_scene(status, false);
        if let Some(switcher_scene) = self.switcher_scene() {
            append_scene(&mut scene, switcher_scene);
        }
        scene
    }

    pub fn base_scene(&mut self) -> Scene {
        self.trim_expired_flash();

        if self.foreground_app.is_some() {
            Scene {
                clear_color: crate::color::Color::rgba(0, 0, 0, 0),
                rects: Vec::new(),
                texts: Vec::new(),
            }
        } else {
            Scene {
                clear_color: BACKGROUND,
                rects: Vec::new(),
                texts: Vec::new(),
            }
        }
    }

    pub fn home_launcher_scene(&mut self, status: &ShellStatus) -> Option<Scene> {
        self.trim_expired_flash();
        self.foreground_app
            .is_none()
            .then(|| self.home_launcher_scene_only(status))
    }

    pub fn top_chrome_strip_state(&self, status: &ShellStatus) -> TopChromeStripState {
        TopChromeStripState {
            time_label: status.time_label.clone(),
            battery_percent: status.battery_percent,
            wifi_strength: status.wifi_strength,
            home_enabled: self.home_indicator_active(),
        }
    }

    pub fn bottom_navigation_pill_state(&self) -> BottomNavigationPillState {
        BottomNavigationPillState {
            active: self.home_indicator_active(),
        }
    }

    fn current_scene(&self, status: &ShellStatus, include_compositor_chrome: bool) -> Scene {
        if let Some(app_id) = self.foreground_app {
            return self.app_scene(status, app_id, include_compositor_chrome);
        }

        self.home_scene(status, include_compositor_chrome)
    }

    pub fn captures_point(&self, x: f32, y: f32) -> bool {
        let point = Point { x, y };

        if self.system_prompt.is_some() {
            return shell_frame().contains(point);
        }

        if self.switcher_overlay_active() {
            return shell_frame().contains(point);
        }

        if self.foreground_app.is_some() {
            !app_viewport_frame().contains(point)
                || home_indicator_frame().contains(point)
                || bottom_navigation_pill_frame().contains(point)
        } else {
            shell_frame().contains(point)
        }
    }

    fn home_scene(&self, status: &ShellStatus, include_compositor_chrome: bool) -> Scene {
        let mut rects = Vec::new();
        let mut texts = Vec::new();

        append_home_launcher(&mut rects, &mut texts, status, self);

        if include_compositor_chrome {
            append_top_chrome_strip(&mut rects, &mut texts, &self.top_chrome_strip_state(status));
            append_bottom_navigation_pill(&mut rects, self.bottom_navigation_pill_state());
        }

        Scene {
            clear_color: BACKGROUND,
            rects,
            texts,
        }
    }

    fn home_launcher_scene_only(&self, status: &ShellStatus) -> Scene {
        let mut rects = Vec::new();
        let mut texts = Vec::new();
        append_home_launcher(&mut rects, &mut texts, status, self);

        Scene {
            clear_color: crate::color::Color::rgba(0, 0, 0, 0),
            rects,
            texts,
        }
    }

    fn app_scene(
        &self,
        status: &ShellStatus,
        app_id: AppId,
        include_compositor_chrome: bool,
    ) -> Scene {
        let mut rects = Vec::new();
        let mut texts = Vec::new();
        let _app = find_app(app_id).expect("foreground app metadata");

        if include_compositor_chrome {
            append_top_chrome_strip(&mut rects, &mut texts, &self.top_chrome_strip_state(status));
            append_bottom_navigation_pill(&mut rects, self.bottom_navigation_pill_state());
        }

        Scene {
            clear_color: crate::color::Color::rgba(0, 0, 0, 0),
            rects,
            texts,
        }
    }

    pub fn set_app_running(&mut self, app_id: AppId, running: bool) {
        if running {
            if !self.running_apps.contains(&app_id) {
                self.running_apps.push(app_id);
            }
            self.touch_recent(app_id);
        } else {
            self.running_apps.retain(|candidate| *candidate != app_id);
            self.recent_apps.retain(|candidate| *candidate != app_id);
            if self.foreground_app == Some(app_id) {
                self.foreground_app = None;
                self.dismiss_switcher_overlay();
            }
            self.switcher_focus = self.normalized_switcher_focus();
        }
    }

    pub fn set_foreground_app(&mut self, app_id: Option<AppId>) {
        self.foreground_app = app_id;
        self.dismiss_switcher_overlay();
        if let Some(app_id) = app_id {
            self.set_app_running(app_id, true);
            self.focus_app_tile(app_id);
        }
    }

    pub fn foreground_app(&self) -> Option<AppId> {
        self.foreground_app
    }

    pub fn set_system_prompt(&mut self, request: Option<SystemPromptRequest>) {
        if request.is_some() {
            self.dismiss_switcher_overlay();
        }
        self.system_prompt = request.map(|request| {
            let focused_action = request
                .actions
                .iter()
                .position(|action| {
                    matches!(
                        action.style,
                        shadow_runtime_protocol::SystemPromptActionStyle::Default
                    )
                })
                .unwrap_or(0);
            SystemPromptUiState {
                request,
                focused_action,
            }
        });
        self.hovered_target = None;
        self.pressed_target = None;
        self.cursor = None;
    }

    pub fn system_prompt_request(&self) -> Option<&SystemPromptRequest> {
        self.system_prompt.as_ref().map(|prompt| &prompt.request)
    }

    pub fn system_prompt_scene(&self) -> Option<Scene> {
        let prompt_state = self.system_prompt.as_ref()?;
        Some(system_prompt_scene(
            &prompt_state.request,
            &self.system_prompt_app_label(prompt_state.request.source_app_id.as_str()),
            prompt_state.focused_action,
            self.hovered_prompt_action(),
            self.pressed_prompt_action(),
            self.last_activated_prompt_action(),
        ))
    }

    pub fn running_apps(&self) -> &[AppId] {
        &self.running_apps
    }

    pub fn show_switcher_overlay(&mut self) -> bool {
        if self.foreground_app.is_none() || self.system_prompt.is_some() {
            return false;
        }

        self.switcher_visible = true;
        self.switcher_focus = self.default_switcher_focus();
        self.hovered_target = None;
        self.pressed_target = None;
        self.cursor = None;
        true
    }

    pub fn switcher_overlay_active(&self) -> bool {
        self.switcher_visible && self.foreground_app.is_some() && self.system_prompt.is_none()
    }

    pub fn switcher_scene(&self) -> Option<Scene> {
        self.switcher_overlay_active()
            .then(|| self.switcher_scene_only())
    }

    pub fn switcher_target_app(&self) -> Option<AppId> {
        self.recent_apps
            .iter()
            .copied()
            .find(|app_id| Some(*app_id) != self.foreground_app)
    }

    fn app_is_running(&self, app_id: AppId) -> bool {
        self.running_apps.contains(&app_id)
    }

    fn app_is_foreground(&self, app_id: AppId) -> bool {
        self.foreground_app == Some(app_id)
    }

    fn home_indicator_active(&self) -> bool {
        self.foreground_app.is_some()
    }

    fn pointer_button(&mut self, state: PointerButtonState) -> Option<ShellAction> {
        match state {
            PointerButtonState::Pressed => {
                self.pressed_target = self.cursor.and_then(|point| self.hit_test(point));
                match self.pressed_target {
                    Some(Target::App(index)) => self.focused_tile = index,
                    Some(Target::Recent(app_id)) => self.focus_recent_target(app_id),
                    Some(Target::PromptAction(index)) => {
                        if let Some(prompt) = self.system_prompt.as_mut() {
                            prompt.focused_action = index;
                        }
                    }
                    _ => {}
                }
                None
            }
            PointerButtonState::Released => {
                let target = self.cursor.and_then(|point| self.hit_test(point));
                let pressed = self.pressed_target.take();
                self.hovered_target = target;

                match (pressed, target) {
                    (Some(lhs), Some(rhs)) if lhs == rhs => self.activate_target(rhs),
                    _ => None,
                }
            }
        }
    }

    fn touch_tap(&mut self, point: Point) -> Option<ShellAction> {
        self.cursor = None;
        self.hovered_target = None;
        self.pressed_target = None;

        let target = self.hit_test(point);
        match target {
            Some(Target::App(index)) => self.focused_tile = index,
            Some(Target::Recent(app_id)) => self.focus_recent_target(app_id),
            Some(Target::PromptAction(index)) => {
                if let Some(prompt) = self.system_prompt.as_mut() {
                    prompt.focused_action = index;
                }
            }
            _ => {}
        }

        target.and_then(|target| self.activate_target(target))
    }

    fn navigate(&mut self, action: NavAction) -> Option<ShellAction> {
        if let Some(prompt) = self.system_prompt.as_mut() {
            let count = prompt.request.actions.len();
            if count == 0 {
                return None;
            }
            let mut activate_action = None;
            match action {
                NavAction::Left | NavAction::Previous => {
                    prompt.focused_action = wrap_prompt_index(prompt.focused_action, count, -1)
                }
                NavAction::Right | NavAction::Next => {
                    prompt.focused_action = wrap_prompt_index(prompt.focused_action, count, 1)
                }
                NavAction::Up => prompt.focused_action = 0,
                NavAction::Down => prompt.focused_action = count.saturating_sub(1),
                NavAction::Activate => activate_action = Some(prompt.focused_action),
                NavAction::Home => return None,
            }
            if let Some(index) = activate_action {
                return self.activate_target(Target::PromptAction(index));
            }
            return None;
        }

        if self.switcher_overlay_active() {
            match action {
                NavAction::Left | NavAction::Up | NavAction::Previous => {
                    self.cycle_switcher_focus(-1)
                }
                NavAction::Right | NavAction::Down | NavAction::Next => {
                    self.cycle_switcher_focus(1)
                }
                NavAction::Activate => {
                    let app_id = self.switcher_selection()?;
                    self.focus_recent_target(app_id);
                    return self.activate_target(Target::Recent(app_id));
                }
                NavAction::Home => return self.activate_target(Target::HomeIndicator),
            }
            return None;
        }

        match action {
            NavAction::Left => self.focused_tile = move_focus(self.focused_tile, -1, 0),
            NavAction::Right => self.focused_tile = move_focus(self.focused_tile, 1, 0),
            NavAction::Up => self.focused_tile = move_focus(self.focused_tile, 0, -1),
            NavAction::Down => self.focused_tile = move_focus(self.focused_tile, 0, 1),
            NavAction::Next => self.focused_tile = wrap_index(self.focused_tile, 1),
            NavAction::Previous => self.focused_tile = wrap_index(self.focused_tile, -1),
            NavAction::Activate => return self.activate_target(Target::App(self.focused_tile)),
            NavAction::Home => return self.activate_target(Target::HomeIndicator),
        }
        None
    }

    fn activate_target(&mut self, target: Target) -> Option<ShellAction> {
        self.last_activated = Some((target, Instant::now()));

        match target {
            Target::App(index) => home_apps().get(index).map(|app| {
                let app_id = app.id;
                self.dismiss_switcher_overlay();
                self.focus_app_tile(app_id);
                ShellAction::Launch { app_id }
            }),
            Target::Recent(app_id) => {
                self.dismiss_switcher_overlay();
                self.focus_recent_target(app_id);
                Some(ShellAction::Launch { app_id })
            }
            Target::HomeIndicator => {
                self.dismiss_switcher_overlay();
                self.foreground_app.is_some().then_some(ShellAction::Home)
            }
            Target::SwitcherBackdrop => {
                self.dismiss_switcher_overlay();
                None
            }
            Target::PromptAction(index) => self
                .system_prompt
                .as_ref()
                .and_then(|prompt| prompt.request.actions.get(index))
                .map(|action| ShellAction::SystemPromptResponse {
                    action_id: action.id.clone(),
                }),
        }
    }

    fn touch_recent(&mut self, app_id: AppId) {
        self.recent_apps.retain(|candidate| *candidate != app_id);
        self.recent_apps.insert(0, app_id);
        self.recent_apps.truncate(3);
    }

    fn focus_app_tile(&mut self, app_id: AppId) {
        if let Some(index) = tile_index_for_app(app_id) {
            self.focused_tile = index;
        }
    }

    fn focus_recent_target(&mut self, app_id: AppId) {
        self.focus_app_tile(app_id);
        if let Some(index) = self
            .recent_apps
            .iter()
            .position(|candidate| *candidate == app_id)
        {
            self.switcher_focus = index;
        }
    }

    fn hit_test(&self, point: Point) -> Option<Target> {
        if let Some(prompt) = self.system_prompt.as_ref() {
            return prompt
                .request
                .actions
                .iter()
                .enumerate()
                .find_map(|(index, _)| {
                    let frame = system_prompt_action_frame(index, prompt.request.actions.len());
                    frame
                        .contains(point.x, point.y)
                        .then_some(Target::PromptAction(index))
                });
        }

        if self.switcher_overlay_active() {
            return self
                .recent_apps
                .iter()
                .copied()
                .enumerate()
                .find_map(|(index, app_id)| {
                    switcher_row_frame(index)
                        .contains(point)
                        .then_some(Target::Recent(app_id))
                })
                .or_else(|| {
                    home_indicator_frame()
                        .contains(point)
                        .then_some(Target::HomeIndicator)
                })
                .or_else(|| {
                    bottom_navigation_pill_frame()
                        .contains(point)
                        .then_some(Target::HomeIndicator)
                })
                .or_else(|| {
                    shell_frame()
                        .contains(point)
                        .then_some(Target::SwitcherBackdrop)
                });
        }

        if self.foreground_app.is_some() {
            return home_indicator_frame()
                .contains(point)
                .then_some(Target::HomeIndicator)
                .or_else(|| {
                    bottom_navigation_pill_frame()
                        .contains(point)
                        .then_some(Target::HomeIndicator)
                });
        }

        self.recent_apps
            .iter()
            .copied()
            .enumerate()
            .find_map(|(index, app_id)| {
                recent_row_frame(index)
                    .contains(point)
                    .then_some(Target::Recent(app_id))
            })
            .or_else(|| {
                home_apps().iter().enumerate().find_map(|(index, _)| {
                    app_frame(index)
                        .contains(point)
                        .then_some(Target::App(index))
                })
            })
            .or_else(|| {
                home_indicator_frame()
                    .contains(point)
                    .then_some(Target::HomeIndicator)
            })
            .or_else(|| {
                bottom_navigation_pill_frame()
                    .contains(point)
                    .then_some(Target::HomeIndicator)
            })
    }

    fn trim_expired_flash(&mut self) {
        if let Some((_, instant)) = self.last_activated {
            if instant.elapsed() >= PRESS_FLASH {
                self.last_activated = None;
            }
        }
    }

    fn dismiss_switcher_overlay(&mut self) {
        self.switcher_visible = false;
        self.hovered_target = None;
        self.pressed_target = None;
        self.cursor = None;
    }

    fn default_switcher_focus(&self) -> usize {
        self.switcher_target_app()
            .and_then(|app_id| {
                self.recent_apps
                    .iter()
                    .position(|candidate| *candidate == app_id)
            })
            .or_else(|| {
                self.foreground_app.and_then(|app_id| {
                    self.recent_apps
                        .iter()
                        .position(|candidate| *candidate == app_id)
                })
            })
            .unwrap_or(0)
    }

    fn normalized_switcher_focus(&self) -> usize {
        if self.recent_apps.is_empty() {
            0
        } else {
            self.switcher_focus.min(self.recent_apps.len() - 1)
        }
    }

    fn cycle_switcher_focus(&mut self, delta: isize) {
        let len = self.recent_apps.len();
        if len <= 1 {
            self.switcher_focus = 0;
            return;
        }

        self.switcher_focus = wrap_overlay_index(self.normalized_switcher_focus(), len, delta);
    }

    fn switcher_selection(&self) -> Option<AppId> {
        self.recent_apps
            .get(self.normalized_switcher_focus())
            .copied()
    }

    fn hovered_prompt_action(&self) -> Option<usize> {
        match self.hovered_target {
            Some(Target::PromptAction(index)) => Some(index),
            _ => None,
        }
    }

    fn pressed_prompt_action(&self) -> Option<usize> {
        match self.pressed_target {
            Some(Target::PromptAction(index)) => Some(index),
            _ => None,
        }
    }

    fn last_activated_prompt_action(&self) -> Option<usize> {
        match self.last_activated {
            Some((Target::PromptAction(index), _)) => Some(index),
            _ => None,
        }
    }

    fn system_prompt_app_label(&self, source_app_id: &str) -> String {
        self.system_prompt
            .as_ref()
            .and_then(|prompt| {
                prompt
                    .request
                    .source_app_title
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned)
            })
            .or_else(|| find_app_by_str(source_app_id).map(|app| app.title.to_owned()))
            .unwrap_or_else(|| source_app_id.to_owned())
    }

    fn switcher_scene_only(&self) -> Scene {
        let mut rects = Vec::new();
        let mut texts = Vec::new();
        build_switcher_overlay(&mut rects, &mut texts, self);

        Scene {
            clear_color: crate::color::Color::rgba(0, 0, 0, 0),
            rects,
            texts,
        }
    }
}

fn first_launchable_tile() -> usize {
    0
}

fn tile_index_for_app(app_id: AppId) -> Option<usize> {
    home_apps()
        .iter()
        .enumerate()
        .find_map(|(index, app)| (app.id == app_id).then_some(index))
}

fn move_focus(current: usize, dx: isize, dy: isize) -> usize {
    let app_count = home_apps().len();
    if app_count <= 1 {
        return 0;
    }
    let cols = GRID_COLUMNS as isize;
    let rows = app_count.div_ceil(GRID_COLUMNS) as isize;
    let col = current as isize % cols;
    let row = current as isize / cols;

    let next_col = (col + dx).clamp(0, cols - 1);
    let next_row = (row + dy).clamp(0, rows - 1);
    ((next_row * cols + next_col) as usize).min(app_count.saturating_sub(1))
}

fn wrap_index(current: usize, delta: isize) -> usize {
    let len = home_apps().len() as isize;
    if len <= 1 {
        return 0;
    }
    ((current as isize + delta).rem_euclid(len)) as usize
}

fn wrap_prompt_index(current: usize, len: usize, delta: isize) -> usize {
    let len = len as isize;
    if len <= 1 {
        return 0;
    }
    ((current as isize + delta).rem_euclid(len)) as usize
}

fn wrap_overlay_index(current: usize, len: usize, delta: isize) -> usize {
    let len = len as isize;
    if len <= 1 {
        return 0;
    }
    ((current as isize + delta).rem_euclid(len)) as usize
}

fn append_scene(scene: &mut Scene, overlay: Scene) {
    scene.rects.extend(overlay.rects);
    scene.texts.extend(overlay.texts);
}

fn build_clock(rects: &mut Vec<RoundedRect>, texts: &mut Vec<TextBlock>, status: &ShellStatus) {
    rects.push(RoundedRect::new(
        CLOCK_CARD_X,
        CLOCK_CARD_Y,
        CLOCK_CARD_WIDTH,
        CLOCK_CARD_HEIGHT,
        46.0,
        SURFACE_RAISED.with_alpha(0.92),
    ));

    texts.push(TextBlock {
        content: status.time_label.clone(),
        left: CLOCK_CARD_X + 20.0,
        top: 162.0,
        width: CLOCK_CARD_WIDTH - 40.0,
        height: 90.0,
        size: 72.0,
        line_height: 76.0,
        align: TextAlign::Center,
        weight: TextWeight::Bold,
        color: TEXT_PRIMARY,
    });

    texts.push(TextBlock {
        content: status.date_label.clone(),
        left: CLOCK_CARD_X + 26.0,
        top: 264.0,
        width: CLOCK_CARD_WIDTH - 52.0,
        height: 28.0,
        size: 22.0,
        line_height: 26.0,
        align: TextAlign::Center,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });
}

fn recent_surface_detail(model: &ShellModel, app_id: AppId, index: usize) -> &'static str {
    if model.app_is_foreground(app_id) {
        "Live now"
    } else if index == 0 {
        "Latest surface"
    } else {
        "Warm in shell"
    }
}

fn build_recent_apps_panel(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    model: &ShellModel,
) {
    rects.push(RoundedRect::new(
        RECENTS_PANEL_X,
        RECENTS_PANEL_Y,
        RECENTS_PANEL_WIDTH,
        RECENTS_PANEL_HEIGHT,
        46.0,
        SURFACE_GLASS.with_alpha(0.82),
    ));

    texts.push(TextBlock {
        content: "Recents".to_string(),
        left: RECENTS_PANEL_X + 24.0,
        top: RECENTS_PANEL_Y + 24.0,
        width: RECENTS_PANEL_WIDTH - 48.0,
        height: 22.0,
        size: 18.0,
        line_height: 22.0,
        align: TextAlign::Left,
        weight: TextWeight::Semibold,
        color: TEXT_PRIMARY,
    });
    texts.push(TextBlock {
        content: if model.recent_apps.is_empty() {
            "Launch from home to keep a surface warm.".to_string()
        } else {
            format!(
                "{} warm surface(s) ready to resume.",
                model.recent_apps.len()
            )
        },
        left: RECENTS_PANEL_X + 24.0,
        top: RECENTS_PANEL_Y + 48.0,
        width: RECENTS_PANEL_WIDTH - 48.0,
        height: 18.0,
        size: 12.0,
        line_height: 14.0,
        align: TextAlign::Left,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });

    if model.recent_apps.is_empty() {
        rects.push(RoundedRect::new(
            RECENTS_PANEL_X + 16.0,
            RECENTS_PANEL_Y + 86.0,
            RECENTS_PANEL_WIDTH - 32.0,
            128.0,
            24.0,
            SURFACE.with_alpha(0.18),
        ));
        texts.push(TextBlock {
            content: "No warm apps yet.".to_string(),
            left: RECENTS_PANEL_X + 36.0,
            top: RECENTS_PANEL_Y + 128.0,
            width: RECENTS_PANEL_WIDTH - 72.0,
            height: 22.0,
            size: 18.0,
            line_height: 22.0,
            align: TextAlign::Center,
            weight: TextWeight::Semibold,
            color: TEXT_PRIMARY.with_alpha(0.92),
        });
        texts.push(TextBlock {
            content: "Open an app, then come home to park it here.".to_string(),
            left: RECENTS_PANEL_X + 28.0,
            top: RECENTS_PANEL_Y + 156.0,
            width: RECENTS_PANEL_WIDTH - 56.0,
            height: 18.0,
            size: 11.0,
            line_height: 14.0,
            align: TextAlign::Center,
            weight: TextWeight::Normal,
            color: TEXT_MUTED,
        });
        return;
    }

    for (index, app_id) in model.recent_apps.iter().copied().enumerate() {
        let app = find_app(app_id).expect("recent app metadata");
        let frame = recent_row_frame(index);
        let target = Target::Recent(app_id);
        let is_hovered = model.hovered_target == Some(target);
        let is_pressed = model.pressed_target == Some(target);
        let is_active = model.last_activated.map(|(target, _)| target) == Some(target);
        let halo_alpha = if is_pressed {
            0.18
        } else if is_active {
            0.15
        } else if is_hovered {
            0.1
        } else {
            0.0
        };

        if halo_alpha > 0.0 {
            rects.push(RoundedRect::new(
                frame.x - 4.0,
                frame.y - 4.0,
                frame.w + 8.0,
                frame.h + 8.0,
                28.0,
                TEXT_PRIMARY.with_alpha(halo_alpha),
            ));
        }

        let row_alpha = if is_pressed {
            0.74
        } else if is_active {
            0.68
        } else if is_hovered {
            0.6
        } else if index == 0 {
            0.58
        } else {
            0.42
        };
        let icon_scale = if is_pressed { 0.96 } else { 1.0 };
        let icon_size = 28.0 * icon_scale;
        let icon_x = frame.x + 12.0 + (28.0 - icon_size) * 0.5;
        let icon_y = frame.y + 9.0 + (28.0 - icon_size) * 0.5;

        rects.push(RoundedRect::new(
            frame.x,
            frame.y,
            frame.w,
            frame.h,
            24.0,
            SURFACE_RAISED.with_alpha(row_alpha),
        ));
        rects.push(RoundedRect::new(
            icon_x,
            icon_y,
            28.0,
            28.0,
            10.0,
            app.icon_color,
        ));

        texts.push(TextBlock {
            content: app.icon_label.to_string(),
            left: icon_x,
            top: icon_y + 5.0,
            width: 28.0,
            height: 18.0,
            size: 14.0,
            line_height: 16.0,
            align: TextAlign::Center,
            weight: TextWeight::Bold,
            color: TEXT_PRIMARY.with_alpha(0.9),
        });
        texts.push(TextBlock {
            content: app.title.to_string(),
            left: frame.x + 50.0,
            top: frame.y + 8.0,
            width: RECENTS_PANEL_WIDTH - 98.0,
            height: 16.0,
            size: 14.0,
            line_height: 16.0,
            align: TextAlign::Left,
            weight: TextWeight::Semibold,
            color: TEXT_PRIMARY,
        });
        texts.push(TextBlock {
            content: recent_surface_detail(model, app_id, index).to_string(),
            left: frame.x + 50.0,
            top: frame.y + 25.0,
            width: RECENTS_PANEL_WIDTH - 98.0,
            height: 14.0,
            size: 10.0,
            line_height: 12.0,
            align: TextAlign::Left,
            weight: TextWeight::Normal,
            color: TEXT_MUTED,
        });
    }
}

fn build_panel_header(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    model: &ShellModel,
) {
    let (headline, detail) = match model.foreground_app() {
        Some(app_id) => {
            let app = find_app(app_id).expect("foreground app metadata");
            (
                format!("{} live", app.title),
                format!(
                    "Tap the pill or press Home to shelf it. {}",
                    app.lifecycle_hint
                ),
            )
        }
        None if model.running_apps().is_empty() => (
            "Home stack".to_string(),
            "Launch an app when you want one. The shell stays resident here.".to_string(),
        ),
        None => (
            "Home stack".to_string(),
            format!(
                "{} warm app(s) waiting. Relaunch resumes state.",
                model.running_apps().len()
            ),
        ),
    };

    rects.push(RoundedRect::new(
        44.0,
        446.0,
        452.0,
        82.0,
        28.0,
        SURFACE_GLASS.with_alpha(0.78),
    ));

    texts.push(TextBlock {
        content: headline,
        left: 68.0,
        top: 464.0,
        width: 408.0,
        height: 24.0,
        size: 22.0,
        line_height: 26.0,
        align: TextAlign::Left,
        weight: TextWeight::Semibold,
        color: TEXT_PRIMARY,
    });
    texts.push(TextBlock {
        content: detail,
        left: 68.0,
        top: 494.0,
        width: 408.0,
        height: 20.0,
        size: 14.0,
        line_height: 18.0,
        align: TextAlign::Left,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });
}

fn build_switcher_overlay(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    model: &ShellModel,
) {
    let Some(foreground_app_id) = model.foreground_app() else {
        return;
    };
    let foreground_app = find_app(foreground_app_id).expect("foreground app metadata");
    let selected_index = model.normalized_switcher_focus();

    rects.push(RoundedRect::new(
        0.0,
        0.0,
        WIDTH,
        HEIGHT,
        0.0,
        SURFACE.with_alpha(0.54),
    ));
    rects.push(RoundedRect::new(
        SWITCHER_PANEL_X,
        SWITCHER_PANEL_Y,
        SWITCHER_PANEL_WIDTH,
        SWITCHER_PANEL_HEIGHT,
        40.0,
        SURFACE_GLASS.with_alpha(0.92),
    ));
    rects.push(RoundedRect::new(
        SWITCHER_PANEL_X + 24.0,
        SWITCHER_PANEL_Y + 72.0,
        SWITCHER_PANEL_WIDTH - 48.0,
        1.0,
        0.5,
        TEXT_PRIMARY.with_alpha(0.12),
    ));

    texts.push(TextBlock {
        content: "App switcher".to_string(),
        left: SWITCHER_PANEL_X + 28.0,
        top: SWITCHER_PANEL_Y + 24.0,
        width: SWITCHER_PANEL_WIDTH - 56.0,
        height: 24.0,
        size: 22.0,
        line_height: 26.0,
        align: TextAlign::Left,
        weight: TextWeight::Semibold,
        color: TEXT_PRIMARY,
    });
    texts.push(TextBlock {
        content: if model.recent_apps.len() > 1 {
            format!(
                "{} stays live underneath. Pick a warm surface or tap outside to dismiss.",
                foreground_app.title
            )
        } else {
            format!(
                "{} is the only warm surface right now. Tap outside to keep it live.",
                foreground_app.title
            )
        },
        left: SWITCHER_PANEL_X + 28.0,
        top: SWITCHER_PANEL_Y + 50.0,
        width: SWITCHER_PANEL_WIDTH - 56.0,
        height: 18.0,
        size: 12.0,
        line_height: 14.0,
        align: TextAlign::Left,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });

    for (index, app_id) in model.recent_apps.iter().copied().enumerate() {
        let app = find_app(app_id).expect("recent app metadata");
        let frame = switcher_row_frame(index);
        let target = Target::Recent(app_id);
        let is_selected = selected_index == index;
        let is_hovered = model.hovered_target == Some(target);
        let is_pressed = model.pressed_target == Some(target);
        let is_active = model.last_activated.map(|(target, _)| target) == Some(target);

        let halo_alpha = if is_pressed {
            0.28
        } else if is_active {
            0.24
        } else if is_selected {
            0.18
        } else if is_hovered {
            0.12
        } else {
            0.0
        };

        if halo_alpha > 0.0 {
            rects.push(RoundedRect::new(
                frame.x - 4.0,
                frame.y - 4.0,
                frame.w + 8.0,
                frame.h + 8.0,
                30.0,
                TEXT_PRIMARY.with_alpha(halo_alpha),
            ));
        }

        rects.push(RoundedRect::new(
            frame.x,
            frame.y,
            frame.w,
            frame.h,
            26.0,
            if is_pressed {
                SURFACE_RAISED.with_alpha(0.84)
            } else if is_selected {
                SURFACE_RAISED.with_alpha(0.72)
            } else if is_hovered {
                SURFACE_RAISED.with_alpha(0.64)
            } else {
                SURFACE_RAISED.with_alpha(0.52)
            },
        ));
        rects.push(RoundedRect::new(
            frame.x + 16.0,
            frame.y + 11.0,
            32.0,
            32.0,
            12.0,
            app.icon_color,
        ));

        texts.push(TextBlock {
            content: app.icon_label.to_string(),
            left: frame.x + 16.0,
            top: frame.y + 17.0,
            width: 32.0,
            height: 18.0,
            size: 15.0,
            line_height: 16.0,
            align: TextAlign::Center,
            weight: TextWeight::Bold,
            color: TEXT_PRIMARY.with_alpha(0.92),
        });
        texts.push(TextBlock {
            content: app.title.to_string(),
            left: frame.x + 62.0,
            top: frame.y + 11.0,
            width: frame.w - 144.0,
            height: 18.0,
            size: 15.0,
            line_height: 18.0,
            align: TextAlign::Left,
            weight: if is_selected {
                TextWeight::Semibold
            } else {
                TextWeight::Normal
            },
            color: TEXT_PRIMARY,
        });
        texts.push(TextBlock {
            content: recent_surface_detail(model, app_id, index).to_string(),
            left: frame.x + 62.0,
            top: frame.y + 31.0,
            width: frame.w - 144.0,
            height: 14.0,
            size: 11.0,
            line_height: 12.0,
            align: TextAlign::Left,
            weight: TextWeight::Normal,
            color: TEXT_MUTED,
        });
        if is_selected {
            texts.push(TextBlock {
                content: "Selected".to_string(),
                left: frame.x + frame.w - 96.0,
                top: frame.y + 18.0,
                width: 72.0,
                height: 16.0,
                size: 11.0,
                line_height: 12.0,
                align: TextAlign::Center,
                weight: TextWeight::Semibold,
                color: TEXT_PRIMARY.with_alpha(0.88),
            });
        }
    }

    texts.push(TextBlock {
        content: "Tap a recent surface to switch. Tap outside the card to stay here.".to_string(),
        left: SWITCHER_PANEL_X + 28.0,
        top: SWITCHER_PANEL_Y + SWITCHER_PANEL_HEIGHT - 40.0,
        width: SWITCHER_PANEL_WIDTH - 56.0,
        height: 16.0,
        size: 12.0,
        line_height: 14.0,
        align: TextAlign::Left,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });
}

fn append_home_launcher(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    status: &ShellStatus,
    model: &ShellModel,
) {
    rects.push(RoundedRect::new(
        0.0,
        0.0,
        WIDTH,
        HEIGHT,
        0.0,
        SURFACE.with_alpha(0.18),
    ));
    rects.push(RoundedRect::new(
        32.0,
        92.0,
        476.0,
        314.0,
        54.0,
        SURFACE.with_alpha(0.22),
    ));
    rects.push(RoundedRect::new(
        20.0,
        APP_PANEL_Y,
        500.0,
        APP_PANEL_HEIGHT,
        44.0,
        SURFACE_ACCENT.with_alpha(0.96),
    ));
    build_clock(rects, texts, status);
    build_recent_apps_panel(rects, texts, model);
    build_panel_header(rects, texts, model);
    build_app_grid(rects, texts, model);
}

fn build_app_grid(rects: &mut Vec<RoundedRect>, texts: &mut Vec<TextBlock>, model: &ShellModel) {
    for (index, app) in home_apps().iter().enumerate() {
        let frame = app_frame(index);
        let target = Target::App(index);
        let is_focused = model.focused_tile == index;
        let is_hovered = model.hovered_target == Some(target);
        let is_pressed = model.pressed_target == Some(target);
        let is_active = model.last_activated.map(|(target, _)| target) == Some(target);
        let app_id = app.id;
        let is_running = model.app_is_running(app_id);
        let is_foreground = model.app_is_foreground(app_id);

        let halo_alpha = if is_pressed {
            0.34
        } else if is_foreground {
            0.26
        } else if is_active {
            0.22
        } else if is_focused {
            0.18
        } else if is_hovered {
            0.12
        } else {
            0.0
        };

        if halo_alpha > 0.0 {
            rects.push(RoundedRect::new(
                frame.x - 10.0,
                frame.y - 10.0,
                frame.w + 20.0,
                frame.h + 20.0,
                28.0,
                TEXT_PRIMARY.with_alpha(halo_alpha),
            ));
        }

        rects.push(RoundedRect::new(
            frame.x,
            frame.y,
            frame.w,
            frame.h,
            28.0,
            SURFACE_GLASS,
        ));

        let icon_scale = if is_pressed { 0.94 } else { 1.0 };
        let icon_size = APP_ICON_SIZE * icon_scale;
        let icon_x = frame.x + (frame.w - icon_size) * 0.5;
        let icon_y = frame.y + 10.0 + (APP_ICON_SIZE - icon_size) * 0.5;

        rects.push(RoundedRect::new(
            icon_x,
            icon_y,
            icon_size,
            icon_size,
            26.0,
            app.icon_color,
        ));
        rects.push(RoundedRect::new(
            icon_x + 16.0,
            icon_y + 20.0,
            icon_size - 32.0,
            10.0,
            5.0,
            TEXT_PRIMARY.with_alpha(0.16),
        ));

        texts.push(TextBlock {
            content: app.icon_label.to_string(),
            left: icon_x,
            top: icon_y + 22.0,
            width: icon_size,
            height: 48.0,
            size: 42.0,
            line_height: 44.0,
            align: TextAlign::Center,
            weight: TextWeight::Bold,
            color: TEXT_PRIMARY.with_alpha(0.92),
        });

        if is_running {
            rects.push(RoundedRect::new(
                frame.x + frame.w * 0.5 - 18.0,
                frame.y + APP_ICON_SIZE + 10.0,
                36.0,
                5.0,
                2.5,
                if is_foreground {
                    TEXT_PRIMARY.with_alpha(0.92)
                } else {
                    TEXT_PRIMARY.with_alpha(0.44)
                },
            ));
        }

        texts.push(TextBlock {
            content: app.title.to_string(),
            left: frame.x + 8.0,
            top: frame.y + APP_ICON_SIZE + 22.0,
            width: frame.w - 16.0,
            height: APP_LABEL_HEIGHT,
            size: 12.0,
            line_height: 14.0,
            align: TextAlign::Center,
            weight: if is_foreground || is_focused {
                TextWeight::Semibold
            } else {
                TextWeight::Normal
            },
            color: TEXT_PRIMARY,
        });
        texts.push(TextBlock {
            content: app.subtitle.to_string(),
            left: frame.x + 8.0,
            top: frame.y + APP_ICON_SIZE + 40.0,
            width: frame.w - 16.0,
            height: APP_SUBTITLE_HEIGHT,
            size: 10.0,
            line_height: 12.0,
            align: TextAlign::Center,
            weight: TextWeight::Normal,
            color: TEXT_MUTED,
        });
    }

    texts.push(TextBlock {
        content: "Mouse, arrows, Tab, Enter. Home returns from the foreground app.".to_string(),
        left: 52.0,
        top: APP_PANEL_Y + APP_PANEL_HEIGHT - 42.0,
        width: 460.0,
        height: 24.0,
        size: 15.0,
        line_height: 18.0,
        align: TextAlign::Center,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });
}

fn grid_origin() -> Point {
    Point { x: 52.0, y: 546.0 }
}

fn shell_frame() -> Frame {
    Frame {
        x: 0.0,
        y: 0.0,
        w: WIDTH,
        h: HEIGHT,
    }
}

fn app_viewport_frame() -> Frame {
    Frame {
        x: APP_VIEWPORT_X,
        y: APP_VIEWPORT_Y,
        w: APP_VIEWPORT_WIDTH,
        h: APP_VIEWPORT_HEIGHT,
    }
}

fn app_frame(index: usize) -> Frame {
    let origin = grid_origin();
    let app_count = home_apps().len();
    let col = index % GRID_COLUMNS;
    let row = index / GRID_COLUMNS;
    let row_start = row * GRID_COLUMNS;
    let row_count = app_count.saturating_sub(row_start).min(GRID_COLUMNS).max(1);
    let row_width = APP_ICON_SIZE + 8.0 + (APP_GRID_STEP_X * row_count as f32) - APP_GRID_STEP_X;
    let full_width =
        APP_ICON_SIZE + 8.0 + (APP_GRID_STEP_X * GRID_COLUMNS as f32) - APP_GRID_STEP_X;
    let row_origin_x = origin.x + ((full_width - row_width) * 0.5);

    Frame {
        x: row_origin_x + col as f32 * APP_GRID_STEP_X,
        y: origin.y + row as f32 * 164.0,
        w: 104.0,
        h: 142.0,
    }
}

fn recent_row_frame(index: usize) -> Frame {
    Frame {
        x: RECENTS_PANEL_X + 16.0,
        y: RECENTS_PANEL_Y + 82.0 + index as f32 * 54.0,
        w: RECENTS_PANEL_WIDTH - 32.0,
        h: 46.0,
    }
}

fn switcher_row_frame(index: usize) -> Frame {
    Frame {
        x: SWITCHER_PANEL_X + 24.0,
        y: SWITCHER_PANEL_Y + 94.0 + index as f32 * (SWITCHER_ROW_HEIGHT + SWITCHER_ROW_GAP),
        w: SWITCHER_PANEL_WIDTH - 48.0,
        h: SWITCHER_ROW_HEIGHT,
    }
}

fn home_indicator_frame() -> Frame {
    Frame {
        x: TOP_CHROME_STRIP_X,
        y: TOP_CHROME_STRIP_Y,
        w: TOP_CHROME_STRIP_WIDTH,
        h: TOP_CHROME_STRIP_HEIGHT,
    }
}

fn bottom_navigation_pill_frame() -> Frame {
    Frame {
        x: BOTTOM_NAVIGATION_PILL_X,
        y: BOTTOM_NAVIGATION_PILL_Y,
        w: BOTTOM_NAVIGATION_PILL_WIDTH,
        h: BOTTOM_NAVIGATION_PILL_HEIGHT,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::{CAMERA_APP_ID, COUNTER_APP_ID, TIMELINE_APP_ID};
    use shadow_runtime_protocol::{
        SystemPromptAction, SystemPromptActionStyle, SystemPromptRequest,
    };

    fn demo_prompt_request() -> SystemPromptRequest {
        SystemPromptRequest {
            source_app_id: String::from("rust-timeline"),
            source_app_title: Some(String::from("Rust Timeline")),
            title: String::from("Allow Nostr publish?"),
            message: String::from("A shared signer request is waiting."),
            detail_lines: vec![String::from("Account: npub1test")],
            actions: vec![
                SystemPromptAction {
                    id: String::from("deny"),
                    label: String::from("Deny"),
                    style: SystemPromptActionStyle::Danger,
                },
                SystemPromptAction {
                    id: String::from("allow_once"),
                    label: String::from("Allow Once"),
                    style: SystemPromptActionStyle::Default,
                },
                SystemPromptAction {
                    id: String::from("allow_always"),
                    label: String::from("Always Allow"),
                    style: SystemPromptActionStyle::Normal,
                },
            ],
        }
    }

    #[test]
    fn launch_tile_returns_launch_action() {
        let mut shell = ShellModel::new();

        assert_eq!(
            shell.handle(ShellEvent::Navigate(NavAction::Activate)),
            Some(ShellAction::Launch {
                app_id: COUNTER_APP_ID,
            })
        );
    }

    #[test]
    fn navigation_reaches_camera_before_timeline() {
        let mut shell = ShellModel::new();

        assert_eq!(shell.focused_tile, 0);
        assert_eq!(shell.handle(ShellEvent::Navigate(NavAction::Right)), None);
        assert_eq!(shell.focused_tile, 1);
        assert_eq!(
            shell.handle(ShellEvent::Navigate(NavAction::Activate)),
            Some(ShellAction::Launch {
                app_id: CAMERA_APP_ID,
            })
        );
        assert_eq!(shell.handle(ShellEvent::Navigate(NavAction::Right)), None);
        assert_eq!(shell.focused_tile, 2);
        assert_eq!(
            shell.handle(ShellEvent::Navigate(NavAction::Activate)),
            Some(ShellAction::Launch {
                app_id: TIMELINE_APP_ID,
            })
        );
    }

    #[test]
    fn home_requires_foreground_app() {
        let mut shell = ShellModel::new();
        assert_eq!(shell.handle(ShellEvent::Navigate(NavAction::Home)), None);

        shell.set_foreground_app(Some(COUNTER_APP_ID));
        assert_eq!(
            shell.handle(ShellEvent::Navigate(NavAction::Home)),
            Some(ShellAction::Home)
        );
    }

    #[test]
    fn switcher_target_uses_most_recent_app_from_home() {
        let mut shell = ShellModel::new();
        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_app_running(TIMELINE_APP_ID, true);

        assert_eq!(shell.switcher_target_app(), Some(TIMELINE_APP_ID));
    }

    #[test]
    fn switcher_target_skips_foreground_app() {
        let mut shell = ShellModel::new();
        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_foreground_app(Some(COUNTER_APP_ID));
        shell.set_app_running(TIMELINE_APP_ID, true);
        shell.set_foreground_app(Some(TIMELINE_APP_ID));

        assert_eq!(shell.switcher_target_app(), Some(COUNTER_APP_ID));
    }

    #[test]
    fn switcher_target_is_empty_without_another_recent_app() {
        let mut shell = ShellModel::new();
        assert_eq!(shell.switcher_target_app(), None);

        shell.set_foreground_app(Some(COUNTER_APP_ID));
        assert_eq!(shell.switcher_target_app(), None);
    }

    #[test]
    fn switcher_overlay_captures_the_full_shell_surface() {
        let mut shell = ShellModel::new();
        shell.set_foreground_app(Some(COUNTER_APP_ID));

        assert!(shell.show_switcher_overlay());
        assert!(shell.captures_point(WIDTH * 0.5, HEIGHT * 0.5));
        assert!(shell.captures_point(APP_VIEWPORT_WIDTH * 0.5, APP_VIEWPORT_Y + 120.0));
        assert!(shell.switcher_overlay_active());
    }

    #[test]
    fn switcher_overlay_tap_outside_dismisses_without_switching() {
        let mut shell = ShellModel::new();
        shell.set_foreground_app(Some(COUNTER_APP_ID));

        assert!(shell.show_switcher_overlay());
        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: WIDTH * 0.5,
                y: HEIGHT - 120.0,
            }),
            None
        );
        assert!(!shell.switcher_overlay_active());
    }

    #[test]
    fn switcher_overlay_recent_tap_requests_selected_app_and_dismisses() {
        let mut shell = ShellModel::new();
        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_foreground_app(Some(TIMELINE_APP_ID));
        let counter_row = switcher_row_frame(1);
        let recents_before = shell.recent_apps.clone();

        assert!(shell.show_switcher_overlay());
        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: counter_row.x + counter_row.w * 0.5,
                y: counter_row.y + counter_row.h * 0.5,
            }),
            Some(ShellAction::Launch {
                app_id: COUNTER_APP_ID,
            })
        );
        assert_eq!(shell.recent_apps, recents_before);
        assert!(!shell.switcher_overlay_active());
    }

    #[test]
    fn switcher_overlay_defaults_to_latest_non_foreground_recent() {
        let mut shell = ShellModel::new();
        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_foreground_app(Some(TIMELINE_APP_ID));

        assert!(shell.show_switcher_overlay());
        assert_eq!(shell.switcher_selection(), Some(COUNTER_APP_ID));
    }

    #[test]
    fn touch_tap_launches_immediately() {
        let mut shell = ShellModel::new();
        let counter_tile = app_frame(0);

        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: counter_tile.x + counter_tile.w * 0.5,
                y: counter_tile.y + counter_tile.h * 0.5,
            }),
            Some(ShellAction::Launch {
                app_id: COUNTER_APP_ID
            })
        );
        assert_eq!(shell.focused_tile, 0);
        assert_eq!(shell.pressed_target, None);
    }

    #[test]
    fn touch_tap_recent_row_requests_warm_app_without_promoting_until_success() {
        let mut shell = ShellModel::new();
        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_app_running(TIMELINE_APP_ID, true);
        let counter_row = recent_row_frame(1);
        let recents_before = shell.recent_apps.clone();

        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: counter_row.x + counter_row.w * 0.5,
                y: counter_row.y + counter_row.h * 0.5,
            }),
            Some(ShellAction::Launch {
                app_id: COUNTER_APP_ID,
            })
        );
        assert_eq!(shell.recent_apps, recents_before);
        assert_eq!(
            shell.focused_tile,
            tile_index_for_app(COUNTER_APP_ID).unwrap()
        );
    }

    #[test]
    fn pointer_click_recent_row_launches_warm_app() {
        let mut shell = ShellModel::new();
        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_app_running(TIMELINE_APP_ID, true);
        let timeline_row = recent_row_frame(0);
        let x = timeline_row.x + timeline_row.w * 0.5;
        let y = timeline_row.y + timeline_row.h * 0.5;

        assert_eq!(shell.handle(ShellEvent::PointerMoved { x, y }), None);
        assert_eq!(
            shell.handle(ShellEvent::PointerButton(PointerButtonState::Pressed)),
            None
        );
        assert_eq!(
            shell.handle(ShellEvent::PointerButton(PointerButtonState::Released)),
            Some(ShellAction::Launch {
                app_id: TIMELINE_APP_ID,
            })
        );
        assert_eq!(
            shell.focused_tile,
            tile_index_for_app(TIMELINE_APP_ID).unwrap()
        );
        assert_eq!(shell.pressed_target, None);
    }

    #[test]
    fn launch_request_does_not_add_failed_app_to_recents() {
        let mut shell = ShellModel::new();
        let counter_tile = app_frame(0);

        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: counter_tile.x + counter_tile.w * 0.5,
                y: counter_tile.y + counter_tile.h * 0.5,
            }),
            Some(ShellAction::Launch {
                app_id: COUNTER_APP_ID
            })
        );
        assert!(shell.recent_apps.is_empty());

        shell.set_foreground_app(Some(COUNTER_APP_ID));
        assert_eq!(shell.recent_apps, vec![COUNTER_APP_ID]);
    }

    #[test]
    fn top_chrome_strip_state_tracks_home_availability() {
        let mut shell = ShellModel::new();
        let status = ShellStatus {
            time_label: "09:41".to_string(),
            date_label: "Friday, April 18".to_string(),
            battery_percent: 61,
            wifi_strength: 2,
        };

        assert_eq!(
            shell.top_chrome_strip_state(&status),
            TopChromeStripState {
                time_label: "09:41".to_string(),
                battery_percent: 61,
                wifi_strength: 2,
                home_enabled: false,
            }
        );

        shell.set_foreground_app(Some(COUNTER_APP_ID));

        assert_eq!(
            shell.top_chrome_strip_state(&status),
            TopChromeStripState {
                time_label: "09:41".to_string(),
                battery_percent: 61,
                wifi_strength: 2,
                home_enabled: true,
            }
        );
    }

    #[test]
    fn bottom_navigation_pill_state_tracks_home_availability() {
        let mut shell = ShellModel::new();

        assert_eq!(
            shell.bottom_navigation_pill_state(),
            BottomNavigationPillState { active: false }
        );

        shell.set_foreground_app(Some(COUNTER_APP_ID));

        assert_eq!(
            shell.bottom_navigation_pill_state(),
            BottomNavigationPillState { active: true }
        );
    }

    #[test]
    fn foreground_home_accepts_top_strip_and_bottom_pill_taps() {
        let mut shell = ShellModel::new();
        shell.set_foreground_app(Some(COUNTER_APP_ID));
        let top = home_indicator_frame();
        let bottom = bottom_navigation_pill_frame();

        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: top.x + top.w * 0.5,
                y: top.y + top.h * 0.5,
            }),
            Some(ShellAction::Home)
        );
        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: bottom.x + bottom.w * 0.5,
                y: bottom.y + bottom.h * 0.5,
            }),
            Some(ShellAction::Home)
        );
    }

    #[test]
    fn foreground_capture_includes_top_strip_and_bottom_pill_only() {
        let mut shell = ShellModel::new();
        shell.set_foreground_app(Some(COUNTER_APP_ID));
        let top = home_indicator_frame();
        let bottom = bottom_navigation_pill_frame();

        assert!(shell.captures_point(top.x + top.w * 0.5, top.y + top.h * 0.5));
        assert!(shell.captures_point(bottom.x + bottom.w * 0.5, bottom.y + bottom.h * 0.5,));
        assert!(!shell.captures_point(APP_VIEWPORT_WIDTH * 0.5, APP_VIEWPORT_Y + 120.0));
    }

    #[test]
    fn scene_without_compositor_chrome_drops_overlay_primitives() {
        let mut shell = ShellModel::new();
        let status = ShellStatus {
            time_label: "09:41".to_string(),
            date_label: "Friday, April 18".to_string(),
            battery_percent: 61,
            wifi_strength: 2,
        };

        let full_scene = shell.scene(&status);
        let scene_without_strip = shell.scene_without_compositor_chrome(&status);

        assert_eq!(full_scene.rects.len(), scene_without_strip.rects.len() + 9);
        assert_eq!(full_scene.texts.len(), scene_without_strip.texts.len() + 1);
        assert_eq!(scene_without_strip.clear_color.rgba8(), BACKGROUND.rgba8());
        assert_eq!(scene_without_strip.texts[0].content, status.time_label);

        shell.set_foreground_app(Some(COUNTER_APP_ID));
        let foreground_full_scene = shell.scene(&status);
        let foreground_scene = shell.scene_without_compositor_chrome(&status);

        assert_eq!(
            foreground_full_scene.rects.len(),
            foreground_scene.rects.len() + 9
        );
        assert_eq!(
            foreground_full_scene.texts.len(),
            foreground_scene.texts.len() + 1
        );
        assert!(foreground_scene.rects.is_empty());
        assert!(foreground_scene.texts.is_empty());
        assert_eq!(foreground_scene.clear_color.rgba8(), [0, 0, 0, 0]);
    }

    #[test]
    fn base_scene_is_background_only_on_home_and_transparent_in_foreground() {
        let mut shell = ShellModel::new();

        let home_scene = shell.base_scene();
        assert_eq!(home_scene.clear_color.rgba8(), BACKGROUND.rgba8());
        assert!(home_scene.rects.is_empty());
        assert!(home_scene.texts.is_empty());

        shell.set_foreground_app(Some(COUNTER_APP_ID));

        let foreground_scene = shell.base_scene();
        assert_eq!(foreground_scene.clear_color.rgba8(), [0, 0, 0, 0]);
        assert!(foreground_scene.rects.is_empty());
        assert!(foreground_scene.texts.is_empty());
    }

    #[test]
    fn home_launcher_scene_is_transparent_overlay_only_on_home() {
        let mut shell = ShellModel::new();
        let status = ShellStatus {
            time_label: "09:41".to_string(),
            date_label: "Friday, April 18".to_string(),
            battery_percent: 61,
            wifi_strength: 2,
        };

        let launcher = shell
            .home_launcher_scene(&status)
            .expect("home launcher scene");
        assert_eq!(launcher.clear_color.rgba8(), [0, 0, 0, 0]);
        assert!(!launcher.rects.is_empty());
        assert!(launcher
            .texts
            .iter()
            .any(|text| text.content == "Home stack"));

        shell.set_foreground_app(Some(COUNTER_APP_ID));
        assert!(shell.home_launcher_scene(&status).is_none());
    }

    #[test]
    fn home_launcher_scene_renders_empty_recents_panel() {
        let mut shell = ShellModel::new();
        let status = ShellStatus {
            time_label: "09:41".to_string(),
            date_label: "Friday, April 18".to_string(),
            battery_percent: 61,
            wifi_strength: 2,
        };

        let launcher = shell
            .home_launcher_scene(&status)
            .expect("home launcher scene");

        assert!(launcher.rects.iter().any(|rect| {
            rect.x == RECENTS_PANEL_X
                && rect.y == RECENTS_PANEL_Y
                && rect.width == RECENTS_PANEL_WIDTH
                && rect.height == RECENTS_PANEL_HEIGHT
        }));
        assert!(launcher.texts.iter().any(|text| text.content == "Recents"));
        assert!(launcher
            .texts
            .iter()
            .any(|text| text.content == "No warm apps yet."));
        assert!(!launcher
            .texts
            .iter()
            .any(|text| text.content.starts_with("Warm apps:")));
    }

    #[test]
    fn home_launcher_scene_lists_recent_surfaces_in_panel() {
        let mut shell = ShellModel::new();
        let status = ShellStatus {
            time_label: "09:41".to_string(),
            date_label: "Friday, April 18".to_string(),
            battery_percent: 61,
            wifi_strength: 2,
        };

        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_app_running(TIMELINE_APP_ID, true);

        let launcher = shell
            .home_launcher_scene(&status)
            .expect("home launcher scene");

        assert!(launcher
            .texts
            .iter()
            .any(|text| text.content == "2 warm surface(s) ready to resume."));
        assert!(launcher
            .texts
            .iter()
            .any(|text| text.content == "Latest surface"));
        assert!(launcher
            .texts
            .iter()
            .any(|text| text.content == "Warm in shell"));
        assert!(!launcher
            .texts
            .iter()
            .any(|text| text.content.starts_with("Warm apps:")));
    }

    #[test]
    fn switcher_scene_renders_overlay_copy_over_foreground_app() {
        let mut shell = ShellModel::new();
        shell.set_app_running(COUNTER_APP_ID, true);
        shell.set_foreground_app(Some(TIMELINE_APP_ID));
        assert!(shell.show_switcher_overlay());

        let scene = shell
            .switcher_scene()
            .expect("foreground switcher overlay scene");

        assert!(scene
            .texts
            .iter()
            .any(|text| text.content == "App switcher"));
        assert!(scene.texts.iter().any(|text| text.content == "Selected"));
        assert!(scene.texts.iter().any(|text| text.content == "Timeline"));
        assert!(scene.texts.iter().any(|text| text.content == "Counter"));
    }

    #[test]
    fn system_prompt_captures_the_full_shell_surface() {
        let mut shell = ShellModel::new();
        shell.set_foreground_app(Some(COUNTER_APP_ID));
        shell.set_system_prompt(Some(demo_prompt_request()));

        assert!(shell.captures_point(WIDTH * 0.5, HEIGHT * 0.5));
        assert!(shell.captures_point(APP_VIEWPORT_WIDTH * 0.5, APP_VIEWPORT_Y + 120.0));
        assert_eq!(shell.handle(ShellEvent::Navigate(NavAction::Home)), None);
    }

    #[test]
    fn system_prompt_activate_returns_selected_action_id() {
        let mut shell = ShellModel::new();
        let prompt = demo_prompt_request();
        let action_frame = system_prompt_action_frame(1, prompt.actions.len());
        shell.set_system_prompt(Some(prompt));

        assert_eq!(
            shell.handle(ShellEvent::TouchTap {
                x: action_frame.x + action_frame.w * 0.5,
                y: action_frame.y + action_frame.h * 0.5,
            }),
            Some(ShellAction::SystemPromptResponse {
                action_id: String::from("allow_once"),
            })
        );
    }
}
