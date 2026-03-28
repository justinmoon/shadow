use std::time::{Duration, Instant};

use chrono::{DateTime, Local};

use crate::{
    app::HOME_TILES,
    color::{
        BACKGROUND, SURFACE, SURFACE_ACCENT, SURFACE_GLASS, SURFACE_RAISED, TEXT_MUTED,
        TEXT_PRIMARY,
    },
    scene::{RoundedRect, Scene, TextAlign, TextBlock, TextWeight, HEIGHT, WIDTH},
};

const STATUS_BAR_HEIGHT: f32 = 54.0;
const CLOCK_CARD_Y: f32 = 124.0;
const CLOCK_CARD_HEIGHT: f32 = 250.0;
const APP_PANEL_Y: f32 = 420.0;
const APP_PANEL_HEIGHT: f32 = 640.0;
const APP_ICON_SIZE: f32 = 96.0;
const APP_LABEL_HEIGHT: f32 = 24.0;
const GRID_COLUMNS: usize = 4;
const PRESS_FLASH: Duration = Duration::from_millis(160);

#[derive(Clone, Copy, Debug)]
pub enum NavAction {
    Left,
    Right,
    Up,
    Down,
    Next,
    Previous,
    Activate,
}

#[derive(Clone, Copy, Debug)]
pub enum PointerButtonState {
    Pressed,
    Released,
}

#[derive(Clone, Copy)]
struct Point {
    x: f32,
    y: f32,
}

#[derive(Clone, Copy)]
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

pub struct ShellModel {
    cursor: Option<Point>,
    hovered_app: Option<usize>,
    pressed_app: Option<usize>,
    focused_app: usize,
    last_activated: Option<(usize, Instant)>,
}

impl ShellModel {
    pub fn new() -> Self {
        Self {
            cursor: None,
            hovered_app: None,
            pressed_app: None,
            focused_app: 0,
            last_activated: None,
        }
    }

    pub fn pointer_moved(&mut self, x: f32, y: f32) {
        let point = Point { x, y };
        self.cursor = Some(point);
        self.hovered_app = self.hit_test(point);
    }

    pub fn pointer_left(&mut self) {
        self.cursor = None;
        self.hovered_app = None;
        self.pressed_app = None;
    }

    pub fn pointer_button(&mut self, state: PointerButtonState) {
        match state {
            PointerButtonState::Pressed => {
                self.pressed_app = self.cursor.and_then(|cursor| self.hit_test(cursor));
            }
            PointerButtonState::Released => {
                let target = self.cursor.and_then(|cursor| self.hit_test(cursor));
                if self.pressed_app == target {
                    if let Some(index) = target {
                        self.focused_app = index;
                        self.activate(index);
                    }
                }
                self.pressed_app = None;
            }
        }
    }

    pub fn navigate(&mut self, action: NavAction) {
        match action {
            NavAction::Left => self.focused_app = move_focus(self.focused_app, -1, 0),
            NavAction::Right => self.focused_app = move_focus(self.focused_app, 1, 0),
            NavAction::Up => self.focused_app = move_focus(self.focused_app, 0, -1),
            NavAction::Down => self.focused_app = move_focus(self.focused_app, 0, 1),
            NavAction::Next => self.focused_app = wrap_index(self.focused_app, 1),
            NavAction::Previous => self.focused_app = wrap_index(self.focused_app, -1),
            NavAction::Activate => self.activate(self.focused_app),
        }
    }

    pub fn scene(&mut self, now: DateTime<Local>) -> Scene {
        self.trim_expired_flash();

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

        build_status_bar(&mut rects, &mut texts, now);
        build_clock(&mut rects, &mut texts, now);
        self.build_app_grid(&mut rects, &mut texts);
        build_navigation_bar(&mut rects);

        Scene {
            clear_color: BACKGROUND,
            rects,
            texts,
        }
    }

    fn build_app_grid(&self, rects: &mut Vec<RoundedRect>, texts: &mut Vec<TextBlock>) {
        let grid = grid_origin();

        for (index, app) in HOME_TILES.iter().enumerate() {
            let frame = app_frame(index);
            let is_focused = self.focused_app == index;
            let is_hovered = self.hovered_app == Some(index);
            let is_pressed = self.pressed_app == Some(index);
            let is_active = self.last_activated.map(|(i, _)| i) == Some(index);

            let halo_alpha = if is_pressed {
                0.34
            } else if is_active {
                0.24
            } else if is_focused {
                0.20
            } else if is_hovered {
                0.14
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
                icon_x, icon_y, icon_size, icon_size, 26.0, app.color,
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
                content: app.label.to_string(),
                left: frame.x,
                top: frame.y + APP_ICON_SIZE + 22.0,
                width: frame.w,
                height: APP_LABEL_HEIGHT,
                size: 17.0,
                line_height: 20.0,
                align: TextAlign::Center,
                weight: if is_focused {
                    TextWeight::Semibold
                } else {
                    TextWeight::Normal
                },
                color: TEXT_PRIMARY,
            });
        }

