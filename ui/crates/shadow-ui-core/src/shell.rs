use std::time::{Duration, Instant};

use chrono::{DateTime, Local};

use crate::{
    app::{find_app, home_apps, AppId},
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
};

const PRESS_FLASH: Duration = Duration::from_millis(160);
const CLOCK_CARD_Y: f32 = 124.0;
const CLOCK_CARD_HEIGHT: f32 = 250.0;
const APP_PANEL_Y: f32 = 420.0;
const APP_PANEL_HEIGHT: f32 = 640.0;
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShellAction {
    Launch { app_id: AppId },
    Home,
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
    HomeIndicator,
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

        self.current_scene(status, true)
    }

    pub fn scene_without_compositor_chrome(&mut self, status: &ShellStatus) -> Scene {
        self.trim_expired_flash();

        self.current_scene(status, false)
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

        if include_compositor_chrome {
            append_top_chrome_strip(&mut rects, &mut texts, &self.top_chrome_strip_state(status));
            append_bottom_navigation_pill(&mut rects, self.bottom_navigation_pill_state());
        }
        build_clock(&mut rects, &mut texts, status, self.recent_app_titles());
        build_panel_header(&mut rects, &mut texts, self);
        build_app_grid(&mut rects, &mut texts, self);

        Scene {
            clear_color: BACKGROUND,
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
            }
        }
    }

    pub fn set_foreground_app(&mut self, app_id: Option<AppId>) {
        self.foreground_app = app_id;
        if let Some(app_id) = app_id {
            self.set_app_running(app_id, true);
            if let Some(index) = tile_index_for_app(app_id) {
                self.focused_tile = index;
            }
        }
    }

    pub fn foreground_app(&self) -> Option<AppId> {
        self.foreground_app
    }

    pub fn running_apps(&self) -> &[AppId] {
        &self.running_apps
    }

    fn recent_app_titles(&self) -> Vec<&'static str> {
        self.recent_apps
            .iter()
            .filter_map(|app_id| find_app(*app_id).map(|app| app.title))
            .collect()
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
                if let Some(Target::App(index)) = self.pressed_target {
                    self.focused_tile = index;
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
        if let Some(Target::App(index)) = target {
            self.focused_tile = index;
        }

        target.and_then(|target| self.activate_target(target))
    }

    fn navigate(&mut self, action: NavAction) -> Option<ShellAction> {
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
                self.touch_recent(app_id);
                ShellAction::Launch { app_id }
            }),
            Target::HomeIndicator => self.foreground_app.is_some().then_some(ShellAction::Home),
        }
    }

    fn touch_recent(&mut self, app_id: AppId) {
        self.recent_apps.retain(|candidate| *candidate != app_id);
        self.recent_apps.insert(0, app_id);
        self.recent_apps.truncate(3);
    }

    fn hit_test(&self, point: Point) -> Option<Target> {
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

        home_apps()
            .iter()
            .enumerate()
            .find_map(|(index, _)| {
                app_frame(index)
                    .contains(point)
                    .then_some(Target::App(index))
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

fn build_clock(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    status: &ShellStatus,
    recent_titles: Vec<&'static str>,
) {
    rects.push(RoundedRect::new(
        42.0,
        CLOCK_CARD_Y,
        456.0,
        CLOCK_CARD_HEIGHT,
        46.0,
        SURFACE_RAISED.with_alpha(0.92),
    ));

    texts.push(TextBlock {
        content: status.time_label.clone(),
        left: 66.0,
        top: 168.0,
        width: 408.0,
        height: 90.0,
        size: 78.0,
        line_height: 82.0,
        align: TextAlign::Center,
        weight: TextWeight::Bold,
        color: TEXT_PRIMARY,
    });

    texts.push(TextBlock {
        content: status.date_label.clone(),
        left: 86.0,
        top: 270.0,
        width: 368.0,
        height: 28.0,
        size: 24.0,
        line_height: 28.0,
        align: TextAlign::Center,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });

    if !recent_titles.is_empty() {
        texts.push(TextBlock {
            content: format!("Warm apps: {}", recent_titles.join("  •  ")),
            left: 78.0,
            top: 322.0,
            width: 384.0,
            height: 22.0,
            size: 14.0,
            line_height: 18.0,
            align: TextAlign::Center,
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
}
