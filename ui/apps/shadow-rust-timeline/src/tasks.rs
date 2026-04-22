use shadow_sdk::{
    services::clipboard::write_text as write_clipboard_text,
    services::nostr::{
        generate_account, import_account_nsec, publish, sync, NostrEvent,
        NostrPublicKeyReference, NostrPublishReceipt, NostrPublishRequest, NostrQuery,
        NostrSyncRequest,
    },
    ui::{with_task, TaskHandle, TaskSlot, WidgetView},
};

use crate::{
    empty_feed_status, load_cached_notes, load_contact_references_for_npub, load_explore_notes,
    load_feed_scope_for_npub, log_preview_text, plural_suffix, short_id, socket_available,
    thread_parent_ids, ActiveAccount, FeedScope, FeedSource, Route, TimelineApp, TimelineStatus,
    Tone, APP_LOG_PREFIX,
};

#[derive(Clone, Copy, Debug)]
pub(crate) enum RefreshSource {
    Startup,
    Manual,
    FollowUpdate,
}

#[derive(Clone, Debug)]
pub(crate) struct PendingRefresh {
    pub(crate) account_npub: String,
    pub(crate) limit: usize,
    pub(crate) relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct PendingExploreSync {
    pub(crate) limit: usize,
    pub(crate) relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct PendingThreadSync {
    pub(crate) note_id: String,
    pub(crate) parent_ids: Vec<String>,
    pub(crate) relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) enum AccountActionKind {
    Generate,
    Import { nsec: String },
}

#[derive(Clone, Debug)]
pub(crate) struct PendingAccountAction {
    pub(crate) kind: AccountActionKind,
}

#[derive(Clone, Debug)]
pub(crate) struct PendingClipboardWrite {
    pub(crate) text: String,
}

#[derive(Clone, Debug)]
pub(crate) enum FollowActionKind {
    Add { npub: String },
    Remove { npub: String },
}

#[derive(Clone, Debug)]
pub(crate) struct PendingFollowUpdate {
    pub(crate) account_npub: String,
    pub(crate) action: FollowActionKind,
    pub(crate) relay_urls: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct PendingPublish {
    pub(crate) content: String,
    pub(crate) note_id: String,
    pub(crate) relay_urls: Vec<String>,
    pub(crate) reply_to_event_id: String,
    pub(crate) root_event_id: Option<String>,
}

#[derive(Debug)]
pub(crate) struct RefreshOutcome {
    pub(crate) feed_scope: FeedScope,
    pub(crate) fetched_count: usize,
    pub(crate) imported_count: usize,
    pub(crate) notes: Vec<NostrEvent>,
}

#[derive(Debug)]
pub(crate) struct ExploreSyncOutcome {
    pub(crate) fetched_count: usize,
    pub(crate) imported_count: usize,
}

#[derive(Debug)]
pub(crate) struct ThreadSyncOutcome {
    pub(crate) fetched_count: usize,
    pub(crate) imported_count: usize,
}

#[derive(Debug)]
pub(crate) struct PublishOutcome {
    pub(crate) receipt: NostrPublishReceipt,
}

#[derive(Debug)]
pub(crate) struct FollowUpdateOutcome {
    pub(crate) receipt: NostrPublishReceipt,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct TimelineTasks {
    account_action: TaskSlot<PendingAccountAction>,
    clipboard_write: TaskSlot<PendingClipboardWrite>,
    explore_sync: TaskSlot<PendingExploreSync>,
    follow_update: TaskSlot<PendingFollowUpdate>,
    publish: TaskSlot<PendingPublish>,
    refresh: TaskSlot<PendingRefresh>,
    thread_sync: TaskSlot<PendingThreadSync>,
}

#[derive(Clone, Debug)]
pub(crate) struct TimelineTaskSnapshot {
    account_action: Option<TaskHandle<PendingAccountAction>>,
    clipboard_write: Option<TaskHandle<PendingClipboardWrite>>,
    explore_sync: Option<TaskHandle<PendingExploreSync>>,
    follow_update: Option<TaskHandle<PendingFollowUpdate>>,
    publish: Option<TaskHandle<PendingPublish>>,
    refresh: Option<TaskHandle<PendingRefresh>>,
    thread_sync: Option<TaskHandle<PendingThreadSync>>,
}

impl TimelineTasks {
    pub(crate) fn snapshot(&self) -> TimelineTaskSnapshot {
        TimelineTaskSnapshot {
            account_action: self.account_action.pending_cloned(),
            clipboard_write: self.clipboard_write.pending_cloned(),
            explore_sync: self.explore_sync.pending_cloned(),
            follow_update: self.follow_update.pending_cloned(),
            publish: self.publish.pending_cloned(),
            refresh: self.refresh.pending_cloned(),
            thread_sync: self.thread_sync.pending_cloned(),
        }
    }

    pub(crate) fn publish_pending(&self) -> bool {
        self.publish.is_pending()
    }

    pub(crate) fn follow_update_pending_for(&self, pubkey: &str) -> bool {
        self.follow_update
            .pending()
            .is_some_and(|pending| match &pending.job().action {
                FollowActionKind::Add { npub } | FollowActionKind::Remove { npub } => {
                    npub == pubkey
                }
            })
    }
}

impl TimelineTaskSnapshot {
    pub(crate) fn account_action_pending(&self) -> bool {
        self.account_action.is_some()
    }

    pub(crate) fn clipboard_write_pending(&self) -> bool {
        self.clipboard_write.is_some()
    }

    pub(crate) fn explore_sync_pending(&self) -> bool {
        self.explore_sync.is_some()
    }

    pub(crate) fn follow_update_pending(&self) -> bool {
        self.follow_update.is_some()
    }

    pub(crate) fn publish_pending_for(&self, note_id: &str) -> bool {
        self.publish
            .as_ref()
            .is_some_and(|job| job.job().note_id == note_id)
    }

    pub(crate) fn thread_sync_pending_for(&self, note_id: &str) -> bool {
        self.thread_sync
            .as_ref()
            .is_some_and(|job| job.job().note_id == note_id)
    }
}

pub(crate) fn decorate_with_tasks(
    content: impl WidgetView<TimelineApp>,
    tasks: TimelineTaskSnapshot,
) -> impl WidgetView<TimelineApp> {
    let content = with_task(
        content,
        tasks.account_action,
        run_account_action,
        |app: &mut TimelineApp, task: TaskHandle<PendingAccountAction>, result| {
            app.finish_account_action(task, result);
        },
    );
    let content = with_task(
        content,
        tasks.clipboard_write,
        run_clipboard_write,
        |app: &mut TimelineApp, task: TaskHandle<PendingClipboardWrite>, result| {
            app.finish_clipboard_write(task, result);
        },
    );
    let content = with_task(
        content,
        tasks.explore_sync,
        sync_explore_notes,
        |app: &mut TimelineApp, task: TaskHandle<PendingExploreSync>, result| {
            app.finish_explore_sync(task, result);
        },
    );
    let content = with_task(
        content,
        tasks.follow_update,
        run_follow_update,
        |app: &mut TimelineApp, task: TaskHandle<PendingFollowUpdate>, result| {
            app.finish_follow_update(task, result);
        },
    );
    let content = with_task(
        content,
        tasks.thread_sync,
        sync_thread_context,
        |app: &mut TimelineApp, task: TaskHandle<PendingThreadSync>, result| {
            app.finish_thread_sync(task, result);
        },
    );
    let content = with_task(
        content,
        tasks.publish,
        run_reply_publish,
        |app: &mut TimelineApp, task: TaskHandle<PendingPublish>, result| {
            app.finish_publish(task, result);
        },
    );

    with_task(
        content,
        tasks.refresh,
        sync_notes,
        |app: &mut TimelineApp, task: TaskHandle<PendingRefresh>, result| {
            app.finish_refresh(task, result);
        },
    )
}

impl TimelineApp {
    pub(crate) fn begin_refresh(&mut self, source: RefreshSource) {
        let Some(account) = self.account.as_ref() else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Set up an account before refreshing the timeline."),
            };
            return;
        };
        if self.tasks.refresh.is_pending() {
            return;
        }
        self.tasks.refresh.start(PendingRefresh {
            account_npub: account.npub.clone(),
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

    pub(crate) fn begin_explore_sync(&mut self) {
        if self.tasks.explore_sync.is_pending() {
            return;
        }
        self.tasks.explore_sync.start(PendingExploreSync {
            limit: self.config.limit.max(24),
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Fetching recent relay notes for Explore..."),
        };
    }

    pub(crate) fn begin_account_generate(&mut self) {
        if self.tasks.account_action.is_pending() {
            return;
        }
        self.tasks.account_action.start(PendingAccountAction {
            kind: AccountActionKind::Generate,
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Generating a new Nostr account..."),
        };
    }

    pub(crate) fn begin_account_import(&mut self) {
        if self.tasks.account_action.is_pending() {
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
        self.tasks.account_action.start(PendingAccountAction {
            kind: AccountActionKind::Import {
                nsec: nsec.to_owned(),
            },
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Importing the Nostr account from nsec..."),
        };
    }

    pub(crate) fn begin_thread_sync(&mut self, note_id: String) {
        if self.tasks.thread_sync.is_pending() {
            return;
        }
        let Some(note) = self.cached_note_by_id(&note_id) else {
            return;
        };
        self.tasks.thread_sync.start(PendingThreadSync {
            note_id,
            parent_ids: thread_parent_ids(&note),
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Pulling thread context from relays..."),
        };
    }

    pub(crate) fn begin_copy_account_npub(&mut self) {
        if self.tasks.clipboard_write.is_pending() {
            return;
        }
        let Some(account) = self.account.as_ref() else {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("No active account is available to copy."),
            };
            return;
        };
        self.tasks.clipboard_write.start(PendingClipboardWrite {
            text: account.npub.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Copying the active npub to the clipboard..."),
        };
    }

    pub(crate) fn begin_follow_add(&mut self) {
        let npub = self.follow_input.trim().to_owned();
        self.begin_follow_add_for(npub);
    }

    pub(crate) fn begin_follow_add_for(&mut self, npub: String) {
        if self.tasks.follow_update.is_pending() {
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
        self.tasks.follow_update.start(PendingFollowUpdate {
            account_npub: account.npub.clone(),
            action: FollowActionKind::Add { npub },
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Updating the shared contact list..."),
        };
    }

    pub(crate) fn begin_follow_remove(&mut self, npub: String) {
        if self.tasks.follow_update.is_pending() {
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
        self.tasks.follow_update.start(PendingFollowUpdate {
            account_npub: account.npub.clone(),
            action: FollowActionKind::Remove { npub },
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Updating the shared contact list..."),
        };
    }

    pub(crate) fn begin_reply_publish(&mut self) {
        if self.tasks.publish.is_pending() {
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
        self.tasks.publish.start(PendingPublish {
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

    pub(crate) fn follow_update_pending_for(&self, pubkey: &str) -> bool {
        self.tasks.follow_update_pending_for(pubkey)
    }

    pub(crate) fn finish_refresh(
        &mut self,
        task: TaskHandle<PendingRefresh>,
        result: Result<RefreshOutcome, String>,
    ) {
        if self.tasks.refresh.finish(task.id()).is_none() {
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

    pub(crate) fn finish_explore_sync(
        &mut self,
        task: TaskHandle<PendingExploreSync>,
        result: Result<ExploreSyncOutcome, String>,
    ) {
        if self.tasks.explore_sync.finish(task.id()).is_none() {
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

    pub(crate) fn finish_thread_sync(
        &mut self,
        task: TaskHandle<PendingThreadSync>,
        result: Result<ThreadSyncOutcome, String>,
    ) {
        if self.tasks.thread_sync.finish(task.id()).is_none() {
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
                eprintln!("{APP_LOG_PREFIX}: thread_sync_error={message}");
                self.status = TimelineStatus {
                    tone: Tone::Danger,
                    message,
                };
            }
        }
    }

    pub(crate) fn finish_account_action(
        &mut self,
        task: TaskHandle<PendingAccountAction>,
        result: Result<ActiveAccount, String>,
    ) {
        if self.tasks.account_action.finish(task.id()).is_none() {
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

    pub(crate) fn finish_clipboard_write(
        &mut self,
        task: TaskHandle<PendingClipboardWrite>,
        result: Result<(), String>,
    ) {
        if self.tasks.clipboard_write.finish(task.id()).is_none() {
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

    pub(crate) fn finish_follow_update(
        &mut self,
        task: TaskHandle<PendingFollowUpdate>,
        result: Result<FollowUpdateOutcome, String>,
    ) {
        let Some(pending) = self.tasks.follow_update.finish(task.id()) else {
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

    pub(crate) fn finish_publish(
        &mut self,
        task: TaskHandle<PendingPublish>,
        result: Result<PublishOutcome, String>,
    ) {
        let Some(pending) = self.tasks.publish.finish(task.id()) else {
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
