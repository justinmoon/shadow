use std::{
    env,
    sync::{
        mpsc::{channel, Receiver, Sender},
        Arc,
    },
    task::{Context, Waker},
    thread,
    time::Duration,
};

use blitz_dom::{DocGuard, DocGuardMut, Document, DocumentConfig};
use blitz_html::{HtmlDocument, HtmlProvider};
use blitz_traits::events::UiEvent;

const FRAME_HTML: &str = r#"
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Shadow Blitz Demo</title>
    <style id="shadow-blitz-style"></style>
  </head>
  <body>
    <main id="shadow-blitz-root"></main>
  </body>
</html>
"#;

pub struct StaticDocument {
    inner: HtmlDocument,
    phase: DemoPhase,
    should_exit: bool,
    last_waker: Option<Waker>,
    timer_started: bool,
    static_only: bool,
    timer_tx: Sender<TimerEvent>,
    timer_rx: Receiver<TimerEvent>,
}

impl StaticDocument {
    pub fn new() -> Self {
        let (timer_tx, timer_rx) = channel();
        let static_only = env::var_os("SHADOW_BLITZ_STATIC_ONLY").is_some();
        let mut document = Self {
            inner: template_document(),
            phase: DemoPhase::Static,
            should_exit: false,
            last_waker: None,
            timer_started: false,
            static_only,
            timer_tx,
            timer_rx,
        };
        document.apply_render();
        eprintln!("[shadow-blitz-demo] static-document-ready");
        if static_only {
            eprintln!("[shadow-blitz-demo] static-only-mode");
        }
        document
    }

    pub fn should_exit(&self) -> bool {
        self.should_exit
    }

    fn apply_render(&mut self) {
        let style_id = self
            .inner
            .query_selector("#shadow-blitz-style")
            .expect("parse style selector")
            .expect("style node");
        let root_id = self
            .inner
            .query_selector("#shadow-blitz-root")
            .expect("parse root selector")
            .expect("root node");

        let mut mutator = self.inner.mutate();
        mutator.set_inner_html(style_id, self.phase.css());
        mutator.set_inner_html(root_id, self.phase.html());
    }

    fn ensure_timer_started(&mut self, task_context: Option<Context<'_>>) {
        let Some(task_context) = task_context else {
            return;
        };

        self.last_waker = Some(task_context.waker().clone());

        if self.timer_started {
            return;
        }

        self.timer_started = true;
        if self.static_only {
            if let Some(delay) = optional_duration_from_env("SHADOW_BLITZ_EXIT_DELAY_MS") {
                spawn_timer(
                    self.timer_tx.clone(),
                    task_context.waker().clone(),
                    delay,
                    TimerEvent::RequestExit,
                );
            }
            return;
        }

        spawn_dynamic_timer(self.timer_tx.clone(), task_context.waker().clone());
    }

    fn handle_timer_event(&mut self, event: TimerEvent) -> bool {
        match event {
            TimerEvent::AdvanceToDynamic if self.phase == DemoPhase::Static => {
                self.phase = DemoPhase::Dynamic;
                self.apply_render();
                eprintln!("[shadow-blitz-demo] dynamic-document-ready");
                if let Some(waker) = self.last_waker.clone() {
                    spawn_exit_timer(self.timer_tx.clone(), waker);
                }
                true
            }
            TimerEvent::RequestExit => {
                self.should_exit = true;
                eprintln!("[shadow-blitz-demo] exit-requested");
                false
            }
            _ => false,
        }
    }
}

