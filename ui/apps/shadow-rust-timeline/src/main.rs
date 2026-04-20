use std::collections::BTreeMap;
use std::env;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;
use shadow_sdk::{
    app::{
        current_lifecycle_state, spawn_lifecycle_listener, AppWindowDefaults, AppWindowEnvironment,
        AppWindowMetrics,
    },
    services::clipboard::write_text as write_clipboard_text,
    services::nostr::{
        current_account, generate_account, get_event, get_replaceable, import_account_nsec, query,
        sync, NostrAccountSource, NostrAccountSummary, NostrEvent, NostrQuery,
        NostrReplaceableQuery, NostrSyncReceipt, NostrSyncRequest, NOSTR_SERVICE_SOCKET_ENV,
    },
    ui::{
        self, body_text, caption_text, column, eyebrow_text, headline_text, maybe,
        multiline_editor, panel, primary_button, primary_button_state, prose_text, row, screen,
        secondary_button, secondary_button_state, selectable_card, status_chip, text_field,
        top_bar, top_bar_with_back, with_blocking_task, with_sheet, ActionButtonState, AsUnit,
        FlexExt, MainAxisAlignment, Theme, Tone, WidgetView,
    },
};

const WINDOW_DEFAULTS: AppWindowDefaults<'static> =
    ui::phone_window_defaults("Shadow Rust Timeline")
        .with_wayland_app_id("dev.shadow.rust-timeline")
        .with_wayland_instance_name("rust-timeline");

const RELAY_URLS_ENV: &str = "SHADOW_RUST_TIMELINE_RELAY_URLS";
const LIMIT_ENV: &str = "SHADOW_RUST_TIMELINE_LIMIT";
const SYNC_ON_START_ENV: &str = "SHADOW_RUST_TIMELINE_SYNC_ON_START";
const APP_LOG_PREFIX: &str = "shadow-rust-timeline";

#[derive(Clone, Debug)]
struct TimelineConfig {
    limit: usize,
    relay_urls: Vec<String>,
    sync_on_start: bool,
}

#[derive(Clone, Debug)]
struct TimelineStatus {
    tone: Tone,
    message: String,
}

#[derive(Clone, Copy, Debug)]
enum RefreshSource {
    Startup,
    Manual,
}

#[derive(Clone, Debug)]
struct PendingRefresh {
    token: u64,
    limit: usize,
    relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
struct PendingThreadSync {
    token: u64,
    note_id: String,
    parent_ids: Vec<String>,
    relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
enum AccountActionKind {
    Generate,
    Import { nsec: String },
}

#[derive(Clone, Debug)]
struct PendingAccountAction {
    kind: AccountActionKind,
    token: u64,
}

#[derive(Clone, Debug)]
struct PendingClipboardWrite {
    text: String,
    token: u64,
}

#[derive(Debug)]
struct RefreshOutcome {
    receipt: NostrSyncReceipt,
    notes: Vec<NostrEvent>,
}

#[derive(Debug)]
struct ThreadSyncOutcome {
    fetched_count: usize,
    imported_count: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Route {
    Account,
    Onboarding,
    Timeline,
    Note { id: String },
    Profile { pubkey: String },
}

#[derive(Clone, Debug)]
struct ActiveAccount {
    npub: String,
    source: AccountSource,
}

#[derive(Clone, Copy, Debug)]
enum AccountSource {
    Generated,
    Imported,
    Env,
}

impl AccountSource {
    fn label(self) -> &'static str {
        match self {
            Self::Generated => "generated on device",
            Self::Imported => "imported from nsec",
            Self::Env => "provided by environment",
        }
    }
}

impl From<NostrAccountSource> for AccountSource {
    fn from(value: NostrAccountSource) -> Self {
        match value {
            NostrAccountSource::Generated => Self::Generated,
            NostrAccountSource::Imported => Self::Imported,
            NostrAccountSource::Env => Self::Env,
        }
    }
}

impl From<NostrAccountSummary> for ActiveAccount {
    fn from(value: NostrAccountSummary) -> Self {
        Self {
            npub: value.npub,
            source: value.source.into(),
        }
    }
}

#[derive(Clone, Debug, Default)]
struct ProfileSummary {
    about: Option<String>,
    display_name: Option<String>,
    metadata_event_id: Option<String>,
    nip05: Option<String>,
}

impl ProfileSummary {
    fn title(&self, pubkey: &str) -> String {
        self.display_name
            .clone()
            .unwrap_or_else(|| short_id(pubkey))
    }

