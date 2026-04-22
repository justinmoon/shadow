use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::future;
use std::time::{SystemTime, UNIX_EPOCH};

mod tasks;

use shadow_sdk::{
    app::{
        current_lifecycle_state, spawn_platform_request_listener, AppWindowDefaults,
        AppWindowEnvironment, AppWindowMetrics, LifecycleState,
    },
    services::nostr::{
        current_account, get_event,
        timeline::{
            load_explore_cache_state, load_home_cache_state_for_account,
            load_home_feed_scope_for_account, load_note_cache_state, load_profile_cache_state,
            NostrExploreCacheState, NostrExploreProfileEntry, NostrHomeFeedScope,
            NostrHomeFeedSource, NostrNoteCacheState, NostrProfileCacheState,
            NostrProfileSummary,
        },
        NostrAccountSource, NostrAccountSummary, NostrEvent, NOSTR_SERVICE_SOCKET_ENV,
    },
    ui::{
        self, body_text, caption_text, column, eyebrow_text, fork, headline_text, maybe,
        multiline_editor, panel, primary_button, primary_button_state, prose_text, row,
        secondary_button, secondary_button_state, selectable_card, status_chip, text_field, tokio,
        top_bar, top_bar_with_back, with_sheet, worker_raw, ActionButtonState, AsUnit, FlexExt,
        MainAxisAlignment, MessageProxy, Tone, UiContext, WidgetView,
    },
};
use tasks::{decorate_with_tasks, RefreshSource, TimelineTasks};

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

#[derive(Clone, Debug, PartialEq, Eq)]
struct FeedScope {
    authors: Option<Vec<String>>,
    source: FeedSource,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum FeedSource {
    Following { count: usize },
    NoContacts,
    Unavailable,
}

impl FeedScope {
    fn unavailable() -> Self {
        Self {
            authors: None,
            source: FeedSource::Unavailable,
        }
    }

    fn following(mut authors: Vec<String>, count: usize) -> Self {
        authors.sort();
        authors.dedup();
        Self {
            authors: Some(authors),
            source: FeedSource::Following { count },
        }
    }

    fn no_contacts() -> Self {
        Self {
            authors: None,
            source: FeedSource::NoContacts,
        }
    }

    fn chip_label(&self) -> String {
        match self.source {
            FeedSource::Following { count } => {
                format!("following {count} account{}", plural_suffix(count))
            }
            FeedSource::NoContacts => String::from("no follows"),
            FeedSource::Unavailable => String::from("feed unavailable"),
        }
    }

