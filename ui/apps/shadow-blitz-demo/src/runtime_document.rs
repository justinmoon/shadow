use std::{
    env,
    sync::mpsc::{channel, Receiver, Sender},
    task::{Context, Waker},
    thread,
    time::Duration,
};

use blitz_dom::{DocGuard, DocGuardMut, Document};
use blitz_html::HtmlDocument;

use crate::frame::template_document;

const STYLE_SELECTOR: &str = "#shadow-blitz-style";
const ROOT_SELECTOR: &str = "#shadow-blitz-root";
const SAMPLE_RUNTIME_HTML: &str = r#"
<section class="runtime-card">
  <p class="runtime-eyebrow">Shadow Runtime</p>
  <h1>First Host Frame</h1>
  <p class="runtime-lede">
    Solid-style TSX rendered on the host and handed into a persistent Blitz frame.
  </p>
  <button class="runtime-action" data-shadow-id="counter">Count 1</button>
</section>
"#;
const SAMPLE_RUNTIME_CSS: &str = r#"
:root {
  color-scheme: dark;
  --bg0: #06131a;
  --bg1: #0e2430;
  --card: rgba(9, 19, 28, 0.88);
  --border: rgba(120, 196, 255, 0.28);
  --text: #f3fbff;
  --muted: #bfd5df;
  --accent: #79d4ff;
  --accent-strong: #2fb8ff;
}
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; }
body {
  min-height: 100vh;
  background:
    radial-gradient(circle at top, rgba(47, 184, 255, 0.18), transparent 34%),
    linear-gradient(180deg, var(--bg0), var(--bg1));
  color: var(--text);
  font: 500 16px/1.5 system-ui, sans-serif;
}
#shadow-blitz-root {
  min-height: 100vh;
  display: grid;
  place-items: center;
  padding: 24px;
}
.runtime-card {
  width: min(100%, 320px);
  padding: 24px;
  border: 1px solid var(--border);
  border-radius: 28px;
  background: var(--card);
  box-shadow: 0 24px 72px rgba(0, 0, 0, 0.35);
}
.runtime-eyebrow {
  margin: 0 0 10px;
  text-transform: uppercase;
  letter-spacing: 0.18em;
  color: var(--accent);
  font-size: 12px;
}
.runtime-card h1 {
  margin: 0;
  font-size: 38px;
  line-height: 0.96;
  letter-spacing: -0.05em;
}
.runtime-lede {
  margin: 14px 0 24px;
  color: var(--muted);
}
.runtime-action {
  border: none;
  border-radius: 999px;
  padding: 13px 18px;
  background: linear-gradient(135deg, var(--accent), var(--accent-strong));
  color: #04212d;
  font: inherit;
  font-weight: 700;
}
"#;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimeDocumentPayload {
    pub html: String,
    pub css: Option<String>,
}

pub struct RuntimeDocument {
    inner: HtmlDocument,
    payload: RuntimeDocumentPayload,
    frame_nodes: FrameNodes,
    should_exit: bool,
    timer_started: bool,
    timer_tx: Sender<RuntimeTimerEvent>,
    timer_rx: Receiver<RuntimeTimerEvent>,
}

impl RuntimeDocument {
    pub fn new(payload: RuntimeDocumentPayload) -> Self {
        let (timer_tx, timer_rx) = channel();
        let inner = template_document();
        let frame_nodes = FrameNodes::resolve(&inner);
        let mut document = Self {
            inner,
            payload,
            frame_nodes,
            should_exit: false,
            timer_started: false,
            timer_tx,
            timer_rx,
        };
        document.apply_render();
        eprintln!("[shadow-runtime-demo] runtime-document-ready");
        document
    }

    pub fn sample_payload() -> RuntimeDocumentPayload {
        RuntimeDocumentPayload {
            html: String::from(SAMPLE_RUNTIME_HTML),
            css: Some(String::from(SAMPLE_RUNTIME_CSS)),
        }
    }

