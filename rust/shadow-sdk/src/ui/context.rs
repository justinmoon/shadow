use xilem::{AnyWidgetView, WidgetView};

use crate::app::AppWindowMetrics;

use super::{theme::Theme, widgets, ActionButtonState, Tone};

#[derive(Clone, Copy, Debug)]
pub struct UiContext {
    metrics: AppWindowMetrics,
    theme: Theme,
}

impl UiContext {
    const fn new(metrics: AppWindowMetrics, theme: Theme) -> Self {
        Self { metrics, theme }
    }

    pub fn shadow_dark(metrics: AppWindowMetrics) -> Self {
        Self::new(metrics, Theme::shadow_dark())
    }

    pub const fn metrics(self) -> AppWindowMetrics {
        self.metrics
    }

    pub fn panel<State: 'static, Action: 'static>(
        self,
        body: impl WidgetView<State, Action>,
    ) -> impl WidgetView<State, Action> {
        widgets::panel(self.theme, body)
    }

    pub fn eyebrow_text<State: 'static, Action: 'static>(
        self,
        text: impl Into<String>,
    ) -> impl WidgetView<State, Action> {
        widgets::eyebrow_text(text, self.theme)
    }

    pub fn headline_text<State: 'static, Action: 'static>(
        self,
        text: impl Into<String>,
    ) -> impl WidgetView<State, Action> {
        widgets::headline_text(text, self.theme)
    }

    pub fn body_text<State: 'static, Action: 'static>(
        self,
        text: impl Into<String>,
    ) -> impl WidgetView<State, Action> {
        widgets::body_text(text, self.theme)
    }

    pub fn prose_text<State: 'static, Action: 'static>(
        self,
        text: impl Into<String>,
        text_size: f32,
    ) -> impl WidgetView<State, Action> {
        widgets::prose_text(text, text_size, self.theme)
    }

    pub fn caption_text<State: 'static, Action: 'static>(
        self,
        text: impl Into<String>,
    ) -> impl WidgetView<State, Action> {
        widgets::caption_text(text, self.theme)
    }

    pub fn top_bar<State: 'static, Action: 'static>(
        self,
        eyebrow: impl Into<String>,
        title: impl Into<String>,
        subtitle: Option<String>,
    ) -> impl WidgetView<State, Action> {
        widgets::top_bar(self.theme, eyebrow, title, subtitle)
    }

    pub fn top_bar_with_back<State: 'static>(
        self,
        eyebrow: impl Into<String>,
        title: impl Into<String>,
        subtitle: Option<String>,
        on_back: impl Fn(&mut State) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::top_bar_with_back(self.theme, eyebrow, title, subtitle, on_back)
    }

    pub fn primary_button<State: 'static>(
        self,
        label_text: impl Into<String>,
        on_press: impl Fn(&mut State) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::primary_button(label_text, self.theme, on_press)
    }

    pub fn primary_button_state<State: 'static>(
        self,
        label_text: impl Into<String>,
        state: ActionButtonState,
        on_press: impl Fn(&mut State) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::primary_button_state(label_text, self.theme, state, on_press)
    }

    pub fn secondary_button<State: 'static>(
        self,
        label_text: impl Into<String>,
        on_press: impl Fn(&mut State) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::secondary_button(label_text, self.theme, on_press)
    }

    pub fn secondary_button_state<State: 'static>(
        self,
        label_text: impl Into<String>,
        state: ActionButtonState,
        on_press: impl Fn(&mut State) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::secondary_button_state(label_text, self.theme, state, on_press)
    }

    pub fn status_chip<State: 'static, Action: 'static>(
        self,
        text: impl Into<String>,
        tone: Tone,
    ) -> impl WidgetView<State, Action> {
        widgets::status_chip(text, tone, self.theme)
    }

    pub fn text_field<State: 'static>(
        self,
        value: impl Into<String>,
        placeholder: impl Into<String>,
        on_change: impl Fn(&mut State, String) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::text_field(value, placeholder, self.theme, on_change)
    }

    pub fn multiline_editor<State: 'static>(
        self,
        value: impl Into<String>,
        placeholder: impl Into<String>,
        min_height: f64,
        on_change: impl Fn(&mut State, String) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::multiline_editor(value, placeholder, min_height, self.theme, on_change)
    }

    pub fn selectable_card<State: 'static>(
        self,
        is_selected: bool,
        body: impl WidgetView<State>,
        on_press: impl Fn(&mut State) + Send + Sync + 'static,
    ) -> impl WidgetView<State> {
        widgets::selectable_card(self.theme, is_selected, body, on_press)
    }

    pub fn with_sheet<State: 'static, Action: 'static>(
        self,
        body: impl WidgetView<State, Action>,
        sheet_content: Option<Box<AnyWidgetView<State, Action>>>,
    ) -> Box<AnyWidgetView<State, Action>> {
        widgets::with_sheet(body, self.theme, sheet_content)
    }

    pub fn screen<State: Send + Sync + 'static, Action: Send + Sync + 'static>(
        self,
        body: impl WidgetView<State, Action>,
    ) -> impl WidgetView<State, Action> {
        widgets::screen(self.metrics, self.theme, body)
    }
}