    fn metadata_status(&self) -> (&'static str, Tone) {
        if self.metadata_event_id.is_some() {
            ("metadata cached", Tone::Success)
        } else {
            ("no metadata yet", Tone::Neutral)
        }
    }
}

#[derive(Clone, Debug, Default)]
struct ThreadContext {
    parent: Option<NostrEvent>,
    replies: Vec<NostrEvent>,
}

#[derive(Clone, Debug)]
struct ReplyDraft {
    note_id: String,
    content: String,
}

#[derive(Clone, Debug)]
struct TimelineApp {
    account: Option<ActiveAccount>,
    config: TimelineConfig,
    filter_text: String,
    metrics: AppWindowMetrics,
    nsec_input: String,
    pending_account_action: Option<PendingAccountAction>,
    pending_clipboard_write: Option<PendingClipboardWrite>,
    notes: Vec<NostrEvent>,
    pending_refresh: Option<PendingRefresh>,
    pending_thread_sync: Option<PendingThreadSync>,
    profiles: BTreeMap<String, ProfileSummary>,
    reply_draft: Option<ReplyDraft>,
    route_stack: Vec<Route>,
    status: TimelineStatus,
    next_refresh_token: u64,
}

impl TimelineApp {
    fn new(window_env: AppWindowEnvironment, config: TimelineConfig) -> Self {
        let account_result = current_account().map(|account| account.map(ActiveAccount::from));
        let metrics = window_env.metrics();
        let (notes, status) = match load_cached_notes(config.limit) {
            Ok(notes) if notes.is_empty() => (
                Vec::new(),
                TimelineStatus {
                    tone: Tone::Neutral,
                    message: String::from("No cached notes yet. Refresh to pull from relays."),
                },
            ),
            Ok(notes) => {
                let count = notes.len();
                (
                    notes,
                    TimelineStatus {
                        tone: Tone::Success,
                        message: format!(
                            "Loaded {count} cached note{} from the shared store.",
                            plural_suffix(count)
                        ),
                    },
                )
            }
            Err(error) => (
                Vec::new(),
                TimelineStatus {
                    tone: Tone::Danger,
                    message: error,
                },
            ),
        };
        let (account, route_stack, status) = match account_result {
            Ok(Some(account)) => (Some(account), vec![Route::Timeline], status),
            Ok(None) => (
                None,
                vec![Route::Onboarding],
                TimelineStatus {
                    tone: Tone::Neutral,
                    message: String::from(
                        "No active Nostr account yet. Import an nsec or generate one to start.",
                    ),
                },
            ),
            Err(error) => (
                None,
                vec![Route::Onboarding],
                TimelineStatus {
                    tone: Tone::Danger,
                    message: format!("Could not load the active account: {error}"),
                },
            ),
        };
        let mut app = Self {
            account,
            config,
            filter_text: String::new(),
            metrics,
            nsec_input: String::new(),
            pending_account_action: None,
            pending_clipboard_write: None,
            notes,
            pending_refresh: None,
            pending_thread_sync: None,
            profiles: BTreeMap::new(),
            reply_draft: None,
            route_stack,
            status,
            next_refresh_token: 1,
        };
        if app.account.is_some() && app.config.sync_on_start && socket_available() {
            app.begin_refresh(RefreshSource::Startup);
        }
        app
    }

    fn begin_refresh(&mut self, source: RefreshSource) {
        if self.account.is_none() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Set up an account before refreshing the timeline."),
            };
            return;
        }
        if self.pending_refresh.is_some() {
            return;
        }
        let token = self.next_token();
        self.pending_refresh = Some(PendingRefresh {
            token,
            limit: self.config.limit,
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: match source {
                RefreshSource::Startup => String::from("Refreshing timeline from relays..."),
                RefreshSource::Manual => String::from("Talking to relays for fresh notes..."),
            },
        };
    }

