use std::sync::Arc;

use blitz_dom::DocumentConfig;
use blitz_html::{HtmlDocument, HtmlProvider};

pub const FRAME_HTML: &str = r#"
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

pub fn template_document() -> HtmlDocument {
    HtmlDocument::from_html(
        FRAME_HTML,
        DocumentConfig {
            html_parser_provider: Some(Arc::new(HtmlProvider) as _),
            ..Default::default()
        },
    )
}
