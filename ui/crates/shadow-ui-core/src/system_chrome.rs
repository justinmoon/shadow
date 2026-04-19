use crate::{
    color::{Color, SURFACE_GLASS, TEXT_PRIMARY},
    scene::{RoundedRect, Scene, TextAlign, TextBlock, TextWeight, APP_VIEWPORT_BOTTOM_PX, WIDTH},
};

pub const TOP_CHROME_STRIP_X: f32 = 16.0;
pub const TOP_CHROME_STRIP_Y: f32 = 10.0;
pub const TOP_CHROME_STRIP_WIDTH: f32 = WIDTH - 32.0;
pub const TOP_CHROME_STRIP_HEIGHT: f32 = 30.0;

const TOP_CHROME_STRIP_RADIUS: f32 = TOP_CHROME_STRIP_HEIGHT * 0.5;
const TIME_LABEL_LEFT: f32 = 18.0;
const TIME_LABEL_TOP: f32 = 6.0;
const TIME_LABEL_WIDTH: f32 = 100.0;
const TIME_LABEL_HEIGHT: f32 = 18.0;
const BATTERY_OUTLINE_X: f32 = 434.0;
const BATTERY_OUTLINE_Y: f32 = 8.0;
const BATTERY_OUTLINE_WIDTH: f32 = 22.0;
const BATTERY_OUTLINE_HEIGHT: f32 = 12.0;
const BATTERY_CAP_X: f32 = 457.0;
const BATTERY_CAP_Y: f32 = 11.0;
const BATTERY_CAP_WIDTH: f32 = 4.0;
const BATTERY_CAP_HEIGHT: f32 = 6.0;
const BATTERY_FILL_X: f32 = 436.0;
const BATTERY_FILL_Y: f32 = 21.0;
const BATTERY_FILL_MAX_WIDTH: f32 = 18.0;
const BATTERY_FILL_HEIGHT: f32 = 8.0;
const WIFI_BAR_X: f32 = 392.0;
const WIFI_BAR_STEP_X: f32 = 10.0;
const WIFI_BAR_BASE_Y: f32 = 14.0;
const WIFI_BAR_STEP_Y: f32 = 4.0;
const WIFI_BAR_WIDTH: f32 = 7.0;
const WIFI_BAR_BASE_HEIGHT: f32 = 6.0;
const WIFI_BAR_STEP_HEIGHT: f32 = 3.0;

pub const BOTTOM_NAVIGATION_PILL_X: f32 = 186.0;
pub const BOTTOM_NAVIGATION_PILL_Y: f32 = APP_VIEWPORT_BOTTOM_PX as f32;
pub const BOTTOM_NAVIGATION_PILL_WIDTH: f32 = 168.0;
pub const BOTTOM_NAVIGATION_PILL_HEIGHT: f32 = 14.0;

