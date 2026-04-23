use std::fmt::Debug;

use xilem::core::fork;
use xilem::masonry::properties::types::AsUnit;
use xilem::masonry::properties::types::CrossAxisAlignment;
use xilem::masonry::properties::types::UnitPoint;
use xilem::masonry::properties::Padding;
use xilem::style::Style as _;
use xilem::tokio;
use xilem::view::{
    button, flex_col, flex_row, label, portal, prose, sized_box, task_raw, text_input, zstack,
    Flex, FlexExt, FlexSequence, FlexSpacer, ZStackExt,
};
use xilem::{AnyWidgetView, Color, FontWeight, InsertNewline, WidgetView};

use crate::app::AppWindowMetrics;

use super::{
    task::{apply_task_decorations, TaskDecoration, TaskHandle},
    theme::Theme,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    Neutral,
    Accent,
    Success,
    Danger,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActionButtonState {
    Enabled,
    Disabled,
    Pending,
}

pub fn column<State, Action, Seq>(children: Seq) -> Flex<Seq, State, Action>
where
    Seq: FlexSequence<State, Action>,
{
    flex_col(children)
}

pub fn row<State, Action, Seq>(children: Seq) -> Flex<Seq, State, Action>
where
    Seq: FlexSequence<State, Action>,
{
    flex_row(children)
}

pub fn maybe<State: 'static, Action: 'static>(
    content: Option<impl WidgetView<State, Action>>,
    fallback: impl WidgetView<State, Action>,
) -> Box<AnyWidgetView<State, Action>> {
    match content {
        Some(content) => content.boxed(),
        None => fallback.boxed(),
    }
}

pub(super) fn screen<State: Send + Sync + 'static, Action: Send + Sync + 'static>(
    metrics: AppWindowMetrics,
    theme: Theme,
    body: impl WidgetView<State, Action>,
) -> impl WidgetView<State, Action> {
    let padding = Padding {
        left: f64::from(metrics.safe_area_insets.left) + 18.0,
        top: f64::from(metrics.safe_area_insets.top) + 18.0,
        right: f64::from(metrics.safe_area_insets.right) + 18.0,
        bottom: f64::from(metrics.safe_area_insets.bottom) + 18.0,
    };

    sized_box(portal(sized_box(body).padding(padding))).background_color(theme.background)
}

pub(super) fn panel<State: 'static, Action: 'static>(
    theme: Theme,
    body: impl WidgetView<State, Action>,
) -> impl WidgetView<State, Action> {
    sized_box(body)
        .padding(16.0)
        .background_color(theme.surface)
        .border(theme.border, 1.0)
        .corner_radius(6.0)
}

pub(super) fn eyebrow_text<State: 'static, Action: 'static>(
    text: impl Into<String>,
    theme: Theme,
) -> impl WidgetView<State, Action> {
    label(text.into())
        .text_size(11.0)
        .weight(FontWeight::SEMI_BOLD)
        .color(theme.text_muted)
}

pub(super) fn headline_text<State: 'static, Action: 'static>(
    text: impl Into<String>,
    theme: Theme,
) -> impl WidgetView<State, Action> {
    label(text.into())
        .text_size(28.0)
        .weight(FontWeight::BOLD)
        .color(theme.text_primary)
}

pub(super) fn top_bar<State: 'static, Action: 'static>(
    theme: Theme,
    eyebrow: impl Into<String>,
    title: impl Into<String>,
    subtitle: Option<String>,
) -> impl WidgetView<State, Action> {
    panel(
        theme,
        column((
            eyebrow_text(eyebrow, theme),
            label(title.into())
                .text_size(22.0)
                .weight(FontWeight::BOLD)
                .color(theme.text_primary),
            subtitle.map(|subtitle| caption_text(subtitle, theme)),
        ))
        .gap(4.0.px()),
    )
}

pub(super) fn top_bar_with_back<State: 'static>(
    theme: Theme,
    eyebrow: impl Into<String>,
    title: impl Into<String>,
    subtitle: Option<String>,
    on_back: impl Fn(&mut State) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    panel(
        theme,
        row((
            secondary_button("Back", theme, on_back),
            column((
                eyebrow_text(eyebrow, theme),
                label(title.into())
                    .text_size(22.0)
                    .weight(FontWeight::BOLD)
                    .color(theme.text_primary),
                subtitle.map(|subtitle| caption_text(subtitle, theme)),
            ))
            .gap(4.0.px())
            .flex(1.0),
        ))
        .gap(12.0.px()),
    )
}

pub(super) fn body_text<State: 'static, Action: 'static>(
    text: impl Into<String>,
    theme: Theme,
) -> impl WidgetView<State, Action> {
    prose_text(text, 15.0, theme)
}

