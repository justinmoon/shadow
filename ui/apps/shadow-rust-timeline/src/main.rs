use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::future;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;
use shadow_sdk::{
    app::{
        current_lifecycle_state, spawn_platform_request_listener, AppWindowDefaults,
        AppWindowEnvironment, AppWindowMetrics, LifecycleState,
    },
    services::clipboard::write_text as write_clipboard_text,
    services::nostr::{
        current_account, generate_account, get_event, get_replaceable, import_account_nsec,
        publish, query, sync, NostrAccountSource, NostrAccountSummary, NostrEvent,
        NostrPublicKeyReference, NostrPublishReceipt, NostrPublishRequest, NostrQuery,
        NostrReplaceableQuery, NostrSyncRequest, NOSTR_SERVICE_SOCKET_ENV,
    },
    ui::{
        self, body_text, caption_text, column, eyebrow_text, fork, headline_text, maybe,
        multiline_editor, panel, primary_button, primary_button_state, prose_text, row,
        secondary_button, secondary_button_state, selectable_card, status_chip, text_field, tokio,
        top_bar, top_bar_with_back, with_sheet, with_task, worker_raw, ActionButtonState, AsUnit,
        FlexExt, MainAxisAlignment, MessageProxy, TaskHandle, TaskSlot, Tone, UiContext,
        WidgetView,
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

#[derive(Clone, Copy, Debug)]
enum RefreshSource {
    Startup,
    Manual,
    FollowUpdate,
}

#[derive(Clone, Debug)]
struct PendingRefresh {
    account_npub: String,
    limit: usize,
    relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
struct PendingExploreSync {
    limit: usize,
    relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
struct PendingThreadSync {
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
}

#[derive(Clone, Debug)]
struct PendingClipboardWrite {
    text: String,
}

#[derive(Clone, Debug)]
enum FollowActionKind {
    Add { npub: String },
    Remove { npub: String },
}

#[derive(Clone, Debug)]
struct PendingFollowUpdate {
    account_npub: String,
    action: FollowActionKind,
    relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
struct PendingPublish {
    content: String,
    note_id: String,
    relay_urls: Vec<String>,
    reply_to_event_id: String,
    root_event_id: Option<String>,
}

#[derive(Debug)]
struct RefreshOutcome {
    feed_scope: FeedScope,
    fetched_count: usize,
    imported_count: usize,
    notes: Vec<NostrEvent>,
}

#[derive(Debug)]
struct ExploreSyncOutcome {
    fetched_count: usize,
    imported_count: usize,
}

#[derive(Debug)]
struct ThreadSyncOutcome {
    fetched_count: usize,
    imported_count: usize,
}

#[derive(Debug)]
struct PublishOutcome {
    receipt: NostrPublishReceipt,
}

#[derive(Debug)]
struct FollowUpdateOutcome {
    receipt: NostrPublishReceipt,
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

#[derive(Clone, Debug)]
struct ExploreProfileEntry {
    latest_note_preview: String,
    note_count: usize,
    profile: ProfileSummary,
    pubkey: String,
    updated_at: u64,
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
    feed_scope: FeedScope,
    filter_text: String,
    follow_input: String,
    metrics: AppWindowMetrics,
    nsec_input: String,
    pending_account_action: TaskSlot<PendingAccountAction>,
    pending_clipboard_write: TaskSlot<PendingClipboardWrite>,
    pending_follow_update: TaskSlot<PendingFollowUpdate>,
    pending_publish: TaskSlot<PendingPublish>,
    notes: Vec<NostrEvent>,
    pending_explore_sync: TaskSlot<PendingExploreSync>,
    pending_refresh: TaskSlot<PendingRefresh>,
    pending_thread_sync: TaskSlot<PendingThreadSync>,
    profiles: BTreeMap<String, ProfileSummary>,
    reply_draft: Option<ReplyDraft>,
    route_stack: Vec<Route>,
    status: TimelineStatus,
}

impl TimelineApp {
    fn new(window_env: AppWindowEnvironment, config: TimelineConfig) -> Self {
        let account_result = current_account().map(|account| account.map(ActiveAccount::from));
        let metrics = window_env.metrics();
        let (account, route_stack, feed_scope, notes, status) = match account_result {
            Ok(Some(account)) => {
                let feed_scope = load_feed_scope(Some(&account));
                match load_cached_notes(config.limit, &feed_scope) {
                    Ok(notes) if notes.is_empty() => {
                        let status = empty_feed_status(&feed_scope);
                        (
                            Some(account),
                            vec![Route::Timeline],
                            feed_scope,
                            Vec::new(),
                            status,
                        )
                    }
                    Ok(notes) => {
                        let count = notes.len();
                        (
                            Some(account),
                            vec![Route::Timeline],
                            feed_scope,
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
                        Some(account),
                        vec![Route::Timeline],
                        feed_scope,
                        Vec::new(),
                        TimelineStatus {
                            tone: Tone::Danger,
                            message: error,
                        },
                    ),
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
            filter_text: String::new(),
            follow_input: String::new(),
            metrics,
            nsec_input: String::new(),
            pending_account_action: TaskSlot::new(),
            pending_clipboard_write: TaskSlot::new(),
            pending_follow_update: TaskSlot::new(),
            pending_publish: TaskSlot::new(),
            notes,
            pending_explore_sync: TaskSlot::new(),
            pending_refresh: TaskSlot::new(),
            pending_thread_sync: TaskSlot::new(),
            profiles: BTreeMap::new(),
            reply_draft: None,
            route_stack,
            status,
        };
        if app.account.is_some() && app.config.sync_on_start && socket_available() {
            app.begin_refresh(RefreshSource::Startup);
        }
        app
    }

    fn begin_refresh(&mut self, source: RefreshSource) {
        let Some(account) = self.account.as_ref() else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Set up an account before refreshing the timeline."),
            };
            return;
        };
        if self.pending_refresh.is_pending() {
            return;
        }
        let account_npub = account.npub.clone();
        self.pending_refresh.start(PendingRefresh {
            account_npub,
            limit: self.config.limit,
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: match source {
                RefreshSource::Startup => String::from("Refreshing timeline from relays..."),
                RefreshSource::Manual => String::from("Talking to relays for fresh notes..."),
                RefreshSource::FollowUpdate => {
                    String::from("Updating Home from the new contact list...")
                }
            },
        };
    }

    fn begin_explore_sync(&mut self) {
        if self.pending_explore_sync.is_pending() {
            return;
        }
        self.pending_explore_sync.start(PendingExploreSync {
            limit: self.config.limit.max(24),
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Fetching recent relay notes for Explore..."),
        };
    }

    fn begin_account_generate(&mut self) {
        if self.pending_account_action.is_pending() {
            return;
        }
        self.pending_account_action.start(PendingAccountAction {
            kind: AccountActionKind::Generate,
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Generating a new Nostr account..."),
        };
    }

    fn begin_account_import(&mut self) {
        if self.pending_account_action.is_pending() {
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
        self.pending_account_action.start(PendingAccountAction {
            kind: AccountActionKind::Import {
                nsec: nsec.to_owned(),
            },
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Importing the Nostr account from nsec..."),
        };
    }

    fn begin_thread_sync(&mut self, note_id: String) {
        if self.pending_thread_sync.is_pending() {
            return;
        }
        let Some(note) = self.cached_note_by_id(&note_id) else {
            return;
        };
        self.pending_thread_sync.start(PendingThreadSync {
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
        if self.pending_clipboard_write.is_pending() {
            return;
        }
        let Some(account) = self.account.as_ref() else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("No active account is available to copy."),
            };
            return;
        };
        self.pending_clipboard_write.start(PendingClipboardWrite {
            text: account.npub.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Copying the active npub to the clipboard..."),
        };
    }

    fn begin_follow_add(&mut self) {
        let npub = self.follow_input.trim().to_owned();
        self.begin_follow_add_for(npub);
    }

    fn begin_follow_add_for(&mut self, npub: String) {
        if self.pending_follow_update.is_pending() {
            return;
        }
        if !socket_available() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from(
                    "Follow updates need the shared relay engine. Start a session with Nostr services enabled.",
                ),
            };
            return;
        }
        let Some(account) = self.account.as_ref() else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Set up an account before following anyone."),
            };
            return;
        };
        let npub = npub.trim().to_owned();
        if npub.is_empty() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Paste an npub before trying to follow it."),
            };
            return;
        }
        if npub == account.npub {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("This account is already your own identity."),
            };
            return;
        }

        if self
            .current_followed_pubkeys()
            .iter()
            .any(|existing| existing == &npub)
        {
            self.status = TimelineStatus {
                tone: Tone::Neutral,
                message: String::from("That account is already in the contact list."),
            };
            return;
        }
        self.pending_follow_update.start(PendingFollowUpdate {
            account_npub: account.npub.clone(),
            action: FollowActionKind::Add { npub },
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Updating the shared contact list..."),
        };
    }

    fn begin_follow_remove(&mut self, npub: String) {
        if self.pending_follow_update.is_pending() {
            return;
        }
        if !socket_available() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from(
                    "Follow updates need the shared relay engine. Start a session with Nostr services enabled.",
                ),
            };
            return;
        }
        let Some(account) = self.account.as_ref() else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Set up an account before changing follows."),
            };
            return;
        };
        self.pending_follow_update.start(PendingFollowUpdate {
            account_npub: account.npub.clone(),
            action: FollowActionKind::Remove { npub },
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Updating the shared contact list..."),
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

    fn begin_reply_publish(&mut self) {
        if self.pending_publish.is_pending() {
            return;
        }
        let Some(draft) = self.reply_draft.clone() else {
            return;
        };
        let content = draft.content.trim();
        if content.is_empty() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Write a reply before trying to publish."),
            };
            return;
        }
        let Some(note) = self.cached_note_by_id(&draft.note_id) else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("That note is no longer available for replying."),
            };
            return;
        };
        self.pending_publish.start(PendingPublish {
            content: content.to_owned(),
            note_id: note.id.clone(),
            relay_urls: self.config.relay_urls.clone(),
            reply_to_event_id: note.id.clone(),
            root_event_id: note.root_event_id.clone().or_else(|| Some(note.id)),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Publishing reply through the shared Nostr account..."),
        };
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

    fn follow_update_pending_for(&self, pubkey: &str) -> bool {
        self.pending_follow_update
            .pending()
            .is_some_and(|pending| match &pending.job().action {
                FollowActionKind::Add { npub } | FollowActionKind::Remove { npub } => {
                    npub == pubkey
                }
            })
    }

    fn finish_refresh(
        &mut self,
        task: TaskHandle<PendingRefresh>,
        result: Result<RefreshOutcome, String>,
    ) {
        if self.pending_refresh.finish(task.id()).is_none() {
            return;
        };

        match result {
            Ok(outcome) => {
                self.feed_scope = outcome.feed_scope;
                self.notes = outcome.notes;
                self.profiles.clear();
                self.sync_routes();
                self.status = if self.notes.is_empty() {
                    empty_feed_status(&self.feed_scope)
                } else {
                    TimelineStatus {
                        tone: Tone::Success,
                        message: format!(
                            "Fetched {} note{}, imported {}.",
                            outcome.fetched_count,
                            plural_suffix(outcome.fetched_count),
                            outcome.imported_count,
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

    fn finish_explore_sync(
        &mut self,
        task: TaskHandle<PendingExploreSync>,
        result: Result<ExploreSyncOutcome, String>,
    ) {
        if self.pending_explore_sync.finish(task.id()).is_none() {
            return;
        };

        self.status = match result {
            Ok(outcome) => TimelineStatus {
                tone: Tone::Success,
                message: format!(
                    "Explore fetched {} note{}, imported {}.",
                    outcome.fetched_count,
                    plural_suffix(outcome.fetched_count),
                    outcome.imported_count,
                ),
            },
            Err(message) => TimelineStatus {
                tone: Tone::Danger,
                message,
            },
        };
    }

    fn finish_thread_sync(
        &mut self,
        task: TaskHandle<PendingThreadSync>,
        result: Result<ThreadSyncOutcome, String>,
    ) {
        if self.pending_thread_sync.finish(task.id()).is_none() {
            return;
        };

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
                eprintln!("{APP_LOG_PREFIX}: publish_error={message}");
                self.status = TimelineStatus {
                    tone: Tone::Danger,
                    message,
                };
            }
        }
    }

    fn finish_account_action(
        &mut self,
        task: TaskHandle<PendingAccountAction>,
        result: Result<ActiveAccount, String>,
    ) {
        if self.pending_account_action.finish(task.id()).is_none() {
            return;
        };

        match result {
            Ok(account) => {
                let message = format!(
                    "Account ready: {} ({})",
                    short_id(&account.npub),
                    account.source.label()
                );
                self.account = Some(account);
                if let Err(error) = self.reload_feed_from_cache() {
                    self.notes.clear();
                    self.feed_scope = FeedScope::unavailable();
                    self.status = TimelineStatus {
                        tone: Tone::Danger,
                        message: error,
                    };
                    return;
                }
                self.nsec_input.clear();
                let has_follows = matches!(self.feed_scope.source, FeedSource::Following { .. });
                self.route_stack = vec![if has_follows {
                    Route::Timeline
                } else {
                    Route::Explore
                }];
                self.status = if has_follows {
                    TimelineStatus {
                        tone: Tone::Success,
                        message,
                    }
                } else {
                    TimelineStatus {
                        tone: Tone::Success,
                        message: String::from(
                            "Account ready. Explore recent relay notes and follow people to populate Home.",
                        ),
                    }
                };
                if self.config.sync_on_start && socket_available() {
                    if has_follows {
                        self.begin_refresh(RefreshSource::Startup);
                    } else {
                        self.begin_explore_sync();
                    }
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

    fn finish_clipboard_write(
        &mut self,
        task: TaskHandle<PendingClipboardWrite>,
        result: Result<(), String>,
    ) {
        if self.pending_clipboard_write.finish(task.id()).is_none() {
            return;
        };

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

    fn finish_follow_update(
        &mut self,
        task: TaskHandle<PendingFollowUpdate>,
        result: Result<FollowUpdateOutcome, String>,
    ) {
        let Some(pending) = self.pending_follow_update.finish(task.id()) else {
            return;
        };
        let action = pending.action;

        match result {
            Ok(outcome) => {
                if let Err(error) = self.reload_feed_from_cache() {
                    self.status = TimelineStatus {
                        tone: Tone::Danger,
                        message: error,
                    };
                    return;
                }
                match action {
                    FollowActionKind::Add { npub } => {
                        self.follow_input.clear();
                        if socket_available() {
                            self.status = TimelineStatus {
                                tone: Tone::Success,
                                message: format!(
                                    "Updated follows for {}. Refreshing Home from relays...",
                                    short_id(&npub)
                                ),
                            };
                            self.begin_refresh(RefreshSource::FollowUpdate);
                        } else {
                            self.status = TimelineStatus {
                                tone: Tone::Success,
                                message: format!(
                                    "Followed {}. Refresh when the shared relay engine is available.",
                                    short_id(&npub)
                                ),
                            };
                        }
                    }
                    FollowActionKind::Remove { npub } => {
                        self.status = TimelineStatus {
                            tone: Tone::Success,
                            message: format!(
                                "Removed {} from Home. Contact list published to {} relay{}.",
                                short_id(&npub),
                                outcome.receipt.published_relays.len(),
                                plural_suffix(outcome.receipt.published_relays.len()),
                            ),
                        };
                    }
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

    fn finish_publish(
        &mut self,
        task: TaskHandle<PendingPublish>,
        result: Result<PublishOutcome, String>,
    ) {
        let Some(pending) = self.pending_publish.finish(task.id()) else {
            return;
        };
        let publish_preview = log_preview_text(&pending.content);

        match result {
            Ok(outcome) => {
                if let Err(error) = self.reload_feed_from_cache() {
                    self.status = TimelineStatus {
                        tone: Tone::Danger,
                        message: error,
                    };
                    return;
                }
                self.sync_routes();
                self.reply_draft = None;
                let relay_count = outcome.receipt.published_relays.len();
                let suffix = if outcome.receipt.failed_relays.is_empty() {
                    String::new()
                } else {
                    format!(
                        "; {} relay{} failed",
                        outcome.receipt.failed_relays.len(),
                        plural_suffix(outcome.receipt.failed_relays.len())
                    )
                };
                eprintln!(
                    "{APP_LOG_PREFIX}: publish_result=success preview={publish_preview} published_relays={relay_count} failed_relays={}",
                    outcome.receipt.failed_relays.len()
                );
                self.status = TimelineStatus {
                    tone: Tone::Success,
                    message: format!(
                        "Published reply to {relay_count} relay{}{suffix}.",
                        plural_suffix(relay_count),
                    ),
                };
            }
            Err(message) => {
                eprintln!(
                    "{APP_LOG_PREFIX}: publish_result=error preview={publish_preview} error={message}"
                );
                self.status = TimelineStatus {
                    tone: Tone::Danger,
                    message,
                };
            }
        }
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
            Route::Account | Route::Explore | Route::Onboarding | Route::Timeline => {}
            Route::Note { id } => {
                if let Some(note) = self.cached_note_by_id(id) {
                    self.ensure_profile_loaded(&note.pubkey);
                }
            }
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
            Route::Explore => self.explore_notes().into_iter().next().map(|note| note.id),
            Route::Profile { pubkey } => self
                .profile_notes(&pubkey)
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
        if self.pending_publish.is_pending() {
            eprintln!("{APP_LOG_PREFIX}: automation_publish_reply_success");
        } else {
            eprintln!("{APP_LOG_PREFIX}: automation_publish_reply_failed");
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

    fn explore_notes(&self) -> Vec<NostrEvent> {
        load_explore_notes(self.config.limit.max(24)).unwrap_or_default()
    }

    fn explore_profiles_for_notes(&self, notes: &[NostrEvent]) -> Vec<ExploreProfileEntry> {
        let mut note_counts = BTreeMap::new();
        for note in notes {
            *note_counts.entry(note.pubkey.clone()).or_insert(0_usize) += 1;
        }

        let mut seen = BTreeSet::new();
        let mut profiles = Vec::new();
        for note in notes {
            if !seen.insert(note.pubkey.clone()) {
                continue;
            }
            profiles.push(ExploreProfileEntry {
                latest_note_preview: note_preview(&note.content),
                note_count: *note_counts.get(&note.pubkey).unwrap_or(&1),
                profile: load_profile_summary(&note.pubkey),
                pubkey: note.pubkey.clone(),
                updated_at: note.created_at,
            });
        }
        profiles
    }

    fn reply_draft_for(&self, note_id: &str) -> Option<ReplyDraft> {
        self.reply_draft
            .as_ref()
            .filter(|draft| draft.note_id == note_id)
            .cloned()
    }

    fn reload_feed_from_cache(&mut self) -> Result<(), String> {
        self.feed_scope = load_feed_scope(self.account.as_ref());
        self.notes = load_cached_notes(self.config.limit, &self.feed_scope)?;
        Ok(())
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
    let pending_account_action = app.pending_account_action.pending_cloned();
    let pending_clipboard_write = app.pending_clipboard_write.pending_cloned();
    let pending_explore_sync = app.pending_explore_sync.pending_cloned();
    let pending_follow_update = app.pending_follow_update.pending_cloned();
    let pending_publish = app.pending_publish.pending_cloned();
    let pending_refresh = app.pending_refresh.pending_cloned();
    let pending_thread_sync = app.pending_thread_sync.pending_cloned();
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
            pending_clipboard_write.is_some(),
            pending_follow_update.is_some(),
            socket_available(),
        )
        .boxed(),
        Route::Explore => {
            let notes = app.explore_notes();
            let profiles = app.explore_profiles_for_notes(&notes);
            explore_screen(
                ui,
                app.account.clone(),
                app.current_followed_pubkeys(),
                app.status.clone(),
                notes,
                profiles,
                socket_available(),
                pending_explore_sync.is_some(),
                pending_follow_update.is_some(),
            )
            .boxed()
        }
        Route::Onboarding => onboarding_screen(
            ui,
            app.nsec_input.clone(),
            app.status.clone(),
            pending_account_action.is_some(),
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
            let note = app.cached_note_by_id(&id);
            let profile = note
                .as_ref()
                .map(|note| app.profile_summary(&note.pubkey))
                .unwrap_or_default();
            let thread = note.as_ref().map(load_thread_context).unwrap_or_default();
            let thread_sync_pending = pending_thread_sync
                .as_ref()
                .is_some_and(|job| job.job().note_id == id);
            let publish_pending = pending_publish
                .as_ref()
                .is_some_and(|job| job.job().note_id == id);
            note_screen(
                ui,
                note,
                profile,
                thread,
                app.reply_draft_for(&id),
                app.status.clone(),
                publish_pending,
                socket_available(),
                thread_sync_pending,
            )
            .boxed()
        }
        Route::Profile { pubkey } => {
            profile_screen(
                ui,
                app.account.clone(),
                pubkey.clone(),
                app.profile_summary(&pubkey),
                app.profile_notes(&pubkey),
                app.status.clone(),
                app.is_following(&pubkey),
                app.follow_update_pending_for(&pubkey),
                socket_available(),
            )
            .boxed()
        }
    };

    let content = ui.screen(body);
    let content = with_task(
        content,
        pending_account_action,
        run_account_action,
        |app: &mut TimelineApp, task: TaskHandle<PendingAccountAction>, result| {
            app.finish_account_action(task, result);
        },
    );
    let content = with_task(
        content,
        pending_clipboard_write,
        run_clipboard_write,
        |app: &mut TimelineApp, task: TaskHandle<PendingClipboardWrite>, result| {
            app.finish_clipboard_write(task, result);
        },
    );
    let content = with_task(
        content,
        pending_explore_sync,
        sync_explore_notes,
        |app: &mut TimelineApp, task: TaskHandle<PendingExploreSync>, result| {
            app.finish_explore_sync(task, result);
        },
    );
    let content = with_task(
        content,
        pending_follow_update,
        run_follow_update,
        |app: &mut TimelineApp, task: TaskHandle<PendingFollowUpdate>, result| {
            app.finish_follow_update(task, result);
        },
    );
    let content = with_task(
        content,
        pending_thread_sync,
        sync_thread_context,
        |app: &mut TimelineApp, task: TaskHandle<PendingThreadSync>, result| {
            app.finish_thread_sync(task, result);
        },
    );
    let content = with_task(
        content,
        pending_publish,
        run_reply_publish,
        |app: &mut TimelineApp, task: TaskHandle<PendingPublish>, result| {
            app.finish_publish(task, result);
        },
    );

    let content = with_task(
        content,
        pending_refresh,
        sync_notes,
        |app: &mut TimelineApp, task: TaskHandle<PendingRefresh>, result| {
            app.finish_refresh(task, result);
        },
    );

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
    profiles: Vec<ExploreProfileEntry>,
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
    profiles: Vec<ExploreProfileEntry>,
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
    profile: ExploreProfileEntry,
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
                    headline_text(profile.profile.title(&profile.pubkey), theme),
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
    profile: ProfileSummary,
    thread: ThreadContext,
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
    profile: ProfileSummary,
    notes: Vec<NostrEvent>,
    status: TimelineStatus,
    is_following: bool,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let metadata_status = profile.metadata_status();
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

fn run_follow_update(job: PendingFollowUpdate) -> Result<FollowUpdateOutcome, String> {
    let relay_urls = (!job.relay_urls.is_empty()).then_some(job.relay_urls.clone());
    let _ = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: Some(vec![job.account_npub.clone()]),
            kinds: Some(vec![3]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(1),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })
    .map_err(|error| format!("Could not refresh the latest contact list: {error}"))?;
    let mut public_keys = load_contact_references_for_npub(&job.account_npub);
    match job.action {
        FollowActionKind::Add { npub } => {
            if public_keys
                .iter()
                .all(|reference| reference.public_key != npub)
            {
                public_keys.push(NostrPublicKeyReference {
                    public_key: npub,
                    relay_url: None,
                    alias: None,
                });
            }
        }
        FollowActionKind::Remove { npub } => {
            public_keys.retain(|reference| reference.public_key != npub);
        }
    }
    let receipt = publish(NostrPublishRequest::ContactList {
        public_keys,
        relay_urls,
        timeout_ms: Some(12_000),
    })
    .map_err(|error| error.to_string())?;

    Ok(FollowUpdateOutcome { receipt })
}

fn run_reply_publish(job: PendingPublish) -> Result<PublishOutcome, String> {
    let receipt = publish(NostrPublishRequest::TextNote {
        content: job.content,
        root_event_id: job.root_event_id,
        reply_to_event_id: Some(job.reply_to_event_id),
        relay_urls: (!job.relay_urls.is_empty()).then_some(job.relay_urls),
        timeout_ms: Some(12_000),
    })
    .map_err(|error| error.to_string())?;

    Ok(PublishOutcome { receipt })
}

fn sync_notes(job: PendingRefresh) -> Result<RefreshOutcome, String> {
    let relay_urls = (!job.relay_urls.is_empty()).then_some(job.relay_urls.clone());
    let mut fetched_count = 0_usize;
    let mut imported_count = 0_usize;

    let account_receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: Some(vec![job.account_npub.clone()]),
            kinds: Some(vec![0, 3]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(4),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })
    .map_err(|error| error.to_string())?;
    fetched_count += account_receipt.fetched_count;
    imported_count += account_receipt.imported_count;

    let feed_scope = load_feed_scope_for_npub(&job.account_npub);
    if let Some(authors) = feed_scope.authors.clone() {
        let profile_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors.clone()),
                kinds: Some(vec![0]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(authors.len().max(1)),
            },
            relay_urls: relay_urls.clone(),
            timeout_ms: Some(8_000),
        })
        .map_err(|error| error.to_string())?;
        fetched_count += profile_receipt.fetched_count;
        imported_count += profile_receipt.imported_count;

        let note_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors),
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(job.limit),
            },
            relay_urls,
            timeout_ms: Some(8_000),
        })
        .map_err(|error| error.to_string())?;
        fetched_count += note_receipt.fetched_count;
        imported_count += note_receipt.imported_count;
    }

    let notes = load_cached_notes(job.limit, &feed_scope)?;

    Ok(RefreshOutcome {
        feed_scope,
        fetched_count,
        imported_count,
        notes,
    })
}

fn sync_explore_notes(job: PendingExploreSync) -> Result<ExploreSyncOutcome, String> {
    let relay_urls = (!job.relay_urls.is_empty()).then_some(job.relay_urls.clone());
    let note_receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: None,
            kinds: Some(vec![1]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(job.limit),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })
    .map_err(|error| error.to_string())?;
    let notes = load_explore_notes(job.limit)?;
    let authors = notes
        .iter()
        .map(|note| note.pubkey.clone())
        .collect::<Vec<_>>();
    let mut fetched_count = note_receipt.fetched_count;
    let mut imported_count = note_receipt.imported_count;
    if !authors.is_empty() {
        let profile_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors),
                kinds: Some(vec![0]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(job.limit),
            },
            relay_urls,
            timeout_ms: Some(8_000),
        })
        .map_err(|error| error.to_string())?;
        fetched_count += profile_receipt.fetched_count;
        imported_count += profile_receipt.imported_count;
    }

    Ok(ExploreSyncOutcome {
        fetched_count,
        imported_count,
    })
}

fn load_cached_notes(limit: usize, feed_scope: &FeedScope) -> Result<Vec<NostrEvent>, String> {
    let Some(authors) = feed_scope.authors.clone() else {
        return Ok(Vec::new());
    };
    query(NostrQuery {
        ids: None,
        authors: Some(authors),
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit),
    })
    .map_err(|error| error.to_string())
}

fn load_explore_notes(limit: usize) -> Result<Vec<NostrEvent>, String> {
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

fn load_feed_scope(account: Option<&ActiveAccount>) -> FeedScope {
    account
        .map(|account| load_feed_scope_for_npub(&account.npub))
        .unwrap_or_else(FeedScope::unavailable)
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

fn load_feed_scope_for_npub(npub: &str) -> FeedScope {
    feed_scope_from_contact_list(load_contact_list_event_for_npub(npub))
}

fn feed_scope_from_contact_list(contact_list: Option<NostrEvent>) -> FeedScope {
    let Some(contact_list) = contact_list else {
        return FeedScope::no_contacts();
    };
    let mut authors = Vec::new();
    for reference in contact_list.public_keys {
        if authors.iter().all(|author| author != &reference.public_key) {
            authors.push(reference.public_key);
        }
    }

    if authors.is_empty() {
        FeedScope::no_contacts()
    } else {
        let follow_count = authors.len();
        FeedScope::following(authors, follow_count)
    }
}

fn load_contact_list_event_for_npub(npub: &str) -> Option<NostrEvent> {
    get_replaceable(NostrReplaceableQuery {
        kind: 3,
        pubkey: npub.to_owned(),
        identifier: None,
    })
    .ok()
    .flatten()
}

fn load_contact_references_for_npub(npub: &str) -> Vec<NostrPublicKeyReference> {
    load_contact_list_event_for_npub(npub)
        .map(|event| event.public_keys)
        .unwrap_or_default()
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

fn note_preview(content: &str) -> String {
    let preview = content.lines().next().unwrap_or("").trim();
    if preview.is_empty() {
        String::from("No visible text in the latest cached note.")
    } else {
        preview.to_owned()
    }
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
    use super::{feed_scope_from_contact_list, FeedScope, FeedSource};
    use shadow_sdk::services::nostr::{NostrEvent, NostrPublicKeyReference};

    fn contact_list_event(public_keys: &[&str]) -> NostrEvent {
        NostrEvent {
            content: String::new(),
            created_at: 1_700_000_000,
            id: String::from("contact-list"),
            kind: 3,
            pubkey: String::from("npub-owner"),
            identifier: None,
            root_event_id: None,
            reply_to_event_id: None,
            references: Vec::new(),
            public_keys: public_keys
                .iter()
                .map(|public_key| NostrPublicKeyReference {
                    public_key: (*public_key).to_owned(),
                    relay_url: None,
                    alias: None,
                })
                .collect(),
        }
    }

    #[test]
    fn missing_contact_list_keeps_home_empty() {
        assert_eq!(feed_scope_from_contact_list(None), FeedScope::no_contacts());
    }

    #[test]
    fn contact_list_without_follows_keeps_home_empty() {
        assert_eq!(
            feed_scope_from_contact_list(Some(contact_list_event(&[]))),
            FeedScope::no_contacts()
        );
    }

    #[test]
    fn contact_list_builds_following_scope_from_unique_public_keys() {
        let scope = feed_scope_from_contact_list(Some(contact_list_event(&[
            "npub-follow-a",
            "npub-follow-b",
            "npub-follow-a",
        ])));

        assert_eq!(scope.source, FeedSource::Following { count: 2 });
        assert_eq!(
            scope.authors,
            Some(vec![
                String::from("npub-follow-a"),
                String::from("npub-follow-b"),
            ])
        );
    }
}
