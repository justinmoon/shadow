use std::time::{Duration, Instant};

use chrono::{DateTime, Local};

use crate::{
    app::{find_app, AppId, HOME_TILES},
    color::{
        BACKGROUND, SURFACE, SURFACE_ACCENT, SURFACE_GLASS, SURFACE_RAISED, TEXT_MUTED,
        TEXT_PRIMARY,
    },
    scene::{
        RoundedRect, Scene, TextAlign, TextBlock, TextWeight, APP_VIEWPORT_HEIGHT,
        APP_VIEWPORT_WIDTH, APP_VIEWPORT_X, APP_VIEWPORT_Y, HEIGHT, WIDTH,
    },
};

const PRESS_FLASH: Duration = Duration::from_millis(160);
const STATUS_BAR_HEIGHT: f32 = 54.0;
const CLOCK_CARD_Y: f32 = 124.0;
const CLOCK_CARD_HEIGHT: f32 = 250.0;
const APP_PANEL_Y: f32 = 420.0;
const APP_PANEL_HEIGHT: f32 = 640.0;
const APP_ICON_SIZE: f32 = 96.0;
const APP_LABEL_HEIGHT: f32 = 24.0;
const APP_HEADER_Y: f32 = 86.0;
const APP_HEADER_HEIGHT: f32 = 58.0;
const APP_CHROME_BOTTOM_Y: f32 = APP_VIEWPORT_Y + APP_VIEWPORT_HEIGHT + 22.0;
const APP_CHROME_BOTTOM_HEIGHT: f32 = 54.0;
const APP_FRAME_SIDE_WIDTH: f32 = 18.0;
const GRID_COLUMNS: usize = 4;

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
            ShellEvent::Navigate(action) => self.navigate(action),
        }
    }

    pub fn scene(&mut self, status: &ShellStatus) -> Scene {
        self.trim_expired_flash();

        if let Some(app_id) = self.foreground_app {
            return self.app_scene(status, app_id);
        }

        self.home_scene(status)
    }

    pub fn captures_point(&self, x: f32, y: f32) -> bool {
        let point = Point { x, y };

        if self.foreground_app.is_some() {
            !app_viewport_frame().contains(point)
        } else {
            shell_frame().contains(point)
        }
    }

    fn home_scene(&self, status: &ShellStatus) -> Scene {
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

        build_status_bar(&mut rects, &mut texts, status);
        build_clock(&mut rects, &mut texts, status, self.recent_app_titles());
        build_panel_header(&mut rects, &mut texts, self);
        build_app_grid(&mut rects, &mut texts, self);
        build_navigation_bar(&mut rects, self.home_indicator_active());

        Scene {
            clear_color: BACKGROUND,
            rects,
            texts,
        }
    }

    fn app_scene(&self, status: &ShellStatus, app_id: AppId) -> Scene {
        let mut rects = Vec::new();
        let mut texts = Vec::new();
        let app = find_app(app_id).expect("foreground app metadata");
        let viewport = app_viewport_frame();

        build_status_bar(&mut rects, &mut texts, status);

        rects.push(RoundedRect::new(
            20.0,
            APP_HEADER_Y,
            500.0,
            APP_HEADER_HEIGHT,
            28.0,
            SURFACE_GLASS.with_alpha(0.92),
        ));
        rects.push(RoundedRect::new(
            392.0,
            98.0,
            98.0,
            32.0,
            16.0,
            TEXT_PRIMARY.with_alpha(0.12),
        ));

        let frame_color = SURFACE.with_alpha(0.94);
        rects.push(RoundedRect::new(
            0.0,
            viewport.y - 6.0,
            APP_FRAME_SIDE_WIDTH,
            viewport.h + 12.0,
            0.0,
            frame_color,
        ));
        rects.push(RoundedRect::new(
            WIDTH - APP_FRAME_SIDE_WIDTH,
            viewport.y - 6.0,
            APP_FRAME_SIDE_WIDTH,
            viewport.h + 12.0,
            0.0,
            frame_color,
        ));
        rects.push(RoundedRect::new(
            APP_VIEWPORT_X,
            viewport.y - 10.0,
            APP_VIEWPORT_WIDTH,
            12.0,
            6.0,
            frame_color,
        ));
        rects.push(RoundedRect::new(
            20.0,
            APP_CHROME_BOTTOM_Y,
            500.0,
            APP_CHROME_BOTTOM_HEIGHT,
            26.0,
            SURFACE_GLASS.with_alpha(0.92),
        ));

        texts.push(TextBlock {
            content: app.title.to_string(),
            left: 48.0,
            top: 100.0,
            width: 220.0,
            height: 24.0,
            size: 24.0,
            line_height: 26.0,
            align: TextAlign::Left,
            weight: TextWeight::Semibold,
            color: TEXT_PRIMARY,
        });
        texts.push(TextBlock {
            content: app.subtitle.to_string(),
            left: 176.0,
            top: 106.0,
            width: 150.0,
            height: 20.0,
            size: 14.0,
            line_height: 18.0,
            align: TextAlign::Left,
            weight: TextWeight::Normal,
            color: TEXT_MUTED,
        });
        texts.push(TextBlock {
            content: "Running".to_string(),
            left: 392.0,
            top: 106.0,
            width: 98.0,
            height: 18.0,
            size: 14.0,
            line_height: 16.0,
            align: TextAlign::Center,
            weight: TextWeight::Semibold,
            color: TEXT_PRIMARY,
        });
        texts.push(TextBlock {
            content: "Esc/Home returns".to_string(),
            left: 52.0,
            top: APP_CHROME_BOTTOM_Y + 18.0,
            width: 436.0,
            height: 18.0,
            size: 14.0,
            line_height: 16.0,
            align: TextAlign::Center,
            weight: TextWeight::Normal,
            color: TEXT_MUTED,
        });

        build_navigation_bar(&mut rects, true);

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
            Target::App(index) => HOME_TILES[index].app_id.map(|app_id| {
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
                .then_some(Target::HomeIndicator);
        }

        HOME_TILES
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
    HOME_TILES
        .iter()
        .enumerate()
        .find_map(|(index, tile)| tile.app_id.map(|_| index))
        .unwrap_or(0)
}

fn tile_index_for_app(app_id: AppId) -> Option<usize> {
    HOME_TILES
        .iter()
        .enumerate()
        .find_map(|(index, tile)| (tile.app_id == Some(app_id)).then_some(index))
}

fn move_focus(current: usize, dx: isize, dy: isize) -> usize {
    let cols = GRID_COLUMNS as isize;
    let rows = (HOME_TILES.len() / GRID_COLUMNS) as isize;
    let col = current as isize % cols;
    let row = current as isize / cols;

    let next_col = (col + dx).clamp(0, cols - 1);
    let next_row = (row + dy).clamp(0, rows - 1);
    (next_row * cols + next_col) as usize
}

fn wrap_index(current: usize, delta: isize) -> usize {
    let len = HOME_TILES.len() as isize;
    ((current as isize + delta).rem_euclid(len)) as usize
}

fn build_status_bar(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    status: &ShellStatus,
) {
    rects.push(RoundedRect::new(
        16.0,
        14.0,
        508.0,
        STATUS_BAR_HEIGHT,
        24.0,
        SURFACE_GLASS,
    ));

    texts.push(TextBlock {
        content: status.time_label.clone(),
        left: 34.0,
        top: 27.0,
        width: 100.0,
        height: 24.0,
        size: 18.0,
        line_height: 20.0,
        align: TextAlign::Left,
        weight: TextWeight::Semibold,
        color: TEXT_PRIMARY,
    });

    let battery_fill = (status.battery_percent.min(100) as f32 / 100.0).max(0.12);
    rects.push(RoundedRect::new(
        450.0,
        29.0,
        22.0,
        12.0,
        3.0,
        TEXT_PRIMARY.with_alpha(0.18),
    ));
    rects.push(RoundedRect::new(
        473.0,
        32.0,
        4.0,
        6.0,
        2.0,
        TEXT_PRIMARY.with_alpha(0.65),
    ));
    rects.push(RoundedRect::new(
        452.0,
        31.0,
        18.0 * battery_fill,
        8.0,
        2.0,
        TEXT_PRIMARY.with_alpha(0.78),
    ));

    for index in 0..3 {
        let alpha = if index < status.wifi_strength.min(3) as usize {
            0.72
        } else {
            0.24 + index as f32 * 0.06
        };
        rects.push(RoundedRect::new(
            408.0 + index as f32 * 10.0,
            35.0 - index as f32 * 4.0,
            7.0,
            6.0 + index as f32 * 3.0,
            3.0,
            TEXT_PRIMARY.with_alpha(alpha),
        ));
    }
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
                format!("Tap the pill or press Home to shelf it. {}.", app.subtitle),
            )
        }
        None if model.running_apps().is_empty() => (
            "Home stack".to_string(),
            "Launch an app when you want one. The shell stays resident here.".to_string(),
        ),
        None => (
            "Home stack".to_string(),
            format!(
                "{} app(s) warm in the background.",
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
    for (index, tile) in HOME_TILES.iter().enumerate() {
        let frame = app_frame(index);
        let target = Target::App(index);
        let is_focused = model.focused_tile == index;
        let is_hovered = model.hovered_target == Some(target);
        let is_pressed = model.pressed_target == Some(target);
        let is_active = model.last_activated.map(|(target, _)| target) == Some(target);
        let app_id = tile.app_id;
        let is_running = app_id.is_some_and(|app_id| model.app_is_running(app_id));
        let is_foreground = app_id.is_some_and(|app_id| model.app_is_foreground(app_id));

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
            icon_x, icon_y, icon_size, icon_size, 26.0, tile.color,
        ));
        rects.push(RoundedRect::new(
            icon_x + 16.0,
            icon_y + 20.0,
            icon_size - 32.0,
            10.0,
            5.0,
            TEXT_PRIMARY.with_alpha(0.16),
        ));

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
            content: tile.label.to_string(),
            left: frame.x,
            top: frame.y + APP_ICON_SIZE + 22.0,
            width: frame.w,
            height: APP_LABEL_HEIGHT,
            size: 15.0,
            line_height: 18.0,
            align: TextAlign::Center,
            weight: if is_foreground || is_focused {
                TextWeight::Semibold
            } else {
                TextWeight::Normal
            },
            color: TEXT_PRIMARY,
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

fn build_navigation_bar(rects: &mut Vec<RoundedRect>, active: bool) {
    rects.push(RoundedRect::new(
        186.0,
        1106.0,
        168.0,
        14.0,
        7.0,
        SURFACE_GLASS.with_alpha(if active { 0.96 } else { 0.88 }),
    ));
    rects.push(RoundedRect::new(
        222.0,
        1110.0,
        96.0,
        6.0,
        3.0,
        TEXT_PRIMARY.with_alpha(if active { 0.96 } else { 0.76 }),
    ));
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
    let col = index % GRID_COLUMNS;
    let row = index / GRID_COLUMNS;

    Frame {
        x: origin.x + col as f32 * 110.0,
        y: origin.y + row as f32 * 164.0,
        w: 104.0,
        h: 142.0,
    }
}

fn home_indicator_frame() -> Frame {
    Frame {
        x: 186.0,
        y: 1098.0,
        w: 168.0,
        h: 26.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::COUNTER_APP_ID;

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
    fn home_requires_foreground_app() {
        let mut shell = ShellModel::new();
        assert_eq!(shell.handle(ShellEvent::Navigate(NavAction::Home)), None);

        shell.set_foreground_app(Some(COUNTER_APP_ID));
        assert_eq!(
            shell.handle(ShellEvent::Navigate(NavAction::Home)),
            Some(ShellAction::Home)
        );
    }
}