pub(super) fn prose_text<State: 'static, Action: 'static>(
    text: impl Into<String>,
    text_size: f32,
    theme: Theme,
) -> impl WidgetView<State, Action> {
    prose(text.into())
        .text_size(text_size)
        .text_color(theme.text_primary)
}

pub(super) fn caption_text<State: 'static, Action: 'static>(
    text: impl Into<String>,
    theme: Theme,
) -> impl WidgetView<State, Action> {
    label(text.into()).text_size(12.0).color(theme.text_muted)
}

pub(super) fn primary_button<State: 'static>(
    label_text: impl Into<String>,
    theme: Theme,
    on_press: impl Fn(&mut State) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    primary_button_state(label_text, theme, ActionButtonState::Enabled, on_press)
}

pub(super) fn primary_button_state<State: 'static>(
    label_text: impl Into<String>,
    theme: Theme,
    state: ActionButtonState,
    on_press: impl Fn(&mut State) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    let disabled = state != ActionButtonState::Enabled;
    let foreground = if disabled {
        theme.text_muted
    } else {
        theme.background
    };
    let background = if disabled {
        theme.surface_raised
    } else {
        theme.accent
    };

    button(
        label(label_text.into())
            .text_size(14.0)
            .weight(FontWeight::SEMI_BOLD)
            .color(foreground),
        on_press,
    )
    .disabled(disabled)
    .background_color(background)
    .padding(Padding::horizontal(14.0))
    .corner_radius(6.0)
}

pub(super) fn secondary_button<State: 'static>(
    label_text: impl Into<String>,
    theme: Theme,
    on_press: impl Fn(&mut State) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    secondary_button_state(label_text, theme, ActionButtonState::Enabled, on_press)
}

pub(super) fn secondary_button_state<State: 'static>(
    label_text: impl Into<String>,
    theme: Theme,
    state: ActionButtonState,
    on_press: impl Fn(&mut State) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    let disabled = state != ActionButtonState::Enabled;
    let foreground = if disabled {
        theme.text_muted
    } else {
        theme.text_primary
    };
    let background = if disabled {
        theme.surface
    } else {
        theme.surface_raised
    };
    let border = if disabled {
        theme.surface_raised
    } else {
        theme.border
    };

    button(
        label(label_text.into())
            .text_size(14.0)
            .weight(FontWeight::SEMI_BOLD)
            .color(foreground),
        on_press,
    )
    .disabled(disabled)
    .background_color(background)
    .border(border, 1.0)
    .padding(Padding::horizontal(14.0))
    .corner_radius(6.0)
}

pub(super) fn status_chip<State: 'static, Action: 'static>(
    text: impl Into<String>,
    tone: Tone,
    theme: Theme,
) -> impl WidgetView<State, Action> {
    let (background, foreground) = tone_colors(tone, theme);
    sized_box(
        label(text.into())
            .text_size(12.0)
            .weight(FontWeight::SEMI_BOLD)
            .color(foreground),
    )
    .background_color(background)
    .padding(Padding::horizontal(10.0))
    .corner_radius(999.0)
}

pub(super) fn text_field<State: 'static>(
    value: impl Into<String>,
    placeholder: impl Into<String>,
    theme: Theme,
    on_change: impl Fn(&mut State, String) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    sized_box(
        text_input(value.into(), on_change)
            .placeholder(placeholder.into())
            .text_color(theme.text_primary)
            .placeholder_color(theme.text_muted),
    )
    .background_color(theme.surface_raised)
    .border(theme.border, 1.0)
    .padding(12.0)
    .corner_radius(6.0)
}

pub(super) fn multiline_editor<State: 'static>(
    value: impl Into<String>,
    placeholder: impl Into<String>,
    min_height: f64,
    theme: Theme,
    on_change: impl Fn(&mut State, String) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    sized_box(
        text_input(value.into(), on_change)
            .insert_newline(InsertNewline::OnEnter)
            .clip(false)
            .placeholder(placeholder.into())
            .text_color(theme.text_primary)
            .placeholder_color(theme.text_muted),
    )
    .height(min_height.px())
    .background_color(theme.surface_raised)
    .border(theme.border, 1.0)
    .padding(12.0)
    .corner_radius(6.0)
}

pub(super) fn selectable_card<State: 'static>(
    theme: Theme,
    is_selected: bool,
    body: impl WidgetView<State>,
    on_press: impl Fn(&mut State) + Send + Sync + 'static,
) -> impl WidgetView<State> {
    let background = if is_selected {
        theme.surface_raised
    } else {
        theme.surface
    };
    let border = if is_selected {
        theme.accent
    } else {
        theme.border
    };

    button(body, on_press)
        .background_color(background)
        .border(border, 1.0)
        .padding(14.0)
        .corner_radius(6.0)
}

