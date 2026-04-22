use xilem::WidgetView;

use crate::app::AppWindowMetrics;

use super::{screen, Theme};

#[derive(Clone, Copy, Debug)]
pub struct UiContext {
    metrics: AppWindowMetrics,
    theme: Theme,
}

impl UiContext {
    pub const fn new(metrics: AppWindowMetrics, theme: Theme) -> Self {
        Self { metrics, theme }
    }

    pub fn shadow_dark(metrics: AppWindowMetrics) -> Self {
        Self::new(metrics, Theme::shadow_dark())
    }

    pub const fn metrics(self) -> AppWindowMetrics {
        self.metrics
    }

    pub const fn theme(self) -> Theme {
        self.theme
    }

    pub fn screen<State: Send + Sync + 'static, Action: Send + Sync + 'static>(
        self,
        body: impl WidgetView<State, Action>,
    ) -> impl WidgetView<State, Action> {
        screen(self.metrics, self.theme, body)
    }
}