    fn detail_text(&self) -> String {
        match self.source {
            FeedSource::Following { count } => format!(
                "Home feed uses the cached contact list from the shared account and follows {count} account{}.",
                plural_suffix(count)
            ),
            FeedSource::NoContacts => {
                String::from("Home is empty until this account follows someone.")
            }
            FeedSource::Unavailable => String::from("No active account is available."),
        }
    }
}

impl From<NostrHomeFeedScope> for FeedScope {
    fn from(value: NostrHomeFeedScope) -> Self {
        match value.source {
            NostrHomeFeedSource::Following { count } => {
                Self::following(value.authors.unwrap_or_default(), count)
            }
            NostrHomeFeedSource::NoContacts => Self::no_contacts(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Route {
    Account,
    Explore,
    Onboarding,
    Timeline,
    Note { id: String },
    Profile { pubkey: String },
}

#[derive(Debug)]
enum PlatformMessage {
    Lifecycle(LifecycleState),
    OpenFirstVisibleNote,
    OpenReply,
    PublishReply,
    SetReplyContent(String),
    PublishReplyContent(String),
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

#[derive(Clone, Debug)]
struct ReplyDraft {
    note_id: String,
    content: String,
}

#[derive(Clone, Debug)]
struct TimelineApp {
    account: Option<ActiveAccount>,
    config: TimelineConfig,
    feed_scope: FeedScope,
    filter_text: String,
    follow_input: String,
    metrics: AppWindowMetrics,
    nsec_input: String,
    notes: Vec<NostrEvent>,
    explore_cache: Option<NostrExploreCacheState>,
    note_caches: BTreeMap<String, NostrNoteCacheState>,
    profile_caches: BTreeMap<String, NostrProfileCacheState>,
    reply_draft: Option<ReplyDraft>,
    route_stack: Vec<Route>,
    status: TimelineStatus,
    tasks: TimelineTasks,
}

impl TimelineApp {
    fn new(window_env: AppWindowEnvironment, config: TimelineConfig) -> Self {
        let account_result = current_account().map(|account| account.map(ActiveAccount::from));
        let metrics = window_env.metrics();
        let (account, route_stack, feed_scope, notes, status) = match account_result {
            Ok(Some(account)) => {
                match load_home_cache_state_for_account(&account.npub, config.limit)
                    .map_err(|error| error.to_string())
                {
                    Ok(cache) if cache.notes.is_empty() => {
                        let feed_scope = FeedScope::from(cache.feed_scope);
                        let status = empty_feed_status(&feed_scope);
                        (
                            Some(account),
                            vec![Route::Timeline],
                            feed_scope,
                            Vec::new(),
                            status,
                        )
                    }
                    Ok(cache) => {
                        let count = cache.notes.len();
                        let feed_scope = FeedScope::from(cache.feed_scope);
                        (
                            Some(account),
                            vec![Route::Timeline],
                            feed_scope,
                            cache.notes,
                            TimelineStatus {
                                tone: Tone::Success,
                                message: format!(
                                    "Loaded {count} cached note{} from the shared store.",
                                    plural_suffix(count)
                                ),
                            },
                        )
                    }
                    Err(error) => {
                        let feed_scope = load_home_feed_scope_for_account(&account.npub)
                            .map(FeedScope::from)
                            .unwrap_or_else(|_| FeedScope::no_contacts());
                        (
                            Some(account),
                            vec![Route::Timeline],
                            feed_scope,
                            Vec::new(),
                            TimelineStatus {
                                tone: Tone::Danger,
                                message: error,
                            },
                        )
                    }
                }
            }
            Ok(None) => (
                None,
                vec![Route::Onboarding],
                FeedScope::unavailable(),
                Vec::new(),
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
                FeedScope::unavailable(),
                Vec::new(),
                TimelineStatus {
                    tone: Tone::Danger,
                    message: format!("Could not load the active account: {error}"),
                },
            ),
        };
        let mut app = Self {
            account,
            config,
            feed_scope,
            explore_cache: None,
            filter_text: String::new(),
            follow_input: String::new(),
            metrics,
            nsec_input: String::new(),
            notes,
            note_caches: BTreeMap::new(),
            profile_caches: BTreeMap::new(),
            reply_draft: None,
            route_stack,
            status,
            tasks: TimelineTasks::default(),
        };
        if app.account.is_some() && app.config.sync_on_start && socket_available() {
            app.begin_refresh(RefreshSource::Startup);
        }
        app
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
            message: String::from("Compose the reply, then publish through the shared account."),
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

    fn current_followed_pubkeys(&self) -> Vec<String> {
        self.feed_scope.authors.clone().unwrap_or_default()
    }

    fn is_following(&self, pubkey: &str) -> bool {
        self.feed_scope
            .authors
            .as_ref()
            .is_some_and(|authors| authors.iter().any(|author| author == pubkey))
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
        self.push_route(Route::Profile { pubkey });
    }

    fn open_account(&mut self) {
        if self.account.is_some() {
            self.push_route(Route::Account);
        }
    }

    fn open_explore(&mut self) {
        if self.account.is_some() {
            self.push_route(Route::Explore);
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
            Route::Explore => self.ensure_explore_loaded(),
            Route::Note { id } => self.ensure_note_loaded(id),
            Route::Profile { pubkey } => self.ensure_profile_loaded(pubkey),
        }
    }

    fn platform_open_reply(&mut self) {
        match self.current_route() {
            Route::Note { id } => {
                self.open_reply_composer(id);
                if self.reply_draft.is_some() {
                    eprintln!("{APP_LOG_PREFIX}: automation_open_reply_success");
                } else {
                    eprintln!("{APP_LOG_PREFIX}: automation_open_reply_failed");
                }
            }
            _ => {
                eprintln!("{APP_LOG_PREFIX}: automation_open_reply_failed");
                self.status = TimelineStatus {
                    tone: Tone::Danger,
                    message: String::from("Open a note before opening the reply draft."),
                };
            }
        }
    }

    fn first_visible_note_id_for_route(&self) -> Option<String> {
        match self.current_route() {
            Route::Timeline => self.visible_notes().into_iter().next().map(|note| note.id),
            Route::Explore => self.explore_state().notes.into_iter().next().map(|note| note.id),
            Route::Profile { pubkey } => self.profile_state(&pubkey).notes.into_iter().next().map(|note| note.id),
            Route::Note { id } => Some(id),
            Route::Account | Route::Onboarding => None,
        }
    }

    fn platform_open_first_visible_note(&mut self) {
        let Some(note_id) = self.first_visible_note_id_for_route() else {
            eprintln!("{APP_LOG_PREFIX}: automation_open_first_visible_note_failed");
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("No visible note is available to open."),
            };
            return;
        };
        eprintln!("{APP_LOG_PREFIX}: automation_open_first_visible_note_success note_id={note_id}");
        self.push_route(Route::Note { id: note_id });
    }

    fn platform_set_reply_content(&mut self, value: String) {
        if self.reply_draft.is_none() {
            self.platform_open_reply();
        }
        self.set_reply_draft_content(value);
    }

    fn platform_publish_reply_content(&mut self, value: String) {
        if self.reply_draft.is_none() {
            self.platform_open_reply();
        }
        self.set_reply_draft_content(value);
        self.begin_reply_publish();
        if self.tasks.publish_pending() {
            eprintln!("{APP_LOG_PREFIX}: automation_publish_reply_success");
        } else {
            eprintln!("{APP_LOG_PREFIX}: automation_publish_reply_failed");
        }
    }

    fn ensure_explore_loaded(&mut self) {
        if self.explore_cache.is_some() {
            return;
        }
        self.explore_cache = load_explore_cache_state(self.config.limit.max(24)).ok();
    }

    fn ensure_profile_loaded(&mut self, pubkey: &str) {
        if self.profile_caches.contains_key(pubkey) {
            return;
        }
        if let Ok(cache) = load_profile_cache_state(pubkey, self.config.limit.max(24)) {
            self.profile_caches.insert(pubkey.to_owned(), cache);
        }
    }

    fn ensure_note_loaded(&mut self, note_id: &str) {
        if self.note_caches.contains_key(note_id) {
            return;
        }
        if let Ok(cache) = load_note_cache_state(note_id) {
            self.note_caches.insert(note_id.to_owned(), cache);
        }
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

    fn explore_state(&self) -> NostrExploreCacheState {
        self.explore_cache.clone().unwrap_or_default()
    }

    fn profile_state(&self, pubkey: &str) -> NostrProfileCacheState {
        self.profile_caches.get(pubkey).cloned().unwrap_or_else(|| {
            let notes = self
                .notes
                .iter()
                .filter(|note| note.pubkey == pubkey)
                .cloned()
                .collect();
            NostrProfileCacheState {
                summary: NostrProfileSummary::default(),
                notes,
            }
        })
    }

    fn note_state(&self, note_id: &str) -> NostrNoteCacheState {
        self.note_caches.get(note_id).cloned().unwrap_or_else(|| NostrNoteCacheState {
            note: self.cached_note_by_id(note_id),
            profile: NostrProfileSummary::default(),
            thread: shadow_sdk::services::nostr::timeline::NostrThreadContext::default(),
        })
    }

    fn reply_draft_for(&self, note_id: &str) -> Option<ReplyDraft> {
        self.reply_draft
            .as_ref()
            .filter(|draft| draft.note_id == note_id)
            .cloned()
    }

    fn reload_feed_from_cache(&mut self) -> Result<(), String> {
        let Some(account) = self.account.as_ref() else {
            self.feed_scope = FeedScope::unavailable();
            self.notes.clear();
            self.invalidate_route_caches();
            return Ok(());
        };
        let cache = load_home_cache_state_for_account(&account.npub, self.config.limit)
            .map_err(|error| error.to_string())?;
        self.feed_scope = FeedScope::from(cache.feed_scope);
        self.notes = cache.notes;
        self.invalidate_route_caches();
        Ok(())
    }

    fn invalidate_route_caches(&mut self) {
        self.explore_cache = None;
        self.note_caches.clear();
        self.profile_caches.clear();
    }
}

fn main() -> Result<(), ui::EventLoopError> {
    let window_env = AppWindowEnvironment::from_env(WINDOW_DEFAULTS);
    log_window_metrics(window_env.metrics());
    log_lifecycle_state(current_lifecycle_state().as_str());
    let app = TimelineApp::new(window_env.clone(), TimelineConfig::from_env());
    ui::run_with_env(app, app_logic, window_env)
}

fn app_logic(app: &mut TimelineApp) -> impl WidgetView<TimelineApp> {
    let task_snapshot = app.tasks.snapshot();
    let ui = UiContext::shadow_dark(app.metrics);
    let route = app.current_route();
    app.prepare_route(&route);

    let body = match route {
        Route::Account => account_screen(
            ui,
            app.account.clone(),
            app.feed_scope.clone(),
            app.follow_input.clone(),
            app.status.clone(),
            task_snapshot.clipboard_write_pending(),
            task_snapshot.follow_update_pending(),
            socket_available(),
        )
        .boxed(),
        Route::Explore => {
            let explore = app.explore_state();
            explore_screen(
                ui,
                app.account.clone(),
                app.current_followed_pubkeys(),
                app.status.clone(),
                explore.notes,
                explore.profiles,
                socket_available(),
                task_snapshot.explore_sync_pending(),
                task_snapshot.follow_update_pending(),
            )
            .boxed()
        }
        Route::Onboarding => onboarding_screen(
            ui,
            app.nsec_input.clone(),
            app.status.clone(),
            task_snapshot.account_action_pending(),
        )
        .boxed(),
        Route::Timeline => timeline_screen(
            ui,
            app.account.clone(),
            app.feed_scope.clone(),
            app.status.clone(),
            app.visible_notes(),
            app.filter_text.clone(),
        )
        .boxed(),
        Route::Note { id } => {
            let note_state = app.note_state(&id);
            note_screen(
                ui,
                note_state.note,
                note_state.profile,
                note_state.thread,
                app.reply_draft_for(&id),
                app.status.clone(),
                task_snapshot.publish_pending_for(&id),
                socket_available(),
                task_snapshot.thread_sync_pending_for(&id),
            )
            .boxed()
        }
        Route::Profile { pubkey } => {
            let profile_state = app.profile_state(&pubkey);
            profile_screen(
                ui,
                app.account.clone(),
                pubkey.clone(),
                profile_state.summary,
                profile_state.notes,
                app.status.clone(),
                app.is_following(&pubkey),
                app.follow_update_pending_for(&pubkey),
                socket_available(),
            )
            .boxed()
        }
    };

    let content = ui.screen(body);
    let content = decorate_with_tasks(content, task_snapshot);

    fork(
        content,
        worker_raw(
            |proxy, _rx: tokio::sync::mpsc::UnboundedReceiver<()>| async move {
                let _ = run_platform_listener(proxy);
                future::pending::<()>().await;
            },
            |_state: &mut TimelineApp, _sender: tokio::sync::mpsc::UnboundedSender<()>| {},
            |app: &mut TimelineApp, message: PlatformMessage| match message {
                PlatformMessage::Lifecycle(state) => log_lifecycle_state(state.as_str()),
                PlatformMessage::OpenFirstVisibleNote => app.platform_open_first_visible_note(),
                PlatformMessage::OpenReply => app.platform_open_reply(),
                PlatformMessage::PublishReply => app.begin_reply_publish(),
                PlatformMessage::SetReplyContent(value) => app.platform_set_reply_content(value),
                PlatformMessage::PublishReplyContent(value) => {
                    app.platform_publish_reply_content(value)
                }
            },
        ),
    )
}

fn timeline_screen(
    ui: UiContext,
    account: Option<ActiveAccount>,
    feed_scope: FeedScope,
    status: TimelineStatus,
    notes: Vec<NostrEvent>,
    filter_text: String,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let note_count = notes.len();

    column((
        top_bar(
            theme,
            "Shadow Nostr",
            "Timeline",
            Some(feed_scope.detail_text()),
        ),
        controls_section(
            ui,
            account,
            &feed_scope,
            &status,
            note_count,
            filter_text,
        ),
        feed_section(ui, "Feed", home_feed_empty_message(&feed_scope), notes),
    ))
    .gap(12.0.px())
}

fn controls_section(
    ui: UiContext,
    account: Option<ActiveAccount>,
    feed_scope: &FeedScope,
    status: &TimelineStatus,
    note_count: usize,
    filter_text: String,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
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
                secondary_button("Clear", theme, |app: &mut TimelineApp| {
                    app.filter_text.clear();
                }),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            row((
                primary_button("Refresh", theme, |app: &mut TimelineApp| {
                    app.begin_refresh(RefreshSource::Manual);
                }),
                maybe(
                    account.as_ref().map(|_| {
                        secondary_button("Account", theme, |app: &mut TimelineApp| {
                            app.open_account();
                        })
                    }),
                    column(()),
                ),
                maybe(
                    account.as_ref().map(|_| {
                        secondary_button("Explore", theme, |app: &mut TimelineApp| {
                            app.open_explore();
                        })
                    }),
                    column(()),
                ),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            row((
                status_chip(feed_scope.chip_label(), Tone::Neutral, theme),
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
    ui: UiContext,
    nsec_input: String,
    status: TimelineStatus,
    action_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
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
    ui: UiContext,
    account: Option<ActiveAccount>,
    feed_scope: FeedScope,
    follow_input: String,
    status: TimelineStatus,
    clipboard_pending: bool,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
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
                    prose_text(account.npub.clone(), 15.0, theme),
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
                    follow_manager(
                        ui,
                        &account,
                        &feed_scope,
                        follow_input,
                        follow_pending,
                        socket_ready,
                    ),
                    column((
                        status_chip(feed_scope.chip_label(), Tone::Neutral, theme),
                        status_chip(status.message, status.tone, theme),
                        caption_text(feed_scope.detail_text(), theme),
                        caption_text(
                            "Use the clipboard to move this device identity into another app.",
                            theme,
                        ),
                        caption_text(
                            "Replies and follow updates publish through the shared account and OS-owned signer approval.",
                            theme,
                        ),
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

fn explore_screen(
    ui: UiContext,
    account: Option<ActiveAccount>,
    followed_pubkeys: Vec<String>,
    status: TimelineStatus,
    notes: Vec<NostrEvent>,
    profiles: Vec<NostrExploreProfileEntry>,
    socket_ready: bool,
    sync_pending: bool,
    follow_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let note_count = notes.len();
    column((
        top_bar_with_back(
            theme,
            "Shadow Nostr",
            "Explore",
            Some(String::from("Real relay notes outside Home.")),
            TimelineApp::pop_route,
        ),
        panel(
            theme,
            column((
                eyebrow_text("Discovery", theme),
                body_text(
                    "Explore is where Shadow can show recent relay notes. Following from here updates Home, but Home itself stays follow-only.",
                    theme,
                ),
                row((
                    primary_button_state(
                        if sync_pending {
                            "Fetching..."
                        } else {
                            "Fetch relay notes"
                        },
                        theme,
                        if sync_pending || !socket_ready {
                            ActionButtonState::Disabled
                        } else {
                            ActionButtonState::Enabled
                        },
                        |app: &mut TimelineApp| {
                            app.begin_explore_sync();
                        },
                    ),
                    status_chip(
                        format!("{note_count} note{}", plural_suffix(note_count)),
                        Tone::Neutral,
                        theme,
                    ),
                    status_chip(status.message, status.tone, theme),
                ))
                .gap(10.0.px())
                .main_axis_alignment(MainAxisAlignment::Start),
                caption_text(
                    if socket_ready {
                        "Refresh pulls recent notes from the configured relays into the shared cache."
                    } else {
                        "The shared relay engine is unavailable in this session, so Explore can only show cached notes."
                    },
                    theme,
                ),
            ))
            .gap(10.0.px()),
        ),
        explore_profiles_section(
            ui,
            account,
            followed_pubkeys,
            profiles,
            follow_pending,
            socket_ready,
        ),
        feed_section(
            ui,
            "Recent relay notes",
            "No cached relay notes yet. Fetch relay notes to discover profiles to follow.",
            notes,
        ),
    ))
    .gap(12.0.px())
}

fn explore_profiles_section(
    ui: UiContext,
    account: Option<ActiveAccount>,
    followed_pubkeys: Vec<String>,
    profiles: Vec<NostrExploreProfileEntry>,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let followed = followed_pubkeys.into_iter().collect::<BTreeSet<_>>();
    let body = maybe(
        (!profiles.is_empty()).then_some(
            column(
                profiles
                    .into_iter()
                    .map(|profile| {
                        explore_profile_card(
                            ui,
                            account.clone(),
                            followed.contains(&profile.pubkey),
                            profile,
                            follow_pending,
                            socket_ready,
                        )
                    })
                    .collect::<Vec<_>>(),
            )
            .gap(10.0.px()),
        ),
        panel(
            theme,
            column((
                eyebrow_text("Profiles", theme),
                caption_text(
                    "Fetch relay notes to discover accounts you can follow from Explore.",
                    theme,
                ),
            ))
            .gap(6.0.px()),
        ),
    );

    column((eyebrow_text("Profiles", theme), body)).gap(8.0.px())
}

fn explore_profile_card(
    ui: UiContext,
    account: Option<ActiveAccount>,
    is_following: bool,
    profile: NostrExploreProfileEntry,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let open_pubkey = profile.pubkey.clone();
    let follow_pubkey = profile.pubkey.clone();
    let is_active_account = account
        .as_ref()
        .is_some_and(|account| account.npub == profile.pubkey);
    let follow_control = if is_active_account {
        status_chip("active account", Tone::Neutral, theme).boxed()
    } else if !socket_ready {
        status_chip("relay engine unavailable", Tone::Neutral, theme).boxed()
    } else if is_following {
        secondary_button_state(
            "Following",
            theme,
            ActionButtonState::Disabled,
            |_app: &mut TimelineApp| {},
        )
        .boxed()
    } else {
        primary_button_state(
            if follow_pending {
                "Updating..."
            } else {
                "Follow"
            },
            theme,
            if follow_pending {
                ActionButtonState::Disabled
            } else {
                ActionButtonState::Enabled
            },
            move |app: &mut TimelineApp| {
                app.begin_follow_add_for(follow_pubkey.clone());
            },
        )
        .boxed()
    };

    panel(
        theme,
        column((
            row((
                column((
                    headline_text(profile_title(&profile.profile, &profile.pubkey), theme),
                    caption_text(short_id(&profile.pubkey), theme),
                    profile
                        .profile
                        .nip05
                        .clone()
                        .map(|nip05| caption_text(nip05, theme)),
                ))
                .gap(4.0.px())
                .flex(1.0),
                status_chip(relative_time(profile.updated_at), Tone::Neutral, theme),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            caption_text(
                format!(
                    "{} recent note{} cached from this author.",
                    profile.note_count,
                    plural_suffix(profile.note_count)
                ),
                theme,
            ),
            body_text(profile.latest_note_preview, theme),
            row((
                secondary_button("Open profile", theme, move |app: &mut TimelineApp| {
                    app.open_profile(open_pubkey.clone());
                }),
                follow_control,
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
        ))
        .gap(10.0.px()),
    )
}

fn follow_manager(
    ui: UiContext,
    account: &ActiveAccount,
    feed_scope: &FeedScope,
    follow_input: String,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let follows = feed_scope.authors.clone().unwrap_or_default();
    panel(
        theme,
        column((
            eyebrow_text("Home feed", theme),
            headline_text("Follow accounts", theme),
            caption_text(
                "Paste an npub or use Explore to add accounts to Home. This publishes a real contact-list event for the shared account.",
                theme,
            ),
            row((
                text_field(
                    follow_input,
                    "Paste npub to follow",
                    theme,
                    |app: &mut TimelineApp, value| {
                        app.follow_input = value;
                    },
                )
                .flex(1.0),
                primary_button_state(
                    if follow_pending {
                        "Updating..."
                    } else {
                        "Follow"
                    },
                    theme,
                    if follow_pending || !socket_ready {
                        ActionButtonState::Disabled
                    } else {
                        ActionButtonState::Enabled
                    },
                    |app: &mut TimelineApp| {
                        app.begin_follow_add();
                    },
                ),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            maybe(
                (!follows.is_empty()).then_some(
                    column(
                        follows
                            .into_iter()
                            .map(|npub| follow_row(ui, account, npub, follow_pending, socket_ready))
                            .collect::<Vec<_>>(),
                    )
                    .gap(8.0.px()),
                ),
                caption_text(
                    if socket_ready {
                        "Home is empty until this account follows someone."
                    } else {
                        "Home is empty. Follow updates need the shared relay engine."
                    },
                    theme,
                ),
            ),
        ))
        .gap(10.0.px()),
    )
}

fn follow_row(
    ui: UiContext,
    account: &ActiveAccount,
    npub: String,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let open_npub = npub.clone();
    let remove_npub = npub.clone();
    panel(
        theme,
        row((
            column((
                caption_text(short_id(&npub), theme),
                maybe(
                    (npub == account.npub).then_some(caption_text("active account", theme)),
                    caption_text("followed account", theme),
                ),
            ))
            .gap(4.0.px())
            .flex(1.0),
            secondary_button("Open", theme, move |app: &mut TimelineApp| {
                app.open_profile(open_npub.clone());
            }),
            secondary_button_state(
                if follow_pending {
                    "Updating..."
                } else {
                    "Unfollow"
                },
                theme,
                if follow_pending || !socket_ready {
                    ActionButtonState::Disabled
                } else {
                    ActionButtonState::Enabled
                },
                move |app: &mut TimelineApp| {
                    app.begin_follow_remove(remove_npub.clone());
                },
            ),
        ))
        .gap(10.0.px())
        .main_axis_alignment(MainAxisAlignment::Start),
    )
}

fn note_screen(
    ui: UiContext,
    note: Option<NostrEvent>,
    profile: NostrProfileSummary,
    thread: shadow_sdk::services::nostr::timeline::NostrThreadContext,
    reply_draft: Option<ReplyDraft>,
    status: TimelineStatus,
    publish_pending: bool,
    thread_sync_available: bool,
    thread_sync_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let body = match note {
        Some(note) => {
            let note_id = note.id.clone();
            let pubkey = note.pubkey.clone();
            let reply_note_id = note.id.clone();
            let parent = thread.parent.clone();
            let replies = thread.replies.clone();
            let composer = reply_draft
                .as_ref()
                .map(|draft| reply_sheet(ui, &note, draft.clone(), publish_pending));
            with_sheet(
                column((
                top_bar_with_back(
                    theme,
                    "Shadow Nostr",
                    "Thread",
                    Some(format!(
                        "{}  •  {}",
                        profile_title(&profile, &note.pubkey),
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
                        headline_text(profile_title(&profile, &note.pubkey), theme),
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
                feed_section(ui, "Replies", "No cached direct replies yet.", replies),
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

fn reply_sheet(
    ui: UiContext,
    note: &NostrEvent,
    draft: ReplyDraft,
    publish_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let note_id = draft.note_id.clone();
    let note_preview = note.content.lines().next().unwrap_or("").trim();
    let note_preview = if note_preview.is_empty() {
        String::from("Write the first reply to this note.")
    } else {
        note_preview.to_owned()
    };
    let can_publish = !publish_pending && !draft.content.trim().is_empty();

    column((
        eyebrow_text("Reply draft", theme),
        headline_text("Compose reply", theme),
        caption_text(
            format!(
                "Replying to {}  •  {}",
                short_id(&note.pubkey),
                short_id(&note_id)
            ),
            theme,
        ),
        body_text(note_preview, theme),
        multiline_editor(
            draft.content,
            "Write a reply for the shared account and relay engine.",
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
            primary_button_state(
                if publish_pending {
                    "Posting..."
                } else {
                    "Post reply"
                },
                theme,
                if can_publish {
                    ActionButtonState::Enabled
                } else {
                    ActionButtonState::Disabled
                },
                |app: &mut TimelineApp| {
                    app.begin_reply_publish();
                },
            ),
        ))
        .gap(10.0.px())
        .main_axis_alignment(MainAxisAlignment::Start),
        caption_text(
            "This uses the shared account and the OS-owned signer approval prompt.",
            theme,
        ),
    ))
    .gap(10.0.px())
}

fn profile_screen(
    ui: UiContext,
    account: Option<ActiveAccount>,
    pubkey: String,
    profile: NostrProfileSummary,
    notes: Vec<NostrEvent>,
    status: TimelineStatus,
    is_following: bool,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let metadata_status = profile_metadata_status(&profile);
    let note_count = notes.len();
    let follow_button = account.filter(|account| account.npub != pubkey).map(|_| {
        if is_following {
            let unfollow_pubkey = pubkey.clone();
            secondary_button_state(
                if follow_pending {
                    "Updating follows..."
                } else {
                    "Unfollow"
                },
                theme,
                if follow_pending || !socket_ready {
                    ActionButtonState::Disabled
                } else {
                    ActionButtonState::Enabled
                },
                move |app: &mut TimelineApp| {
                    app.begin_follow_remove(unfollow_pubkey.clone());
                },
            )
            .boxed()
        } else {
            let follow_pubkey = pubkey.clone();
            primary_button_state(
                if follow_pending {
                    "Updating follows..."
                } else {
                    "Follow"
                },
                theme,
                if follow_pending || !socket_ready {
                    ActionButtonState::Disabled
                } else {
                    ActionButtonState::Enabled
                },
                move |app: &mut TimelineApp| {
                    app.follow_input = follow_pubkey.clone();
                    app.begin_follow_add();
                },
            )
            .boxed()
        }
    });

    column((
        top_bar_with_back(
            theme,
            "Shadow Nostr",
            profile_title(&profile, &pubkey),
            Some(short_id(&pubkey)),
            TimelineApp::pop_route,
        ),
        panel(
            theme,
            column((
                eyebrow_text("Identity", theme),
                headline_text(profile_title(&profile, &pubkey), theme),
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
                maybe(follow_button, column(())),
            ))
            .gap(10.0.px()),
        ),
        feed_section(
            ui,
            "Recent notes",
            "This author has no cached kind-1 notes yet.",
            notes,
        ),
    ))
    .gap(12.0.px())
}

fn feed_section(
    ui: UiContext,
    title: &str,
    empty_message: &str,
    notes: Vec<NostrEvent>,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let title = title.to_owned();
    let empty_message = empty_message.to_owned();
    let body = maybe(
        (!notes.is_empty()).then_some(
            column(
                notes
                    .into_iter()
                    .map(|note| note_card(ui, note))
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

fn note_card(ui: UiContext, note: NostrEvent) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
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

fn empty_feed_status(feed_scope: &FeedScope) -> TimelineStatus {
    match feed_scope.source {
        FeedSource::Following { .. } => TimelineStatus {
            tone: Tone::Neutral,
            message: String::from("No cached notes yet for followed accounts."),
        },
        FeedSource::NoContacts => TimelineStatus {
            tone: Tone::Neutral,
            message: String::from("Home is empty until you follow accounts."),
        },
        FeedSource::Unavailable => TimelineStatus {
            tone: Tone::Danger,
            message: String::from("No active account is available."),
        },
    }
}

fn home_feed_empty_message(feed_scope: &FeedScope) -> &'static str {
    match feed_scope.source {
        FeedSource::Following { .. } => "No followed-account notes match the current filter or cache state.",
        FeedSource::NoContacts => {
            "Home is empty until this account follows someone. Use Explore or Account to add follows."
        }
        FeedSource::Unavailable => "No active account is available.",
    }
}

fn profile_title(profile: &NostrProfileSummary, pubkey: &str) -> String {
    profile
        .display_name
        .clone()
        .unwrap_or_else(|| short_id(pubkey))
}

fn profile_metadata_status(profile: &NostrProfileSummary) -> (&'static str, Tone) {
    if profile.metadata_event_id.is_some() {
        ("metadata cached", Tone::Success)
    } else {
        ("no metadata yet", Tone::Neutral)
    }
}

fn socket_available() -> bool {
    env::var(NOSTR_SERVICE_SOCKET_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .is_some_and(|value| !value.is_empty())
}

fn run_platform_listener(proxy: MessageProxy<PlatformMessage>) {
    if let Err(error) = spawn_platform_request_listener(move |request| match request {
        shadow_runtime_protocol::AppPlatformRequest::Lifecycle { state } => {
            let handled = proxy.message(PlatformMessage::Lifecycle(state)).is_ok();
            format!(
                "ok\nhandled={}\nstate={}\n",
                if handled { 1 } else { 0 },
                state.as_str()
            )
        }
        shadow_runtime_protocol::AppPlatformRequest::Media { action } => format!(
            "ok\nhandled=0\nreason=unsupported-request\nrequest={}\n",
            action.as_str()
        ),
        shadow_runtime_protocol::AppPlatformRequest::Automation { action, argument } => {
            let message = match (action.as_str(), argument) {
                ("open_first_visible_note", None) => Some(PlatformMessage::OpenFirstVisibleNote),
                ("open_reply", None) => Some(PlatformMessage::OpenReply),
                ("publish_reply", None) => Some(PlatformMessage::PublishReply),
                ("publish_reply_content", Some(value)) => {
                    Some(PlatformMessage::PublishReplyContent(value))
                }
                ("set_reply_content", Some(value)) => Some(PlatformMessage::SetReplyContent(value)),
                _ => None,
            };
            match message {
                Some(message) => {
                    let handled = proxy.message(message).is_ok();
                    format!(
                        "ok\nhandled={}\naction={action}\n",
                        if handled { 1 } else { 0 }
                    )
                }
                None => format!(
                    "ok\nhandled=0\nreason=invalid-action\nrequest=automation:{action}\n"
                ),
            }
        }
    }) {
        eprintln!("{APP_LOG_PREFIX}: platform_listener_start_failed error={error}");
    }
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

fn log_preview_text(content: &str) -> String {
    content.split_whitespace().collect::<Vec<_>>().join(" ")
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

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{
        AccountSource, ActiveAccount, FeedScope, FeedSource, Route, TimelineApp, TimelineConfig,
        TimelineStatus,
    };
    use shadow_sdk::{
        app::{AppSafeAreaInsets, AppWindowMetrics},
        services::nostr::{timeline::NostrHomeFeedScope, NostrEvent},
        ui::Tone,
    };

    fn test_app() -> TimelineApp {
        TimelineApp {
            account: Some(ActiveAccount {
                npub: String::from("npub-owner"),
                source: AccountSource::Generated,
            }),
            config: TimelineConfig {
                limit: 20,
                relay_urls: Vec::new(),
                sync_on_start: false,
            },
            feed_scope: FeedScope::no_contacts(),
            filter_text: String::new(),
            follow_input: String::new(),
            metrics: AppWindowMetrics {
                surface_width: 390,
                surface_height: 844,
                safe_area_insets: AppSafeAreaInsets {
                    left: 0,
                    top: 0,
                    right: 0,
                    bottom: 0,
                },
            },
            nsec_input: String::new(),
            notes: Vec::new(),
            explore_cache: None,
            note_caches: BTreeMap::new(),
            profile_caches: BTreeMap::new(),
            reply_draft: None,
            route_stack: vec![Route::Timeline],
            status: TimelineStatus {
                tone: Tone::Neutral,
                message: String::new(),
            },
            tasks: crate::tasks::TimelineTasks::default(),
        }
    }

    #[test]
    fn missing_contact_list_keeps_home_empty() {
        assert_eq!(FeedScope::from(NostrHomeFeedScope::no_contacts()), FeedScope::no_contacts());
    }

    #[test]
    fn contact_list_without_follows_keeps_home_empty() {
        assert_eq!(
            FeedScope::from(NostrHomeFeedScope::following(Vec::new())),
            FeedScope::no_contacts()
        );
    }

    #[test]
    fn contact_list_builds_following_scope_from_unique_public_keys() {
        let scope = FeedScope::from(NostrHomeFeedScope::following(vec![
            String::from("npub-follow-a"),
            String::from("npub-follow-b"),
            String::from("npub-follow-a"),
        ]));

        assert_eq!(scope.source, FeedSource::Following { count: 2 });
        assert_eq!(
            scope.authors,
            Some(vec![
                String::from("npub-follow-a"),
                String::from("npub-follow-b"),
            ])
        );
    }

    #[test]
    fn profile_state_falls_back_to_cached_home_notes_without_route_cache() {
        let mut app = test_app();
        app.notes.push(NostrEvent {
            content: String::from("note"),
            created_at: 1_700_000_000,
            id: String::from("note-1"),
            kind: 1,
            pubkey: String::from("npub-alice"),
            identifier: None,
            root_event_id: None,
            reply_to_event_id: None,
            references: Vec::new(),
            public_keys: Vec::new(),
        });

        let profile = app.profile_state("npub-alice");

        assert_eq!(profile.notes.len(), 1);
        assert_eq!(profile.notes[0].id, "note-1");
        assert!(profile.summary.display_name.is_none());
    }

    #[test]
    fn note_state_falls_back_to_cached_note_without_route_cache() {
        let mut app = test_app();
        app.notes.push(NostrEvent {
            content: String::from("note"),
            created_at: 1_700_000_000,
            id: String::from("note-1"),
            kind: 1,
            pubkey: String::from("npub-alice"),
            identifier: None,
            root_event_id: None,
            reply_to_event_id: None,
            references: Vec::new(),
            public_keys: Vec::new(),
        });

        let note = app.note_state("note-1");

        assert_eq!(note.note.as_ref().map(|event| event.id.as_str()), Some("note-1"));
        assert!(note.profile.display_name.is_none());
        assert!(note.thread.parent.is_none());
        assert!(note.thread.replies.is_empty());
    }

    #[test]
    fn invalidate_route_caches_clears_route_local_state() {
        let mut app = test_app();
        app.explore_cache = Some(Default::default());
        app.profile_caches
            .insert(String::from("npub-alice"), Default::default());
        app.note_caches
            .insert(String::from("note-1"), Default::default());

        app.invalidate_route_caches();

        assert!(app.explore_cache.is_none());
        assert!(app.profile_caches.is_empty());
        assert!(app.note_caches.is_empty());
    }
}