fn sheet<State: 'static, Action: 'static>(
    theme: Theme,
    body: impl WidgetView<State, Action>,
) -> impl WidgetView<State, Action> {
    sized_box(body)
        .padding(18.0)
        .background_color(theme.surface_raised)
        .border(theme.border, 1.0)
        .corner_radius(14.0)
}

pub(super) fn with_sheet<State: 'static, Action: 'static>(
    body: impl WidgetView<State, Action>,
    theme: Theme,
    sheet_content: Option<Box<AnyWidgetView<State, Action>>>,
) -> Box<AnyWidgetView<State, Action>> {
    match sheet_content {
        Some(sheet_content) => zstack((
            body.boxed(),
            sized_box(
                column((
                    FlexSpacer::Flex(1.0),
                    sized_box(sheet(theme, sheet_content))
                        .padding(Padding::horizontal(6.0))
                        .padding(Padding::bottom(6.0)),
                ))
                .cross_axis_alignment(CrossAxisAlignment::Fill),
            )
            .expand()
            .background_color(theme.background.multiply_alpha(0.78))
            .alignment(UnitPoint::BOTTOM),
        ))
        .boxed(),
        None => body.boxed(),
    }
}

pub fn with_blocking_task<State, Job, Output>(
    content: impl WidgetView<State>,
    job: Option<Job>,
    run: impl Fn(Job) -> Result<Output, String> + Clone + Send + Sync + 'static,
    apply: impl Fn(&mut State, Job, Result<Output, String>) + Clone + Send + Sync + 'static,
) -> impl WidgetView<State>
where
    State: Send + Sync + 'static,
    Job: Clone + Send + Sync + 'static,
    Output: Debug + Send + 'static,
{
    fork(
        content,
        job.map(move |job| {
            let task_job = job.clone();
            let apply_job = job.clone();
            let run_fn = run.clone();
            let apply_fn = apply.clone();
            task_raw(
                move |proxy| {
                    let job = task_job.clone();
                    let run = run_fn.clone();
                    async move {
                        let result = tokio::task::spawn_blocking(move || run(job))
                            .await
                            .map_err(|error| {
                                format!("shadow ui background task join error: {error}")
                            })
                            .and_then(|value| value);
                        drop(proxy.message(result));
                    }
                },
                move |state: &mut State, result: Result<Output, String>| {
                    apply_fn(state, apply_job.clone(), result);
                },
            )
        }),
    )
}

pub fn with_task<State, Job, Output>(
    content: impl WidgetView<State>,
    task: Option<TaskHandle<Job>>,
    run: impl Fn(Job) -> Result<Output, String> + Clone + Send + Sync + 'static,
    apply: impl Fn(&mut State, TaskHandle<Job>, Result<Output, String>) + Clone + Send + Sync + 'static,
) -> impl WidgetView<State>
where
    State: Send + Sync + 'static,
    Job: Clone + Send + Sync + 'static,
    Output: Debug + Send + 'static,
{
    with_blocking_task(
        content,
        task,
        move |task: TaskHandle<Job>| run(task.into_job()),
        apply,
    )
}

pub fn task_decoration<State, Job, Output>(
    task: Option<TaskHandle<Job>>,
    run: impl Fn(Job) -> Result<Output, String> + Clone + Send + Sync + 'static,
    apply: impl Fn(&mut State, TaskHandle<Job>, Result<Output, String>) + Clone + Send + Sync + 'static,
) -> TaskDecoration<State>
where
    State: Send + Sync + 'static,
    Job: Clone + Send + Sync + 'static,
    Output: Debug + Send + 'static,
{
    TaskDecoration::new(move |content| with_task(content, task, run, apply).boxed())
}

pub fn with_tasks<State>(
    content: impl WidgetView<State>,
    decorations: impl IntoIterator<Item = TaskDecoration<State>>,
) -> Box<AnyWidgetView<State>>
where
    State: Send + Sync + 'static,
{
    apply_task_decorations(content, decorations)
}

fn tone_colors(tone: Tone, theme: Theme) -> (Color, Color) {
    match tone {
        Tone::Neutral => (theme.surface_raised, theme.text_muted),
        Tone::Accent => (theme.accent_soft, theme.text_primary),
        Tone::Success => (theme.success.multiply_alpha(0.25), theme.success),
        Tone::Danger => (theme.danger.multiply_alpha(0.22), theme.danger),
    }
}
