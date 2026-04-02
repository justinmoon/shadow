use blitz_dom::{DocGuard, DocGuardMut, Document};
use blitz_html::HtmlDocument;

use crate::frame::template_document;

const STYLE_SELECTOR: &str = "#shadow-blitz-style";
const ROOT_SELECTOR: &str = "#shadow-blitz-root";

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimeDocumentPayload {
    pub html: String,
    pub css: Option<String>,
}

pub struct RuntimeDocument {
    inner: HtmlDocument,
    payload: RuntimeDocumentPayload,
    frame_nodes: FrameNodes,
}

impl RuntimeDocument {
    pub fn new(payload: RuntimeDocumentPayload) -> Self {
        let inner = template_document();
        let frame_nodes = FrameNodes::resolve(&inner);
        let mut document = Self {
            inner,
            payload,
            frame_nodes,
        };
        document.apply_render();
        document
    }

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