    fn begin_account_generate(&mut self) {
        if self.pending_account_action.is_some() {
            return;
        }
        self.pending_account_action = Some(PendingAccountAction {
            kind: AccountActionKind::Generate,
            token: self.next_token(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Generating a new Nostr account..."),
        };
    }

    fn begin_account_import(&mut self) {
        if self.pending_account_action.is_some() {
            return;
        }
        let nsec = self.nsec_input.trim();
        if nsec.is_empty() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Paste an nsec before trying to import."),
            };
            return;
        }
        self.pending_account_action = Some(PendingAccountAction {
            kind: AccountActionKind::Import {
                nsec: nsec.to_owned(),
            },
            token: self.next_token(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Importing the Nostr account from nsec..."),
        };
    }

    fn begin_thread_sync(&mut self, note_id: String) {
        if self.pending_thread_sync.is_some() {
            return;
        }
        let Some(note) = self.cached_note_by_id(&note_id) else {
            return;
        };
        let token = self.next_token();
        self.pending_thread_sync = Some(PendingThreadSync {
            token,
            note_id,
            parent_ids: thread_parent_ids(&note),
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Pulling thread context from relays..."),
        };
    }

    fn begin_copy_account_npub(&mut self) {
        if self.pending_clipboard_write.is_some() {
            return;
        }
        let Some(account) = self.account.as_ref() else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("No active account is available to copy."),
            };
            return;
        };
        self.pending_clipboard_write = Some(PendingClipboardWrite {
            text: account.npub.clone(),
            token: self.next_token(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Copying the active npub to the clipboard..."),
        };
    }

    fn open_reply_composer(&mut self, note_id: String) {
        let Some(note) = self.cached_note_by_id(&note_id) else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("That note is no longer available for drafting a reply."),
            };
            return;
        };
        self.reply_draft = Some(ReplyDraft {
            note_id: note.id,
            content: String::new(),
        });
        self.status = TimelineStatus {
            tone: Tone::Neutral,
            message: String::from(
                "Compose the reply draft here. Publish will use the OS signer once that seam lands.",
            ),
        };
    }

    fn close_reply_composer(&mut self) {
        self.reply_draft = None;
    }

    fn set_reply_draft_content(&mut self, value: String) {
        if let Some(draft) = self.reply_draft.as_mut() {
            draft.content = value;
        }
    }

    fn next_token(&mut self) -> u64 {
        let token = self.next_refresh_token;
        self.next_refresh_token += 1;
        token
    }

    fn finish_refresh(&mut self, token: u64, result: Result<RefreshOutcome, String>) {
        let Some(pending) = &self.pending_refresh else {
            return;
        };
        if pending.token != token {
            return;
        }
        self.pending_refresh = None;

        match result {
            Ok(outcome) => {
                self.notes = outcome.notes;
                self.profiles.clear();
                self.sync_routes();
                self.status = if self.notes.is_empty() {
                    TimelineStatus {
                        tone: Tone::Neutral,
                        message: String::from(
                            "No relay notes yet. The shared cache is still empty.",
                        ),
                    }
                } else {
                    TimelineStatus {
                        tone: Tone::Success,
                        message: format!(
                            "Fetched {} note{}, imported {}.",
                            outcome.receipt.fetched_count,
                            plural_suffix(outcome.receipt.fetched_count),
                            outcome.receipt.imported_count,
                        ),
                    }
                };
            }
            Err(message) => {
                eprintln!("{APP_LOG_PREFIX}: refresh_error={message}");
                self.status = if self.notes.is_empty() {
                    TimelineStatus {
                        tone: Tone::Danger,
                        message,
                    }
                } else {
                    let count = self.notes.len();
                    TimelineStatus {
                        tone: Tone::Neutral,
                        message: format!(
                            "Relay refresh failed; showing {count} cached note{}.",
                            plural_suffix(count)
                        ),
                    }
                };
            }
        }
    }

    fn finish_thread_sync(&mut self, token: u64, result: Result<ThreadSyncOutcome, String>) {
        let Some(pending) = &self.pending_thread_sync else {
            return;
        };
        if pending.token != token {
            return;
        }
        self.pending_thread_sync = None;

        match result {
            Ok(outcome) => {
                self.sync_routes();
                self.status = TimelineStatus {
                    tone: if outcome.imported_count > 0 {
                        Tone::Success
                    } else {
                        Tone::Neutral
                    },
                    message: format!(
                        "Thread sync fetched {} event{}, imported {}.",
                        outcome.fetched_count,
                        plural_suffix(outcome.fetched_count),
                        outcome.imported_count,
                    ),
                };
            }
            Err(message) => {
                self.status = TimelineStatus {
                    tone: Tone::Danger,
                    message,
                };
            }
        }
    }

    fn finish_account_action(&mut self, token: u64, result: Result<ActiveAccount, String>) {
        let Some(pending) = &self.pending_account_action else {
            return;
        };
        if pending.token != token {
            return;
        }
        self.pending_account_action = None;

        match result {
            Ok(account) => {
                let message = format!(
                    "Account ready: {} ({})",
                    short_id(&account.npub),
                    account.source.label()
                );
                self.account = Some(account);
                self.nsec_input.clear();
                self.route_stack = vec![Route::Timeline];
                self.status = TimelineStatus {
                    tone: Tone::Success,
                    message,
                };
                if self.config.sync_on_start && socket_available() {
                    self.begin_refresh(RefreshSource::Startup);
                }
            }
            Err(message) => {
                self.status = TimelineStatus {
                    tone: Tone::Danger,
                    message,
                };
            }
        }
    }

    fn finish_clipboard_write(&mut self, token: u64, result: Result<(), String>) {
        let Some(pending) = &self.pending_clipboard_write else {
            return;
        };
        if pending.token != token {
            return;
        }
        self.pending_clipboard_write = None;

        self.status = match result {
            Ok(()) => TimelineStatus {
                tone: Tone::Success,
                message: String::from("Copied the active npub to the clipboard."),
            },
            Err(message) => TimelineStatus {
                tone: Tone::Danger,
                message,
            },
        };
    }

    fn current_route(&self) -> Route {
        self.route_stack.last().cloned().unwrap_or(Route::Timeline)
    }

    fn push_route(&mut self, route: Route) {
        if self.route_stack.last() == Some(&route) {
            return;
        }
        self.reply_draft = None;
        self.route_stack.push(route);
    }

    fn pop_route(&mut self) {
        self.reply_draft = None;
        if self.route_stack.len() > 1 {
            self.route_stack.pop();
        }
    }

    fn open_note(&mut self, id: String) {
        self.push_route(Route::Note { id });
    }

    fn open_profile(&mut self, pubkey: String) {
        self.ensure_profile_loaded(&pubkey);
        self.push_route(Route::Profile { pubkey });
    }

    fn open_account(&mut self) {
        if self.account.is_some() {
            self.push_route(Route::Account);
        }
    }

    fn sync_routes(&mut self) {
        if self.account.is_none() {
            self.route_stack = vec![Route::Onboarding];
            return;
        }
        loop {
            let should_pop = match self.current_route() {
                Route::Note { ref id } => self.cached_note_by_id(id).is_none(),
                _ => false,
            };
            if !should_pop || self.route_stack.len() == 1 {
                break;
            }
            self.route_stack.pop();
        }

        let route = self.current_route();
        self.prepare_route(&route);
        if self.reply_draft.as_ref().is_some_and(|draft| match route {
            Route::Note { ref id } => {
                draft.note_id != *id || self.cached_note_by_id(&draft.note_id).is_none()
            }
            _ => true,
        }) {
            self.reply_draft = None;
        }
    }

    fn prepare_route(&mut self, route: &Route) {
        match route {
            Route::Account | Route::Onboarding | Route::Timeline => {}
            Route::Note { id } => {
                if let Some(note) = self.cached_note_by_id(id) {
                    self.ensure_profile_loaded(&note.pubkey);
                }
            }
            Route::Profile { pubkey } => self.ensure_profile_loaded(pubkey),
        }
    }

    fn ensure_profile_loaded(&mut self, pubkey: &str) {
        if self.profiles.contains_key(pubkey) {
            return;
        }
        self.profiles
            .insert(pubkey.to_owned(), load_profile_summary(pubkey));
    }

    fn visible_notes(&self) -> Vec<NostrEvent> {
        let query_text = self.filter_text.trim().to_lowercase();
        self.notes
            .iter()
            .filter(|note| {
                query_text.is_empty()
                    || note.content.to_lowercase().contains(&query_text)
                    || note.pubkey.to_lowercase().contains(&query_text)
                    || note.id.to_lowercase().contains(&query_text)
            })
            .cloned()
            .collect()
    }

    fn note_by_id(&self, id: &str) -> Option<NostrEvent> {
        self.notes.iter().find(|note| note.id == id).cloned()
    }

    fn cached_note_by_id(&self, id: &str) -> Option<NostrEvent> {
        self.note_by_id(id).or_else(|| get_event(id).ok().flatten())
    }

    fn profile_notes(&self, pubkey: &str) -> Vec<NostrEvent> {
        query(NostrQuery {
            ids: None,
            authors: Some(vec![pubkey.to_owned()]),
            kinds: Some(vec![1]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(self.config.limit.max(24)),
        })
        .unwrap_or_else(|_| {
            self.notes
                .iter()
                .filter(|note| note.pubkey == pubkey)
                .cloned()
                .collect()
        })
    }

    fn profile_summary(&self, pubkey: &str) -> ProfileSummary {
        self.profiles.get(pubkey).cloned().unwrap_or_default()
    }

    fn reply_draft_for(&self, note_id: &str) -> Option<ReplyDraft> {
        self.reply_draft
            .as_ref()
            .filter(|draft| draft.note_id == note_id)
            .cloned()
    }
}

fn main() -> Result<(), ui::EventLoopError> {
    let window_env = AppWindowEnvironment::from_env(WINDOW_DEFAULTS);
    log_window_metrics(window_env.metrics());
    log_lifecycle_state(current_lifecycle_state().as_str());
    let _lifecycle_listener = spawn_lifecycle_listener(|state| {
        log_lifecycle_state(state.as_str());
    });
    let app = TimelineApp::new(window_env.clone(), TimelineConfig::from_env());
    ui::run_with_env(app, app_logic, window_env)
}

fn app_logic(app: &mut TimelineApp) -> impl WidgetView<TimelineApp> {
    let pending_account_action = app.pending_account_action.clone();
    let pending_clipboard_write = app.pending_clipboard_write.clone();
    let pending_refresh = app.pending_refresh.clone();
    let pending_thread_sync = app.pending_thread_sync.clone();
    let theme = Theme::shadow_dark();
    let route = app.current_route();
    app.prepare_route(&route);

    let body = match route {
        Route::Account => account_screen(
            theme,
            app.account.clone(),
            app.status.clone(),
            pending_clipboard_write.is_some(),
        )
        .boxed(),
        Route::Onboarding => onboarding_screen(
            theme,
            app.nsec_input.clone(),
            app.status.clone(),
            pending_account_action.is_some(),
        )
        .boxed(),
        Route::Timeline => timeline_screen(
            theme,
            app.account.clone(),
            app.status.clone(),
            app.visible_notes(),
            app.filter_text.clone(),
        )
        .boxed(),
        Route::Note { id } => {
            let note = app.cached_note_by_id(&id);
            let profile = note
                .as_ref()
                .map(|note| app.profile_summary(&note.pubkey))
                .unwrap_or_default();
            let thread = note.as_ref().map(load_thread_context).unwrap_or_default();
            let thread_sync_pending = pending_thread_sync
                .as_ref()
                .is_some_and(|job| job.note_id == id);
            note_screen(
                theme,
                note,
                profile,
                thread,
                app.reply_draft_for(&id),
                app.status.clone(),
                socket_available(),
                thread_sync_pending,
            )
            .boxed()
        }
        Route::Profile { pubkey } => profile_screen(
            theme,
            pubkey.clone(),
            app.profile_summary(&pubkey),
            app.profile_notes(&pubkey),
            app.status.clone(),
        )
        .boxed(),
    };

    let content = screen(app.metrics, theme, body);
    let content = with_blocking_task(
        content,
        pending_account_action,
        run_account_action,
        |app: &mut TimelineApp,
         job: PendingAccountAction,
         result: Result<ActiveAccount, String>| {
            app.finish_account_action(job.token, result);
        },
    );
    let content = with_blocking_task(
        content,
        pending_clipboard_write,
        run_clipboard_write,
        |app: &mut TimelineApp, job: PendingClipboardWrite, result: Result<(), String>| {
            app.finish_clipboard_write(job.token, result);
        },
    );
    let content = with_blocking_task(
        content,
        pending_thread_sync,
        sync_thread_context,
        |app: &mut TimelineApp,
         job: PendingThreadSync,
         result: Result<ThreadSyncOutcome, String>| {
            app.finish_thread_sync(job.token, result);
        },
    );

    with_blocking_task(
        content,
        pending_refresh,
        sync_notes,
        |app: &mut TimelineApp, job: PendingRefresh, result: Result<RefreshOutcome, String>| {
            app.finish_refresh(job.token, result);
        },
    )
}

fn timeline_screen(
    theme: Theme,
    account: Option<ActiveAccount>,
    status: TimelineStatus,
    notes: Vec<NostrEvent>,
    filter_text: String,
) -> impl WidgetView<TimelineApp> {
    let note_count = notes.len();

    column((
        top_bar(
            theme,
            "Shadow Nostr",
            "Timeline",
            Some(String::from(
                "Read-first native client over the shared cache and relay engine.",
            )),
        ),
        controls_section(theme, account, &status, note_count, filter_text),
        feed_section(
            theme,
            "Feed",
            "Nothing matches the current filter or cache state.",
            notes,
        ),
    ))
    .gap(12.0.px())
}

fn controls_section(
    theme: Theme,
    account: Option<ActiveAccount>,
    status: &TimelineStatus,
    note_count: usize,
    filter_text: String,
) -> impl WidgetView<TimelineApp> {
    panel(
        theme,
        column((
            row((
                text_field(
                    filter_text,
                    "Filter notes, authors, ids",
                    theme,
                    |app: &mut TimelineApp, value| {
                        app.filter_text = value;
                    },
                )
                .flex(1.0),
                primary_button("Refresh", theme, |app: &mut TimelineApp| {
                    app.begin_refresh(RefreshSource::Manual);
                }),
                maybe(
                    account.map(|_| {
                        secondary_button("Account", theme, |app: &mut TimelineApp| {
                            app.open_account();
                        })
                    }),
                    column(()),
                ),
                secondary_button("Clear", theme, |app: &mut TimelineApp| {
                    app.filter_text.clear();
                }),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            row((
                status_chip(status.message.clone(), status.tone, theme),
                caption_text(
                    format!("{note_count} note{} visible", plural_suffix(note_count)),
                    theme,
                ),
            ))
            .gap(10.0.px()),
        ))
        .gap(12.0.px()),
    )
}

fn onboarding_screen(
    theme: Theme,
    nsec_input: String,
    status: TimelineStatus,
    action_pending: bool,
) -> impl WidgetView<TimelineApp> {
    column((
        top_bar(
            theme,
            "Shadow Nostr",
            "Set up account",
            Some(String::from("Import an nsec or create a new key.")),
        ),
        panel(
            theme,
            column((
                eyebrow_text("First run", theme),
                body_text(
                    "Shadow needs one active Nostr account before it can sync a real timeline.",
                    theme,
                ),
                text_field(
                    nsec_input,
                    "Paste nsec to import",
                    theme,
                    |app: &mut TimelineApp, value| {
                        app.nsec_input = value;
                    },
                ),
                column((
                    primary_button("Import nsec", theme, |app: &mut TimelineApp| {
                        app.begin_account_import();
                    }),
                    secondary_button("Generate new", theme, |app: &mut TimelineApp| {
                        app.begin_account_generate();
                    }),
                ))
                .gap(10.0.px())
                .main_axis_alignment(MainAxisAlignment::Start),
                column((
                    status_chip(status.message, status.tone, theme),
                    caption_text(
                        if action_pending {
                            "Waiting for the shared Nostr service..."
                        } else {
                            "Stored in the shared Nostr service once created."
                        },
                        theme,
                    ),
                ))
                .gap(8.0.px()),
            ))
            .gap(12.0.px()),
        ),
    ))
    .gap(12.0.px())
}

fn account_screen(
    theme: Theme,
    account: Option<ActiveAccount>,
    status: TimelineStatus,
    clipboard_pending: bool,
) -> impl WidgetView<TimelineApp> {
    match account {
        Some(account) => column((
            top_bar_with_back(
                theme,
                "Shadow Nostr",
                "Account",
                Some(String::from("Active account for this device.")),
                TimelineApp::pop_route,
            ),
            panel(
                theme,
                column((
                    eyebrow_text("Identity", theme),
                    headline_text("Active account", theme),
                    status_chip(account.source.label(), Tone::Neutral, theme),
                    caption_text("npub", theme),
                    prose_text(account.npub, 15.0, theme),
                    secondary_button(
                        if clipboard_pending {
                            "Copying npub..."
                        } else {
                            "Copy npub"
                        },
                        theme,
                        |app: &mut TimelineApp| {
                            app.begin_copy_account_npub();
                        },
                    ),
                    column((
                        status_chip(status.message, status.tone, theme),
                        caption_text(
                            "Use the clipboard to move this device identity into another app.",
                            theme,
                        ),
                        caption_text("This app does not offer publish controls yet.", theme),
                    ))
                    .gap(8.0.px()),
                ))
                .gap(10.0.px()),
            ),
        ))
        .gap(12.0.px())
        .boxed(),
        None => column((
            top_bar_with_back(
                theme,
                "Shadow Nostr",
                "Account",
                Some(String::from("No active account is available.")),
                TimelineApp::pop_route,
            ),
            panel(
                theme,
                column((
                    eyebrow_text("Unavailable", theme),
                    caption_text(
                        "Go back and import an nsec or generate an account first.",
                        theme,
                    ),
                ))
                .gap(6.0.px()),
            ),
        ))
        .gap(12.0.px())
        .boxed(),
    }
}

fn note_screen(
    theme: Theme,
    note: Option<NostrEvent>,
    profile: ProfileSummary,
    thread: ThreadContext,
    reply_draft: Option<ReplyDraft>,
    status: TimelineStatus,
    thread_sync_available: bool,
    thread_sync_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let body = match note {
        Some(note) => {
            let note_id = note.id.clone();
            let pubkey = note.pubkey.clone();
            let reply_note_id = note.id.clone();
            let parent = thread.parent.clone();
            let replies = thread.replies.clone();
            let composer = reply_draft
                .as_ref()
                .map(|draft| reply_sheet(theme, &note, draft.clone()));
            with_sheet(
                column((
                top_bar_with_back(
                    theme,
                    "Shadow Nostr",
                    "Thread",
                    Some(format!(
                        "{}  •  {}",
                        profile.title(&note.pubkey),
                        relative_time(note.created_at)
                    )),
                    TimelineApp::pop_route,
                ),
                panel(
                    theme,
                    column((
                        eyebrow_text("Status", theme),
                        caption_text(status.message.clone(), theme),
                        maybe(
                            thread_sync_available.then_some(if thread_sync_pending {
                                caption_text(
                                    "Talking to relays for missing thread context.",
                                    theme,
                                )
                                .boxed()
                            } else {
                                primary_button(
                                    "Fetch thread",
                                    theme,
                                    move |app: &mut TimelineApp| {
                                        app.begin_thread_sync(note_id.clone());
                                    },
                                )
                                .boxed()
                            }),
                            caption_text(
                                "Thread fetch is available when the shared Nostr engine is running.",
                                theme,
                            ),
                        ),
                    ))
                    .gap(8.0.px()),
                ),
                maybe(
                    parent.map(|parent| {
                        let parent_id = parent.id.clone();
                        panel(
                            theme,
                            column((
                                eyebrow_text("Replying to", theme),
                                caption_text(
                                    format!(
                                        "{}  •  {}",
                                        short_id(&parent.pubkey),
                                        relative_time(parent.created_at)
                                    ),
                                    theme,
                                ),
                                prose_text(parent.content, 15.0, theme),
                                secondary_button(
                                    "Open parent",
                                    theme,
                                    move |app: &mut TimelineApp| {
                                        app.open_note(parent_id.clone());
                                    },
                                ),
                            ))
                            .gap(8.0.px()),
                        )
                    }),
                    panel(
                        theme,
                        column((
                            eyebrow_text("Reply chain", theme),
                            caption_text("No cached parent note for this entry yet.", theme),
                        ))
                        .gap(6.0.px()),
                    ),
                ),
                panel(
                    theme,
                    column((
                        eyebrow_text("Selected note", theme),
                        headline_text(profile.title(&note.pubkey), theme),
                        caption_text(short_id(&note.pubkey), theme),
                        prose_text(note.content, 17.0, theme),
                        caption_text(format!("event {}", short_id(&note.id)), theme),
                        row((
                            status_chip(relative_time(note.created_at), Tone::Neutral, theme),
                            note.root_event_id.clone().map(|root_id| {
                                caption_text(format!("root {}", short_id(&root_id)), theme)
                            }),
                        ))
                        .gap(8.0.px()),
                        secondary_button_state(
                            if reply_draft.is_some() {
                                "Reply draft open"
                            } else {
                                "Reply"
                            },
                            theme,
                            if reply_draft.is_some() {
                                ActionButtonState::Disabled
                            } else {
                                ActionButtonState::Enabled
                            },
                            move |app: &mut TimelineApp| {
                                app.open_reply_composer(reply_note_id.clone());
                            },
                        ),
                        secondary_button("Open profile", theme, move |app: &mut TimelineApp| {
                            app.open_profile(pubkey.clone());
                        }),
                    ))
                    .gap(10.0.px()),
                ),
                feed_section(theme, "Replies", "No cached direct replies yet.", replies),
                ))
                .gap(12.0.px()),
                theme,
                composer.map(|view| view.boxed()),
            )
        }
        None => column((
            top_bar_with_back(
                theme,
                "Shadow Nostr",
                "Note",
                Some(String::from("This note is no longer in the shared cache.")),
                TimelineApp::pop_route,
            ),
            panel(
                theme,
                column((
                    eyebrow_text("Unavailable", theme),
                    caption_text(
                        "Refresh the timeline or go back to pick another note.",
                        theme,
                    ),
                ))
                .gap(6.0.px()),
            ),
        ))
        .gap(12.0.px())
        .boxed(),
    };

    body
}

fn reply_sheet(theme: Theme, note: &NostrEvent, draft: ReplyDraft) -> impl WidgetView<TimelineApp> {
    let note_id = draft.note_id.clone();
    let note_preview = note.content.lines().next().unwrap_or("").trim();
    let note_preview = if note_preview.is_empty() {
        String::from("Write the first reply to this note.")
    } else {
        note_preview.to_owned()
    };

    column((
        eyebrow_text("Reply draft", theme),
        headline_text("Compose reply", theme),
        caption_text(
            format!("Replying to {}  •  {}", short_id(&note.pubkey), short_id(&note_id)),
            theme,
        ),
        body_text(note_preview, theme),
        multiline_editor(
            draft.content,
            "Write a reply for the shared Nostr signer to publish later.",
            148.0,
            theme,
            |app: &mut TimelineApp, value| {
                app.set_reply_draft_content(value);
            },
        ),
        row((
            secondary_button("Close", theme, |app: &mut TimelineApp| {
                app.close_reply_composer();
            }),
            primary_button_state("Post reply", theme, ActionButtonState::Disabled, |_| {}),
        ))
        .gap(10.0.px())
        .main_axis_alignment(MainAxisAlignment::Start),
        caption_text(
            "This slice stops at drafting. The OS-owned signer and publish approval flow land next.",
            theme,
        ),
    ))
    .gap(10.0.px())
}

fn profile_screen(
    theme: Theme,
    pubkey: String,
    profile: ProfileSummary,
    notes: Vec<NostrEvent>,
    status: TimelineStatus,
) -> impl WidgetView<TimelineApp> {
    let metadata_status = profile.metadata_status();
    let note_count = notes.len();

    column((
        top_bar_with_back(
            theme,
            "Shadow Nostr",
            profile.title(&pubkey),
            Some(short_id(&pubkey)),
            TimelineApp::pop_route,
        ),
        panel(
            theme,
            column((
                eyebrow_text("Identity", theme),
                headline_text(profile.title(&pubkey), theme),
                caption_text(short_id(&pubkey), theme),
                profile
                    .nip05
                    .clone()
                    .map(|nip05| caption_text(nip05, theme)),
                profile.about.clone().map(|about| body_text(about, theme)),
                row((
                    status_chip(metadata_status.0, metadata_status.1, theme),
                    status_chip(status.message, status.tone, theme),
                    caption_text(
                        format!("{note_count} note{} cached", plural_suffix(note_count)),
                        theme,
                    ),
                ))
                .gap(10.0.px()),
                primary_button("Refresh", theme, |app: &mut TimelineApp| {
                    app.begin_refresh(RefreshSource::Manual);
                }),
            ))
            .gap(10.0.px()),
        ),
        feed_section(
            theme,
            "Recent notes",
            "This author has no cached kind-1 notes yet.",
            notes,
        ),
    ))
    .gap(12.0.px())
}

fn feed_section(
    theme: Theme,
    title: &str,
    empty_message: &str,
    notes: Vec<NostrEvent>,
) -> impl WidgetView<TimelineApp> {
    let title = title.to_owned();
    let empty_message = empty_message.to_owned();
    let body = maybe(
        (!notes.is_empty()).then_some(
            column(
                notes
                    .into_iter()
                    .map(|note| note_card(theme, note))
                    .collect::<Vec<_>>(),
            )
            .gap(10.0.px()),
        ),
        panel(
            theme,
            column((
                eyebrow_text(title.clone(), theme),
                caption_text(empty_message, theme),
            ))
            .gap(6.0.px()),
        ),
    );

    column((eyebrow_text(title, theme), body)).gap(8.0.px())
}

fn note_card(theme: Theme, note: NostrEvent) -> impl WidgetView<TimelineApp> {
    let note_id = note.id.clone();

    selectable_card(
        theme,
        false,
        column((
            row((
                caption_text(short_id(&note.pubkey), theme),
                status_chip(relative_time(note.created_at), Tone::Neutral, theme),
            ))
            .gap(8.0.px()),
            prose_text(note.content, 15.0, theme),
        ))
        .gap(8.0.px()),
        move |app: &mut TimelineApp| {
            app.open_note(note_id.clone());
        },
    )
}

fn run_account_action(job: PendingAccountAction) -> Result<ActiveAccount, String> {
    match job.kind {
        AccountActionKind::Generate => generate_account()
            .map(ActiveAccount::from)
            .map_err(|error| error.to_string()),
        AccountActionKind::Import { nsec } => import_account_nsec(nsec)
            .map(ActiveAccount::from)
            .map_err(|error| error.to_string()),
    }
}

fn run_clipboard_write(job: PendingClipboardWrite) -> Result<(), String> {
    write_clipboard_text(job.text).map_err(|error| error.to_string())
}

fn sync_notes(job: PendingRefresh) -> Result<RefreshOutcome, String> {
    let receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: None,
            kinds: Some(vec![0, 1]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(job.limit),
        },
        relay_urls: (!job.relay_urls.is_empty()).then_some(job.relay_urls.clone()),
        timeout_ms: Some(8_000),
    })
    .map_err(|error| error.to_string())?;
    let notes = load_cached_notes(job.limit)?;

    Ok(RefreshOutcome { receipt, notes })
}

fn load_cached_notes(limit: usize) -> Result<Vec<NostrEvent>, String> {
    query(NostrQuery {
        ids: None,
        authors: None,
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit),
    })
    .map_err(|error| error.to_string())
}

fn load_profile_summary(pubkey: &str) -> ProfileSummary {
    let Ok(Some(event)) = get_replaceable(NostrReplaceableQuery {
        kind: 0,
        pubkey: pubkey.to_owned(),
        identifier: None,
    }) else {
        return ProfileSummary::default();
    };

    let Ok(metadata) = serde_json::from_str::<Value>(&event.content) else {
        return ProfileSummary {
            metadata_event_id: Some(event.id),
            ..ProfileSummary::default()
        };
    };

    ProfileSummary {
        about: metadata
            .get("about")
            .and_then(Value::as_str)
            .map(str::to_owned),
        display_name: metadata
            .get("display_name")
            .and_then(Value::as_str)
            .or_else(|| metadata.get("displayName").and_then(Value::as_str))
            .or_else(|| metadata.get("name").and_then(Value::as_str))
            .map(str::to_owned),
        metadata_event_id: Some(event.id),
        nip05: metadata
            .get("nip05")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}

fn sync_thread_context(job: PendingThreadSync) -> Result<ThreadSyncOutcome, String> {
    let mut fetched_count = 0_usize;
    let mut imported_count = 0_usize;
    let relay_urls = (!job.relay_urls.is_empty()).then_some(job.relay_urls.clone());

    if !job.parent_ids.is_empty() {
        let receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: Some(job.parent_ids.clone()),
                authors: None,
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(job.parent_ids.len()),
            },
            relay_urls: relay_urls.clone(),
            timeout_ms: Some(8_000),
        })
        .map_err(|error| error.to_string())?;
        fetched_count += receipt.fetched_count;
        imported_count += receipt.imported_count;
    }

