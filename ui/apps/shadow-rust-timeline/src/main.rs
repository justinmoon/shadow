use std::collections::BTreeMap;
use std::env;
use std::future;

mod screens;
mod tasks;

use screens::{
    account_screen, explore_screen, note_screen, onboarding_screen, profile_screen, timeline_screen,
};
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
            NostrExploreCacheState, NostrHomeFeedScope, NostrHomeFeedSource, NostrNoteCacheState,
            NostrProfileCacheState, NostrProfileSummary,
        },
        NostrAccountSource, NostrAccountSummary, NostrEvent, NOSTR_SERVICE_SOCKET_ENV,
    },
    ui::{self, fork, tokio, worker_raw, MessageProxy, Tone, UiContext, WidgetView},
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
    OpenAccount,
    OpenExplore,
    OpenTimeline,
    OpenFirstVisibleNote,
    OpenNoteProfile,
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

    fn platform_open_account(&mut self) {
        self.open_account();
        if matches!(self.current_route(), Route::Account) {
            eprintln!("{APP_LOG_PREFIX}: automation_open_account_success");
        } else {
            eprintln!("{APP_LOG_PREFIX}: automation_open_account_failed");
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("No active account is available."),
            };
        }
    }

    fn platform_open_explore(&mut self) {
        self.open_explore();
        if matches!(self.current_route(), Route::Explore) {
            eprintln!("{APP_LOG_PREFIX}: automation_open_explore_success");
        } else {
            eprintln!("{APP_LOG_PREFIX}: automation_open_explore_failed");
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Explore needs an active account."),
            };
        }
    }

    fn platform_open_timeline(&mut self) {
        self.reply_draft = None;
        if self.account.is_some() {
            self.route_stack = vec![Route::Timeline];
            eprintln!("{APP_LOG_PREFIX}: automation_open_timeline_success");
        } else {
            eprintln!("{APP_LOG_PREFIX}: automation_open_timeline_failed");
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("No active account is available."),
            };
        }
    }

    fn first_visible_note_id_for_route(&self) -> Option<String> {
        match self.current_route() {
            Route::Timeline => self.visible_notes().into_iter().next().map(|note| note.id),
            Route::Explore => self
                .explore_state()
                .notes
                .into_iter()
                .next()
                .map(|note| note.id),
            Route::Profile { pubkey } => self
                .profile_state(&pubkey)
                .notes
                .into_iter()
                .next()
                .map(|note| note.id),
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

    fn platform_open_note_profile(&mut self) {
        let Route::Note { id } = self.current_route() else {
            eprintln!("{APP_LOG_PREFIX}: automation_open_note_profile_failed");
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Open a note before opening its profile."),
            };
            return;
        };
        let Some(note) = self.note_state(&id).note else {
            eprintln!("{APP_LOG_PREFIX}: automation_open_note_profile_failed");
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("No cached note is available for this route."),
            };
            return;
        };
        let pubkey = note.pubkey;
        eprintln!("{APP_LOG_PREFIX}: automation_open_note_profile_success pubkey={pubkey}");
        self.push_route(Route::Profile { pubkey });
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
        self.note_caches
            .get(note_id)
            .cloned()
            .unwrap_or_else(|| NostrNoteCacheState {
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
                PlatformMessage::OpenAccount => app.platform_open_account(),
                PlatformMessage::OpenExplore => app.platform_open_explore(),
                PlatformMessage::OpenTimeline => app.platform_open_timeline(),
                PlatformMessage::OpenFirstVisibleNote => app.platform_open_first_visible_note(),
                PlatformMessage::OpenNoteProfile => app.platform_open_note_profile(),
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
                ("open_account", None) => Some(PlatformMessage::OpenAccount),
                ("open_explore", None) => Some(PlatformMessage::OpenExplore),
                ("open_timeline", None) => Some(PlatformMessage::OpenTimeline),
                ("open_first_visible_note", None) => Some(PlatformMessage::OpenFirstVisibleNote),
                ("open_note_profile", None) => Some(PlatformMessage::OpenNoteProfile),
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
                None => {
                    format!("ok\nhandled=0\nreason=invalid-action\nrequest=automation:{action}\n")
                }
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
        app_logic, AccountSource, ActiveAccount, FeedScope, FeedSource, Route, TimelineApp,
        TimelineConfig, TimelineStatus,
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

    fn test_note(id: &str, pubkey: &str, content: &str) -> NostrEvent {
        NostrEvent {
            content: content.to_owned(),
            created_at: 1_700_000_000,
            id: id.to_owned(),
            kind: 1,
            pubkey: pubkey.to_owned(),
            identifier: None,
            root_event_id: None,
            reply_to_event_id: None,
            references: Vec::new(),
            public_keys: Vec::new(),
        }
    }

    #[test]
    fn missing_contact_list_keeps_home_empty() {
        assert_eq!(
            FeedScope::from(NostrHomeFeedScope::no_contacts()),
            FeedScope::no_contacts()
        );
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
        app.notes.push(test_note("note-1", "npub-alice", "note"));

        let profile = app.profile_state("npub-alice");

        assert_eq!(profile.notes.len(), 1);
        assert_eq!(profile.notes[0].id, "note-1");
        assert!(profile.summary.display_name.is_none());
    }

    #[test]
    fn note_state_falls_back_to_cached_note_without_route_cache() {
        let mut app = test_app();
        app.notes.push(test_note("note-1", "npub-alice", "note"));

        let note = app.note_state("note-1");

        assert_eq!(
            note.note.as_ref().map(|event| event.id.as_str()),
            Some("note-1")
        );
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

    #[test]
    fn platform_route_automation_navigates_across_moved_screens() {
        let mut app = test_app();
        app.notes.push(test_note("note-1", "npub-alice", "hello"));

        app.platform_open_first_visible_note();
        assert_eq!(
            app.current_route(),
            Route::Note {
                id: String::from("note-1")
            }
        );

        app.platform_open_note_profile();
        assert_eq!(
            app.current_route(),
            Route::Profile {
                pubkey: String::from("npub-alice")
            }
        );

        app.platform_open_account();
        assert_eq!(app.current_route(), Route::Account);

        app.platform_open_explore();
        assert_eq!(app.current_route(), Route::Explore);

        app.platform_open_timeline();
        assert_eq!(app.current_route(), Route::Timeline);
    }

    #[test]
    fn app_logic_builds_onboarding_route_without_account() {
        let mut app = test_app();
        app.account = None;
        app.feed_scope = FeedScope::unavailable();
        app.route_stack = vec![Route::Onboarding];

        let _ = app_logic(&mut app);
    }
}