impl Document for StaticDocument {
    fn inner(&self) -> DocGuard<'_> {
        self.inner.inner()
    }

    fn inner_mut(&mut self) -> DocGuardMut<'_> {
        self.inner.inner_mut()
    }

    fn handle_ui_event(&mut self, _event: UiEvent) {}

    fn poll(&mut self, task_context: Option<std::task::Context<'_>>) -> bool {
        self.ensure_timer_started(task_context);

        let mut changed = false;
        while let Ok(event) = self.timer_rx.try_recv() {
            changed |= self.handle_timer_event(event);
        }
        changed
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DemoPhase {
    Static,
    Dynamic,
}

impl DemoPhase {
    fn css(self) -> &'static str {
        match self {
            Self::Static => static_css(),
            Self::Dynamic => dynamic_css(),
        }
    }

    fn html(self) -> &'static str {
        match self {
            Self::Static => static_html(),
            Self::Dynamic => dynamic_html(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
enum TimerEvent {
    AdvanceToDynamic,
    RequestExit,
}

fn spawn_dynamic_timer(timer_tx: Sender<TimerEvent>, waker: Waker) {
    let delay = duration_from_env("SHADOW_BLITZ_DYNAMIC_DELAY_MS", 900);
    spawn_timer(timer_tx, waker, delay, TimerEvent::AdvanceToDynamic);
}

fn spawn_exit_timer(timer_tx: Sender<TimerEvent>, waker: Waker) {
    let delay = duration_from_env("SHADOW_BLITZ_EXIT_DELAY_MS", 1400);
    spawn_timer(timer_tx, waker, delay, TimerEvent::RequestExit);
}

fn spawn_timer(timer_tx: Sender<TimerEvent>, waker: Waker, delay: Duration, event: TimerEvent) {
    thread::spawn(move || {
        thread::sleep(delay);
        let _ = timer_tx.send(event);
        waker.wake_by_ref();
    });
}

fn duration_from_env(key: &str, default_ms: u64) -> Duration {
    let millis = env::var(key)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(default_ms);
    Duration::from_millis(millis)
}

fn optional_duration_from_env(key: &str) -> Option<Duration> {
    let value = env::var(key).ok()?;
    if value.is_empty() {
        return None;
    }

    value.parse::<u64>().ok().map(Duration::from_millis)
}

fn template_document() -> HtmlDocument {
    HtmlDocument::from_html(
        FRAME_HTML,
        DocumentConfig {
            html_parser_provider: Some(Arc::new(HtmlProvider) as _),
            ..Default::default()
        },
    )
}

fn static_css() -> &'static str {
    r#"
:root {
  color-scheme: dark;
  --bg0: #050816;
  --bg1: #0e1630;
  --bg2: #141c2e;
  --card: rgba(10, 16, 28, 0.88);
  --border: rgba(125, 211, 252, 0.22);
  --text: #f8fafc;
  --muted: #cbd5e1;
  --accent: #7dd3fc;
  --accent-strong: #38bdf8;
  --glow: rgba(56, 189, 248, 0.24);
}
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; }
body {
  display: grid;
  place-items: center;
  padding: 24px;
  background:
    radial-gradient(circle at top, var(--glow), transparent 32%),
    linear-gradient(180deg, var(--bg0), var(--bg1) 50%, var(--bg2));
  color: var(--text);
  font: 500 16px/1.5 system-ui, sans-serif;
}
.frame {
  width: min(480px, 100%);
  padding: 26px;
  border-radius: 28px;
  border: 1px solid var(--border);
  background: var(--card);
  box-shadow: 0 24px 80px rgba(0, 0, 0, 0.38);
}
.eyebrow {
  margin: 0 0 10px;
  text-transform: uppercase;
  letter-spacing: 0.22em;
  color: var(--accent);
  font-size: 12px;
}
h1 {
  margin: 0;
  font-size: 42px;
  line-height: 0.96;
  letter-spacing: -0.06em;
}
.lede {
  margin: 14px 0 24px;
  color: var(--muted);
}
.status {
  margin: 0;
  font-size: 22px;
  line-height: 1.2;
}
.meta {
  margin: 12px 0 0;
  color: var(--muted);
}
.badge-row {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 20px;
}
.badge {
  padding: 8px 12px;
  border-radius: 999px;
  border: 1px solid rgba(125, 211, 252, 0.28);
  background: rgba(15, 23, 42, 0.78);
  color: var(--accent);
  font-size: 13px;
  letter-spacing: 0.02em;
}
"#
}

fn dynamic_css() -> &'static str {
    r#"
:root {
  color-scheme: light;
  --bg0: #fff3c4;
  --bg1: #ffd166;
  --bg2: #f97316;
  --card: rgba(255, 251, 235, 0.96);
  --border: rgba(124, 45, 18, 0.28);
  --text: #431407;
  --muted: #7c2d12;
  --accent: #c2410c;
}
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; }
body {
  display: grid;
  place-items: center;
  padding: 24px;
  background:
    radial-gradient(circle at top left, rgba(255, 255, 255, 0.5), transparent 28%),
    linear-gradient(180deg, var(--bg0), var(--bg1) 48%, var(--bg2));
  color: var(--text);
  font: 600 16px/1.5 system-ui, sans-serif;
}
.frame {
  width: min(480px, 100%);
  padding: 26px;
  border-radius: 28px;
  border: 1px solid var(--border);
  background: var(--card);
  box-shadow: 0 28px 70px rgba(124, 45, 18, 0.22);
}
.eyebrow {
  margin: 0 0 10px;
  text-transform: uppercase;
  letter-spacing: 0.22em;
  color: var(--accent);
  font-size: 12px;
}
h1 {
  margin: 0;
  font-size: 42px;
  line-height: 0.96;
  letter-spacing: -0.06em;
}
.lede {
  margin: 14px 0 24px;
  color: var(--muted);
}
.status {
  margin: 0;
  font-size: 22px;
  line-height: 1.2;
}
.meta {
  margin: 12px 0 0;
  color: var(--muted);
}
.badge-row {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 20px;
}
.badge {
  padding: 8px 12px;
  border-radius: 999px;
  border: 1px solid rgba(124, 45, 18, 0.22);
  background: rgba(255, 247, 237, 0.95);
  color: var(--accent);
  font-size: 13px;
  letter-spacing: 0.02em;
}
"#
}

fn static_html() -> &'static str {
    r#"
<section class="frame">
  <p class="eyebrow">Shadow demo</p>
  <h1>Blitz rendered.<br>Static first.</h1>
  <p class="lede">
    This is the first bring-up rung in this worktree: prove the existing rooted
    guest compositor can present a native Blitz document on the Pixel panel
    before adding click handling or a JS runtime seam.
  </p>
  <p class="status">Static HTML and CSS are live inside Blitz.</p>
  <p class="meta">Timer armed. The document will mutate in place on the next rung.</p>
</section>
"#
}

fn dynamic_html() -> &'static str {
    r#"
<section class="frame">
  <p class="eyebrow">Shadow demo</p>
  <h1>Dynamic update.<br>No JS yet.</h1>
  <p class="lede">
    The same rooted Pixel compositor path is now proving a native Blitz document
    can mutate after startup and present the new frame before the client exits.
  </p>
  <p class="status">Second-frame HTML landed on-device.</p>
  <div class="badge-row">
    <span class="badge">Static HTML</span>
    <span class="badge">Timed DOM mutation</span>
    <span class="badge">Clean client shutdown</span>
  </div>
  <p class="meta">Next step: real input and state changes, then Deno/runtime work.</p>
</section>
"#
}