const BOTTOM_NAVIGATION_PILL_RADIUS: f32 = BOTTOM_NAVIGATION_PILL_HEIGHT * 0.5;
const BOTTOM_NAVIGATION_PILL_INNER_X: f32 = 36.0;
const BOTTOM_NAVIGATION_PILL_INNER_Y: f32 = 4.0;
const BOTTOM_NAVIGATION_PILL_INNER_WIDTH: f32 = 96.0;
const BOTTOM_NAVIGATION_PILL_INNER_HEIGHT: f32 = 6.0;
const BOTTOM_NAVIGATION_PILL_INNER_RADIUS: f32 = BOTTOM_NAVIGATION_PILL_INNER_HEIGHT * 0.5;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TopChromeStripState {
    pub time_label: String,
    pub battery_percent: u8,
    pub wifi_strength: u8,
    pub home_enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BottomNavigationPillState {
    pub active: bool,
}

pub fn top_chrome_strip_scene(state: &TopChromeStripState) -> Scene {
    let mut rects = Vec::new();
    let mut texts = Vec::new();
    append_top_chrome_strip_at(&mut rects, &mut texts, state, 0.0, 0.0);

    Scene {
        clear_color: Color::rgba(0, 0, 0, 0),
        rects,
        texts,
    }
}

pub fn bottom_navigation_pill_scene(state: BottomNavigationPillState) -> Scene {
    let mut rects = Vec::new();
    append_bottom_navigation_pill_at(&mut rects, state, 0.0, 0.0);

    Scene {
        clear_color: Color::rgba(0, 0, 0, 0),
        rects,
        texts: Vec::new(),
    }
}

pub(crate) fn append_top_chrome_strip(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    state: &TopChromeStripState,
) {
    append_top_chrome_strip_at(rects, texts, state, TOP_CHROME_STRIP_X, TOP_CHROME_STRIP_Y);
}

fn append_top_chrome_strip_at(
    rects: &mut Vec<RoundedRect>,
    texts: &mut Vec<TextBlock>,
    state: &TopChromeStripState,
    origin_x: f32,
    origin_y: f32,
) {
    rects.push(RoundedRect::new(
        origin_x,
        origin_y,
        TOP_CHROME_STRIP_WIDTH,
        TOP_CHROME_STRIP_HEIGHT,
        TOP_CHROME_STRIP_RADIUS,
        SURFACE_GLASS,
    ));

    texts.push(TextBlock {
        content: state.time_label.clone(),
        left: origin_x + TIME_LABEL_LEFT,
        top: origin_y + TIME_LABEL_TOP,
        width: TIME_LABEL_WIDTH,
        height: TIME_LABEL_HEIGHT,
        size: 14.0,
        line_height: 16.0,
        align: TextAlign::Left,
        weight: TextWeight::Semibold,
        color: TEXT_PRIMARY,
    });

    let battery_fill = (state.battery_percent.min(100) as f32 / 100.0).max(0.12);
    rects.push(RoundedRect::new(
        origin_x + BATTERY_OUTLINE_X,
        origin_y + BATTERY_OUTLINE_Y,
        BATTERY_OUTLINE_WIDTH,
        BATTERY_OUTLINE_HEIGHT,
        3.0,
        TEXT_PRIMARY.with_alpha(0.18),
    ));
    rects.push(RoundedRect::new(
        origin_x + BATTERY_CAP_X,
        origin_y + BATTERY_CAP_Y,
        BATTERY_CAP_WIDTH,
        BATTERY_CAP_HEIGHT,
        2.0,
        TEXT_PRIMARY.with_alpha(0.65),
    ));
    rects.push(RoundedRect::new(
        origin_x + BATTERY_FILL_X,
        origin_y + BATTERY_FILL_Y,
        BATTERY_FILL_MAX_WIDTH * battery_fill,
        BATTERY_FILL_HEIGHT,
        2.0,
        TEXT_PRIMARY.with_alpha(0.78),
    ));

    for index in 0..3 {
        let alpha = if index < state.wifi_strength.min(3) as usize {
            0.72
        } else {
            0.24 + index as f32 * 0.06
        };
        rects.push(RoundedRect::new(
            origin_x + WIFI_BAR_X + index as f32 * WIFI_BAR_STEP_X,
            origin_y + WIFI_BAR_BASE_Y - index as f32 * WIFI_BAR_STEP_Y,
            WIFI_BAR_WIDTH,
            WIFI_BAR_BASE_HEIGHT + index as f32 * WIFI_BAR_STEP_HEIGHT,
            3.0,
            TEXT_PRIMARY.with_alpha(alpha),
        ));
    }
}

pub(crate) fn append_bottom_navigation_pill(
    rects: &mut Vec<RoundedRect>,
    state: BottomNavigationPillState,
) {
    append_bottom_navigation_pill_at(
        rects,
        state,
        BOTTOM_NAVIGATION_PILL_X,
        BOTTOM_NAVIGATION_PILL_Y,
    );
}

fn append_bottom_navigation_pill_at(
    rects: &mut Vec<RoundedRect>,
    state: BottomNavigationPillState,
    origin_x: f32,
    origin_y: f32,
) {
    rects.push(RoundedRect::new(
        origin_x,
        origin_y,
        BOTTOM_NAVIGATION_PILL_WIDTH,
        BOTTOM_NAVIGATION_PILL_HEIGHT,
        BOTTOM_NAVIGATION_PILL_RADIUS,
        SURFACE_GLASS.with_alpha(if state.active { 0.96 } else { 0.88 }),
    ));
    rects.push(RoundedRect::new(
        origin_x + BOTTOM_NAVIGATION_PILL_INNER_X,
        origin_y + BOTTOM_NAVIGATION_PILL_INNER_Y,
        BOTTOM_NAVIGATION_PILL_INNER_WIDTH,
        BOTTOM_NAVIGATION_PILL_INNER_HEIGHT,
        BOTTOM_NAVIGATION_PILL_INNER_RADIUS,
        TEXT_PRIMARY.with_alpha(if state.active { 0.96 } else { 0.76 }),
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_scene_is_transparent_overlay_with_shared_bounds() {
        let scene = top_chrome_strip_scene(&TopChromeStripState {
            time_label: "09:41".to_string(),
            battery_percent: 78,
            wifi_strength: 2,
            home_enabled: true,
        });

        assert_eq!(scene.clear_color.rgba8(), [0, 0, 0, 0]);
        assert_eq!(scene.rects[0].x, 0.0);
        assert_eq!(scene.rects[0].y, 0.0);
        assert_eq!(scene.rects[0].width, TOP_CHROME_STRIP_WIDTH);
        assert_eq!(scene.rects[0].height, TOP_CHROME_STRIP_HEIGHT);
        assert_eq!(scene.texts[0].content, "09:41");
        assert!(scene.rects.iter().all(|rect| {
            rect.x >= 0.0
                && rect.y >= 0.0
                && rect.x + rect.width <= TOP_CHROME_STRIP_WIDTH
                && rect.y + rect.height <= TOP_CHROME_STRIP_HEIGHT
        }));
    }

    #[test]
    fn bottom_navigation_pill_scene_is_transparent_overlay_with_shared_bounds() {
        let scene = bottom_navigation_pill_scene(BottomNavigationPillState { active: true });

        assert_eq!(scene.clear_color.rgba8(), [0, 0, 0, 0]);
        assert_eq!(scene.rects.len(), 2);
        assert_eq!(scene.rects[0].x, 0.0);
        assert_eq!(scene.rects[0].y, 0.0);
        assert_eq!(scene.rects[0].width, BOTTOM_NAVIGATION_PILL_WIDTH);
        assert_eq!(scene.rects[0].height, BOTTOM_NAVIGATION_PILL_HEIGHT);
        assert!(scene.texts.is_empty());
        assert!(scene.rects.iter().all(|rect| {
            rect.x >= 0.0
                && rect.y >= 0.0
                && rect.x + rect.width <= BOTTOM_NAVIGATION_PILL_WIDTH
                && rect.y + rect.height <= BOTTOM_NAVIGATION_PILL_HEIGHT
        }));
    }
}
