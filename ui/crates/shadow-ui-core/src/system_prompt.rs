use shadow_runtime_protocol::{SystemPromptActionStyle, SystemPromptRequest};

use crate::{
    color::{
        Color, BACKGROUND, ICON_BLUE, ICON_RED, SURFACE, SURFACE_GLASS, SURFACE_RAISED, TEXT_MUTED,
        TEXT_PRIMARY,
    },
    scene::{RoundedRect, Scene, TextAlign, TextBlock, TextWeight, HEIGHT, WIDTH},
};

pub const SYSTEM_PROMPT_CARD_X: f32 = 24.0;
pub const SYSTEM_PROMPT_CARD_Y: f32 = 322.0;
pub const SYSTEM_PROMPT_CARD_WIDTH: f32 = WIDTH - 48.0;
pub const SYSTEM_PROMPT_CARD_HEIGHT: f32 = 428.0;

const SYSTEM_PROMPT_CARD_RADIUS: f32 = 34.0;
const SYSTEM_PROMPT_INSET_X: f32 = 24.0;
const SYSTEM_PROMPT_HEADER_TOP: f32 = 28.0;
const SYSTEM_PROMPT_TITLE_TOP: f32 = 62.0;
const SYSTEM_PROMPT_MESSAGE_TOP: f32 = 118.0;
const SYSTEM_PROMPT_MESSAGE_HEIGHT: f32 = 74.0;
const SYSTEM_PROMPT_DETAIL_TOP: f32 = 206.0;
const SYSTEM_PROMPT_DETAIL_HEIGHT: f32 = 122.0;
const SYSTEM_PROMPT_DETAIL_RADIUS: f32 = 24.0;
const SYSTEM_PROMPT_ACTION_TOP: f32 = 350.0;
const SYSTEM_PROMPT_ACTION_HEIGHT: f32 = 54.0;
const SYSTEM_PROMPT_ACTION_RADIUS: f32 = 22.0;
const SYSTEM_PROMPT_ACTION_GAP: f32 = 12.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PromptFrame {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl PromptFrame {
    pub fn contains(self, x: f32, y: f32) -> bool {
        x >= self.x && x <= self.x + self.w && y >= self.y && y <= self.y + self.h
    }
}

pub fn system_prompt_action_frame(index: usize, count: usize) -> PromptFrame {
    let count = count.max(1);
    let total_gap = SYSTEM_PROMPT_ACTION_GAP * (count.saturating_sub(1) as f32);
    let width = ((SYSTEM_PROMPT_CARD_WIDTH - (SYSTEM_PROMPT_INSET_X * 2.0) - total_gap)
        / count as f32)
        .max(1.0);
    PromptFrame {
        x: SYSTEM_PROMPT_CARD_X
            + SYSTEM_PROMPT_INSET_X
            + index as f32 * (width + SYSTEM_PROMPT_ACTION_GAP),
        y: SYSTEM_PROMPT_CARD_Y + SYSTEM_PROMPT_ACTION_TOP,
        w: width,
        h: SYSTEM_PROMPT_ACTION_HEIGHT,
    }
}

pub fn system_prompt_card_frame() -> PromptFrame {
    PromptFrame {
        x: SYSTEM_PROMPT_CARD_X,
        y: SYSTEM_PROMPT_CARD_Y,
        w: SYSTEM_PROMPT_CARD_WIDTH,
        h: SYSTEM_PROMPT_CARD_HEIGHT,
    }
}

pub fn system_prompt_scene(
    request: &SystemPromptRequest,
    app_label: &str,
    focused_action: usize,
    hovered_action: Option<usize>,
    pressed_action: Option<usize>,
    last_activated_action: Option<usize>,
) -> Scene {
    let mut rects = Vec::new();
    let mut texts = Vec::new();

    rects.push(RoundedRect::new(
        0.0,
        0.0,
        WIDTH,
        HEIGHT,
        0.0,
        BACKGROUND.with_alpha(0.76),
    ));
    rects.push(RoundedRect::new(
        SYSTEM_PROMPT_CARD_X,
        SYSTEM_PROMPT_CARD_Y,
        SYSTEM_PROMPT_CARD_WIDTH,
        SYSTEM_PROMPT_CARD_HEIGHT,
        SYSTEM_PROMPT_CARD_RADIUS,
        SURFACE_RAISED.with_alpha(0.98),
    ));

    texts.push(TextBlock {
        content: app_label.to_owned(),
        left: SYSTEM_PROMPT_CARD_X + SYSTEM_PROMPT_INSET_X,
        top: SYSTEM_PROMPT_CARD_Y + SYSTEM_PROMPT_HEADER_TOP,
        width: SYSTEM_PROMPT_CARD_WIDTH - (SYSTEM_PROMPT_INSET_X * 2.0),
        height: 18.0,
        size: 14.0,
        line_height: 16.0,
        align: TextAlign::Left,
        weight: TextWeight::Semibold,
        color: TEXT_MUTED,
    });
    texts.push(TextBlock {
        content: request.title.clone(),
        left: SYSTEM_PROMPT_CARD_X + SYSTEM_PROMPT_INSET_X,
        top: SYSTEM_PROMPT_CARD_Y + SYSTEM_PROMPT_TITLE_TOP,
        width: SYSTEM_PROMPT_CARD_WIDTH - (SYSTEM_PROMPT_INSET_X * 2.0),
        height: 42.0,
        size: 28.0,
        line_height: 30.0,
        align: TextAlign::Left,
        weight: TextWeight::Bold,
        color: TEXT_PRIMARY,
    });
    texts.push(TextBlock {
        content: request.message.clone(),
        left: SYSTEM_PROMPT_CARD_X + SYSTEM_PROMPT_INSET_X,
        top: SYSTEM_PROMPT_CARD_Y + SYSTEM_PROMPT_MESSAGE_TOP,
        width: SYSTEM_PROMPT_CARD_WIDTH - (SYSTEM_PROMPT_INSET_X * 2.0),
        height: SYSTEM_PROMPT_MESSAGE_HEIGHT,
        size: 16.0,
        line_height: 20.0,
        align: TextAlign::Left,
        weight: TextWeight::Normal,
        color: TEXT_PRIMARY,
    });

    if !request.detail_lines.is_empty() {
        rects.push(RoundedRect::new(
            SYSTEM_PROMPT_CARD_X + SYSTEM_PROMPT_INSET_X,
            SYSTEM_PROMPT_CARD_Y + SYSTEM_PROMPT_DETAIL_TOP,
            SYSTEM_PROMPT_CARD_WIDTH - (SYSTEM_PROMPT_INSET_X * 2.0),
            SYSTEM_PROMPT_DETAIL_HEIGHT,
            SYSTEM_PROMPT_DETAIL_RADIUS,
            SURFACE.with_alpha(0.76),
        ));
        texts.push(TextBlock {
            content: request.detail_lines.join("\n"),
            left: SYSTEM_PROMPT_CARD_X + SYSTEM_PROMPT_INSET_X + 18.0,
            top: SYSTEM_PROMPT_CARD_Y + SYSTEM_PROMPT_DETAIL_TOP + 16.0,
            width: SYSTEM_PROMPT_CARD_WIDTH - (SYSTEM_PROMPT_INSET_X * 2.0) - 36.0,
            height: SYSTEM_PROMPT_DETAIL_HEIGHT - 32.0,
            size: 14.0,
            line_height: 18.0,
            align: TextAlign::Left,
            weight: TextWeight::Normal,
            color: TEXT_MUTED,
        });
    }

    for (index, action) in request.actions.iter().enumerate() {
        let frame = system_prompt_action_frame(index, request.actions.len());
        let is_hovered = hovered_action == Some(index);
        let is_pressed = pressed_action == Some(index);
        let is_focused = focused_action == index;
        let is_active = last_activated_action == Some(index);
        let (background, foreground) = action_colors(
            action.style,
            is_hovered || is_focused,
            is_pressed || is_active,
        );
        rects.push(RoundedRect::new(
            frame.x,
            frame.y,
            frame.w,
            frame.h,
            SYSTEM_PROMPT_ACTION_RADIUS,
            background,
        ));
        texts.push(TextBlock {
            content: action.label.clone(),
            left: frame.x + 10.0,
            top: frame.y + 16.0,
            width: frame.w - 20.0,
            height: 22.0,
            size: 14.0,
            line_height: 18.0,
            align: TextAlign::Center,
            weight: if matches!(action.style, SystemPromptActionStyle::Default) {
                TextWeight::Bold
            } else {
                TextWeight::Semibold
            },
            color: foreground,
        });
    }

    Scene {
        clear_color: Color::rgba(0, 0, 0, 0),
        rects,
        texts,
    }
}

fn action_colors(style: SystemPromptActionStyle, selected: bool, active: bool) -> (Color, Color) {
    match style {
        SystemPromptActionStyle::Default => (
            ICON_BLUE.with_alpha(if active {
                0.86
            } else if selected {
                0.78
            } else {
                0.68
            }),
            BACKGROUND,
        ),
        SystemPromptActionStyle::Danger => (
            ICON_RED.with_alpha(if active {
                0.78
            } else if selected {
                0.68
            } else {
                0.58
            }),
            TEXT_PRIMARY,
        ),
        SystemPromptActionStyle::Normal => (
            SURFACE_GLASS.with_alpha(if active {
                0.98
            } else if selected {
                0.92
            } else {
                0.86
            }),
            TEXT_PRIMARY,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::{system_prompt_action_frame, system_prompt_card_frame, system_prompt_scene};
    use shadow_runtime_protocol::{
        SystemPromptAction, SystemPromptActionStyle, SystemPromptRequest,
    };

    fn demo_request() -> SystemPromptRequest {
        SystemPromptRequest {
            source_app_id: String::from("rust-timeline"),
            source_app_title: Some(String::from("Rust Timeline")),
            title: String::from("Allow publish?"),
            message: String::from("A shared signer request is waiting."),
            detail_lines: vec![
                String::from("Account: npub1test"),
                String::from("Preview: hello shadow"),
            ],
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
    fn action_frames_fit_within_card() {
        let card = system_prompt_card_frame();
        for index in 0..3 {
            let frame = system_prompt_action_frame(index, 3);
            assert!(frame.x >= card.x);
            assert!(frame.y >= card.y);
            assert!(frame.x + frame.w <= card.x + card.w);
            assert!(frame.y + frame.h <= card.y + card.h);
        }
    }

    #[test]
    fn prompt_scene_is_transparent_overlay() {
        let scene = system_prompt_scene(&demo_request(), "Rust Timeline", 1, Some(1), None, None);

        assert_eq!(scene.clear_color.rgba8(), [0, 0, 0, 0]);
        assert!(!scene.rects.is_empty());
        assert!(scene
            .texts
            .iter()
            .any(|text| text.content == "Allow publish?"));
        assert!(scene.texts.iter().any(|text| text.content == "Allow Once"));
    }
}