    let receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: None,
            kinds: Some(vec![1]),
            referenced_ids: Some(vec![job.note_id.clone()]),
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(48),
        },
        relay_urls,
        timeout_ms: Some(8_000),
    })
    .map_err(|error| error.to_string())?;
    fetched_count += receipt.fetched_count;
    imported_count += receipt.imported_count;

    Ok(ThreadSyncOutcome {
        fetched_count,
        imported_count,
    })
}

fn load_thread_context(note: &NostrEvent) -> ThreadContext {
    let parent = note
        .reply_to_event_id
        .as_ref()
        .and_then(|reply_to_id| get_event(reply_to_id).ok().flatten());
    let replies = query(NostrQuery {
        ids: None,
        authors: None,
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: Some(vec![note.id.clone()]),
        since: None,
        until: None,
        limit: Some(24),
    })
    .unwrap_or_default();

    ThreadContext { parent, replies }
}

fn thread_parent_ids(note: &NostrEvent) -> Vec<String> {
    let mut parent_ids = Vec::new();
    if let Some(reply_to_event_id) = note.reply_to_event_id.as_ref() {
        parent_ids.push(reply_to_event_id.clone());
    }
    if let Some(root_event_id) = note.root_event_id.as_ref() {
        if !parent_ids.iter().any(|id| id == root_event_id) {
            parent_ids.push(root_event_id.clone());
        }
    }
    parent_ids
}