        texts.push(TextBlock {
            content: "Use mouse or arrow keys + Enter".to_string(),
            left: grid.x,
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

    fn activate(&mut self, index: usize) {
        self.last_activated = Some((index, Instant::now()));
    }

    fn trim_expired_flash(&mut self) {
        if let Some((_, instant)) = self.last_activated {
            if instant.elapsed() >= PRESS_FLASH {
                self.last_activated = None;
            }
        }
    }

    fn hit_test(&self, point: Point) -> Option<usize> {
        HOME_TILES
            .iter()
            .enumerate()
            .find_map(|(index, _)| app_frame(index).contains(point).then_some(index))
    }
}

fn build_status_bar(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    now: DateTime<Local>,
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
        content: now.format("%H:%M").to_string(),
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
        14.0,
        8.0,
        2.0,
        TEXT_PRIMARY.with_alpha(0.72),
    ));

    rects.push(RoundedRect::new(
        408.0,
        35.0,
        7.0,
        6.0,
        3.0,
        TEXT_PRIMARY.with_alpha(0.38),
    ));
    rects.push(RoundedRect::new(
        418.0,
        32.0,
        7.0,
        9.0,
        3.0,
        TEXT_PRIMARY.with_alpha(0.52),
    ));
    rects.push(RoundedRect::new(
        428.0,
        28.0,
        7.0,
        13.0,
        3.0,
        TEXT_PRIMARY.with_alpha(0.72),
    ));
}

fn build_clock(rects: &mut Vec<RoundedRect>, texts: &mut Vec<TextBlock>, now: DateTime<Local>) {
    rects.push(RoundedRect::new(
        42.0,
        CLOCK_CARD_Y,
        456.0,
        CLOCK_CARD_HEIGHT,
        46.0,
        SURFACE_RAISED.with_alpha(0.92),
    ));

    texts.push(TextBlock {
        content: now.format("%H:%M").to_string(),
        left: 66.0,
        top: 172.0,
        width: 408.0,
        height: 90.0,
        size: 78.0,
        line_height: 82.0,
        align: TextAlign::Center,
        weight: TextWeight::Bold,
        color: TEXT_PRIMARY,
    });

    texts.push(TextBlock {
        content: now.format("%A, %B %-d").to_string(),
        left: 86.0,
        top: 274.0,
        width: 368.0,
        height: 28.0,
        size: 24.0,
        line_height: 28.0,
        align: TextAlign::Center,
        weight: TextWeight::Normal,
        color: TEXT_MUTED,
    });
}

fn build_navigation_bar(rects: &mut Vec<RoundedRect>) {
    rects.push(RoundedRect::new(
        186.0,
        1106.0,
        168.0,
        14.0,
        7.0,
        SURFACE_GLASS.with_alpha(0.88),
    ));
    rects.push(RoundedRect::new(
        222.0,
        1110.0,
        96.0,
        6.0,
        3.0,
        TEXT_PRIMARY.with_alpha(0.76),
    ));
}

fn grid_origin() -> Point {
    Point { x: 52.0, y: 510.0 }
}

fn app_frame(index: usize) -> Frame {
    let origin = grid_origin();
    let col = index % GRID_COLUMNS;
    let row = index / GRID_COLUMNS;
    let stride_x = 110.0;
    let stride_y = 164.0;

    Frame {
        x: origin.x + col as f32 * stride_x,
        y: origin.y + row as f32 * stride_y,
        w: 104.0,
        h: 142.0,
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn navigation_stays_within_grid_bounds() {
        let mut shell = ShellModel::new();

        shell.navigate(NavAction::Left);
        assert_eq!(shell.focused_app, 0);

        shell.navigate(NavAction::Up);
        assert_eq!(shell.focused_app, 0);

        shell.navigate(NavAction::Right);
        assert_eq!(shell.focused_app, 1);

        shell.navigate(NavAction::Down);
        assert_eq!(shell.focused_app, 5);

        shell.navigate(NavAction::Down);
        assert_eq!(shell.focused_app, 5);
    }

    #[test]
    fn tab_navigation_wraps_across_apps() {
        let mut shell = ShellModel::new();

        for _ in 0..HOME_TILES.len() {
            shell.navigate(NavAction::Next);
        }
        assert_eq!(shell.focused_app, 0);

        shell.navigate(NavAction::Previous);
        assert_eq!(shell.focused_app, HOME_TILES.len() - 1);
    }

    #[test]
    fn pointer_click_focuses_and_activates_target() {
        let mut shell = ShellModel::new();
        let frame = app_frame(3);
        let point = Point {
            x: frame.x + frame.w * 0.5,
            y: frame.y + frame.h * 0.5,
        };

        shell.pointer_moved(point.x, point.y);
        shell.pointer_button(PointerButtonState::Pressed);
        shell.pointer_button(PointerButtonState::Released);

        assert_eq!(shell.focused_app, 3);
        assert_eq!(shell.hovered_app, Some(3));
        assert_eq!(shell.last_activated.map(|(index, _)| index), Some(3));
    }

    #[test]
    fn scene_clears_expired_flash_state() {
        let mut shell = ShellModel::new();
        shell.last_activated = Some((2, Instant::now() - PRESS_FLASH - Duration::from_millis(1)));

        let _ = shell.scene(Local::now());

        assert!(shell.last_activated.is_none());
    }
}
