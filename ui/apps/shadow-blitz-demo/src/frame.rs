use std::{env, path::PathBuf, sync::Arc, time::Instant};

use blitz_dom::{DocumentConfig, FontContext};
use blitz_html::{HtmlDocument, HtmlProvider};

pub const FRAME_HTML: &str = r#"
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Shadow Counter</title>
    <style>
      html, body {
        margin: 0;
        height: 100%;
        width: 100%;
        background: #08121b;
      }

      body {
        overflow: hidden;
        font-family: "Google Sans", "Roboto", "Droid Sans", "Noto Sans", sans-serif;
      }

      #shadow-blitz-root {
        width: 100%;
        height: 100%;
        overflow: hidden;
        background: #08121b;
      }

      #shadow-blitz-debug {
        position: fixed;
        top: 16px;
        left: 16px;
        z-index: 2147483647;
        display: flex;
        gap: 8px;
        align-items: center;
        padding: 10px 12px;
        border-radius: 16px;
        background: rgba(4, 10, 16, 0.88);
        border: 1px solid rgba(255, 255, 255, 0.12);
        pointer-events: none;
      }

      #shadow-blitz-debug:empty {
        display: none;
      }

      .shadow-debug-lane {
        width: 22px;
        height: 14px;
        border-radius: 999px;
        opacity: 0.18;
        background: #243746;
        box-shadow: inset 0 1px 1px rgba(255, 255, 255, 0.08);
      }

      .shadow-debug-lane.is-on {
        opacity: 1;
      }

      .shadow-debug-lane.raw.is-on {
        background: #ff5d7a;
      }

      .shadow-debug-lane.signal.is-on {
        background: #ffe16b;
      }

      .shadow-debug-lane.ui.is-on {
        background: #62d9ff;
      }

      .shadow-debug-lane.hit.is-on {
        background: #97f766;
      }

      .shadow-debug-lane.click.is-on {
        background: #ffb15f;
      }
    </style>
    <style id="shadow-blitz-style"></style>
  </head>
  <body>
    <main id="shadow-blitz-root"></main>
    <aside id="shadow-blitz-debug"></aside>
  </body>
</html>
"#;

pub fn template_document() -> HtmlDocument {
    let start = Instant::now();
    let mut config = DocumentConfig {
        html_parser_provider: Some(Arc::new(HtmlProvider) as _),
        ..Default::default()
    };
    if let Some(font_ctx) = android_font_context() {
        config.font_ctx = Some(font_ctx);
    }

    let document = HtmlDocument::from_html(FRAME_HTML, config);
    eprintln!(
        "[shadow-blitz-demo] template-document-ready elapsed_ms={}",
        start.elapsed().as_millis()
    );
    document
}

fn android_font_context() -> Option<FontContext> {
    match android_font_loading_mode() {
        AndroidFontMode::Disabled => {
            eprintln!("[shadow-blitz-demo] android-font-loading disabled");
            None
        }
        AndroidFontMode::Curated => {
            let font_paths = android_curated_font_paths();
            if font_paths.is_empty() {
                eprintln!("[shadow-blitz-demo] curated-android-fonts missing");
                return None;
            }

            let start = Instant::now();
            let mut font_ctx = FontContext::new();
            font_ctx.collection.load_fonts_from_paths(&font_paths);
            eprintln!(
                "[shadow-blitz-demo] registered-curated-android-fonts count={} elapsed_ms={}",
                font_paths.len(),
                start.elapsed().as_millis()
            );
            Some(font_ctx)
        }
        AndroidFontMode::Scan => {
            let font_dirs = android_font_dirs();
            if font_dirs.is_empty() {
                return None;
            }

            let start = Instant::now();
            let mut font_ctx = FontContext::new();
            font_ctx.collection.load_fonts_from_paths(&font_dirs);
            eprintln!(
                "[shadow-blitz-demo] registered-android-font-dirs count={} elapsed_ms={}",
                font_dirs.len(),
                start.elapsed().as_millis()
            );
            Some(font_ctx)
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AndroidFontMode {
    Disabled,
    Curated,
    Scan,
}

fn android_font_loading_mode() -> AndroidFontMode {
    match env::var("SHADOW_BLITZ_ANDROID_FONTS")
        .ok()
        .as_deref()
        .map(str::trim)
    {
        Some("0") | Some("false") | Some("off") | Some("none") => AndroidFontMode::Disabled,
        Some("scan") | Some("system") | Some("all") => AndroidFontMode::Scan,
        Some("curated") | Some("1") | Some("true") | Some("on") | None => AndroidFontMode::Curated,
        Some(_) => AndroidFontMode::Curated,
    }
}

fn android_font_dirs() -> Vec<PathBuf> {
    const FONT_DIRS: &[&str] = &[
        "/product/fonts",
        "/system/fonts",
        "/system/product/fonts",
        "/vendor/fonts",
        "/odm/fonts",
    ];

    let mut font_dirs = Vec::new();
    for dir in FONT_DIRS {
        let path = PathBuf::from(dir);
        if path.is_dir() {
            font_dirs.push(path);
        }
    }

    font_dirs.sort();
    font_dirs
}

fn android_curated_font_paths() -> Vec<PathBuf> {
    const FONT_FILES: &[&str] = &[
        "/system/fonts/DroidSans.ttf",
        "/system/fonts/DroidSans-Bold.ttf",
        "/system/fonts/DroidSansMono.ttf",
        "/system/fonts/NotoColorEmoji.ttf",
    ];

    let mut font_paths = Vec::new();
    for font_file in FONT_FILES {
        let path = PathBuf::from(font_file);
        if path.is_file() {
            font_paths.push(path);
        }
    }

    font_paths
}