fn socket_available() -> bool {
    env::var(NOSTR_SERVICE_SOCKET_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .is_some_and(|value| !value.is_empty())
}

impl TimelineConfig {
    fn from_env() -> Self {
        Self {
            limit: env::var(LIMIT_ENV)
                .ok()
                .and_then(|value| value.trim().parse::<usize>().ok())
                .filter(|value| *value > 0)
                .unwrap_or(18),
            relay_urls: env::var(RELAY_URLS_ENV)
                .ok()
                .map(|value| {
                    value
                        .split(',')
                        .map(str::trim)
                        .filter(|value| !value.is_empty())
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
                .filter(|urls| !urls.is_empty())
                .unwrap_or_else(|| {
                    vec![
                        String::from("wss://relay.primal.net/"),
                        String::from("wss://relay.damus.io/"),
                    ]
                }),
            sync_on_start: env::var(SYNC_ON_START_ENV)
                .ok()
                .map(|value| !matches!(value.trim(), "0" | "false" | "False"))
                .unwrap_or(true),
        }
    }
}

fn short_id(value: &str) -> String {
    if value.len() <= 18 {
        return value.to_owned();
    }
    format!("{}…{}", &value[..8], &value[value.len() - 8..])
}

fn relative_time(created_at: u64) -> String {
    let Ok(duration) = SystemTime::now().duration_since(UNIX_EPOCH) else {
        return created_at.to_string();
    };
    let delta = duration.as_secs().saturating_sub(created_at);
    if delta < 60 {
        return format!("{delta}s");
    }
    if delta < 60 * 60 {
        return format!("{}m", delta / 60);
    }
    if delta < 60 * 60 * 24 {
        return format!("{}h", delta / (60 * 60));
    }
    format!("{}d", delta / (60 * 60 * 24))
}

fn plural_suffix(count: usize) -> &'static str {
    if count == 1 {
        ""
    } else {
        "s"
    }
}

fn log_window_metrics(metrics: AppWindowMetrics) {
    eprintln!(
        "{APP_LOG_PREFIX}: window_metrics surface={}x{} safe_area=l{} t{} r{} b{}",
        metrics.surface_width,
        metrics.surface_height,
        metrics.safe_area_insets.left,
        metrics.safe_area_insets.top,
        metrics.safe_area_insets.right,
        metrics.safe_area_insets.bottom,
    );
}

fn log_lifecycle_state(state: &str) {
    eprintln!("{APP_LOG_PREFIX}: lifecycle_state={state}");
}