    pub fn should_exit(&self) -> bool {
        self.should_exit
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn replace_document(&mut self, payload: RuntimeDocumentPayload) {
        self.payload = payload;
        self.apply_render();
    }

    fn apply_render(&mut self) {
        let mut mutator = self.inner.mutate();
        mutator.set_inner_html(
            self.frame_nodes.style_id,
            self.payload.css.as_deref().unwrap_or(""),
        );
        mutator.set_inner_html(self.frame_nodes.root_id, &self.payload.html);
    }

    fn ensure_exit_timer_started(&mut self, task_context: Option<Context<'_>>) {
        let Some(task_context) = task_context else {
            return;
        };

        if self.timer_started {
            return;
        }

        self.timer_started = true;
        let Some(delay) = optional_duration_from_env("SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS") else {
            return;
        };

        spawn_timer(
            self.timer_tx.clone(),
            task_context.waker().clone(),
            delay,
            RuntimeTimerEvent::RequestExit,
        );
    }

    fn handle_timer_event(&mut self, event: RuntimeTimerEvent) -> bool {
        match event {
            RuntimeTimerEvent::RequestExit => {
                self.should_exit = true;
                eprintln!("[shadow-runtime-demo] exit-requested");
                false
            }
        }
    }

    #[cfg(test)]
    fn node_outer_html(&self, selector: &str) -> String {
        let node_id = self
            .inner
            .query_selector(selector)
            .expect("parse selector")
            .expect("matching node");
        self.inner
            .get_node(node_id)
            .expect("node by selector")
            .outer_html()
    }

    #[cfg(test)]
    fn node_text_content(&self, selector: &str) -> String {
        let node_id = self
            .inner
            .query_selector(selector)
            .expect("parse selector")
            .expect("matching node");
        self.inner
            .get_node(node_id)
            .expect("node by selector")
            .text_content()
    }
}

impl Document for RuntimeDocument {
    fn inner(&self) -> DocGuard<'_> {
        self.inner.inner()
    }

    fn inner_mut(&mut self) -> DocGuardMut<'_> {
        self.inner.inner_mut()
    }

    fn poll(&mut self, task_context: Option<std::task::Context<'_>>) -> bool {
        self.ensure_exit_timer_started(task_context);

        let mut changed = false;
        while let Ok(event) = self.timer_rx.try_recv() {
            changed |= self.handle_timer_event(event);
        }
        changed
    }
}

struct FrameNodes {
    style_id: usize,
    root_id: usize,
}

impl FrameNodes {
    fn resolve(document: &HtmlDocument) -> Self {
        let style_id = document
            .query_selector(STYLE_SELECTOR)
            .expect("parse style selector")
            .expect("style node");
        let root_id = document
            .query_selector(ROOT_SELECTOR)
            .expect("parse root selector")
            .expect("root node");
        Self { style_id, root_id }
    }
}

#[derive(Clone, Copy, Debug)]
enum RuntimeTimerEvent {
    RequestExit,
}

fn spawn_timer(
    timer_tx: Sender<RuntimeTimerEvent>,
    waker: Waker,
    delay: Duration,
    event: RuntimeTimerEvent,
) {
    thread::spawn(move || {
        thread::sleep(delay);
        let _ = timer_tx.send(event);
        waker.wake_by_ref();
    });
}

fn optional_duration_from_env(key: &str) -> Option<Duration> {
    let value = env::var(key).ok()?;
    if value.is_empty() {
        return None;
    }

    value.parse::<u64>().ok().map(Duration::from_millis)
}

#[cfg(test)]
mod tests {
    use super::{RuntimeDocument, RuntimeDocumentPayload};

    #[test]
    fn runtime_document_renders_initial_payload_into_fixed_frame() {
        let payload = RuntimeDocumentPayload {
            html: String::from(r#"<section class="screen"><h1>Hello</h1></section>"#),
            css: Some(String::from("body { color: red; }")),
        };
        let document = RuntimeDocument::new(payload.clone());

        assert_eq!(
            document.node_text_content("#shadow-blitz-style"),
            "body { color: red; }"
        );
        assert_eq!(
            document.node_outer_html("#shadow-blitz-root"),
            format!(r#"<main id="shadow-blitz-root">{}</main>"#, payload.html)
        );
    }

    #[test]
    fn runtime_document_replaces_style_and_root_content() {
        let mut document = RuntimeDocument::new(RuntimeDocumentPayload {
            html: String::from("<p>Before</p>"),
            css: Some(String::from("body { color: red; }")),
        });

        document.replace_document(RuntimeDocumentPayload {
            html: String::from(r#"<article data-app="next">After</article>"#),
            css: None,
        });

        assert_eq!(document.node_text_content("#shadow-blitz-style"), "");
        assert_eq!(
            document.node_outer_html("#shadow-blitz-root"),
            r#"<main id="shadow-blitz-root"><article data-app="next">After</article></main>"#
        );
    }
}
