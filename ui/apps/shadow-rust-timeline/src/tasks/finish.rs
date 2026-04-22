use shadow_sdk::ui::TaskHandle;

use super::{
    ExploreSyncOutcome, FollowActionKind, FollowUpdateOutcome, PendingAccountAction,
    PendingClipboardWrite, PendingExploreSync, PendingFollowUpdate, PendingPublish,
    PendingPublishRequest, PendingPublishTarget, PendingRefresh, PendingThreadSync, PublishOutcome,
    RefreshOutcome, RefreshSource, ThreadSyncOutcome,
};
use crate::{
    empty_feed_status, log_preview_text, plural_suffix, short_id, FeedScope, FeedSource,
    TimelineApp, TimelineStatus, Tone, APP_LOG_PREFIX,
};

impl TimelineApp {
    pub(crate) fn finish_refresh(
        &mut self,
        task: TaskHandle<PendingRefresh>,
        result: Result<RefreshOutcome, String>,
    ) {
        if self.tasks.refresh.finish(task.id()).is_none() {
            return;
        }

        match result {
            Ok(outcome) => {
                self.feed_scope = FeedScope::from(outcome.feed_scope);
                self.notes = outcome.notes;
                self.invalidate_route_caches();
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
        }

        self.status = match result {
            Ok(outcome) => {
                self.invalidate_route_caches();
                self.sync_routes();
                TimelineStatus {
                    tone: Tone::Success,
                    message: format!(
                        "Explore fetched {} note{}, imported {}.",
                        outcome.fetched_count,
                        plural_suffix(outcome.fetched_count),
                        outcome.imported_count,
                    ),
                }
            }
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
        }
        self.invalidate_route_caches();
        self.sync_routes();

        match result {
            Ok(outcome) => {
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
        result: Result<crate::ActiveAccount, String>,
    ) {
        if self.tasks.account_action.finish(task.id()).is_none() {
            return;
        }

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
                    crate::Route::Timeline
                } else {
                    crate::Route::Explore
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
                if self.config.sync_on_start && crate::socket_available() {
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
        }

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
                        if crate::socket_available() {
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
        let publish_preview = match &pending.request {
            PendingPublishRequest::Note(request) => log_preview_text(&request.content),
            PendingPublishRequest::Reply(request) => log_preview_text(&request.content),
        };

        match result {
            Ok(outcome) => {
                if let Err(error) = self.reload_feed_from_cache() {
                    self.status = TimelineStatus {
                        tone: Tone::Danger,
                        message: error,
                    };
                    return;
                }
                let (publish_label, status_suffix) = match pending.target {
                    PendingPublishTarget::Note => {
                        self.note_draft = None;
                        self.route_stack = vec![crate::Route::Timeline];
                        self.open_note(outcome.receipt.event.id.clone());
                        self.sync_routes();
                        ("note", " Opened the published note.")
                    }
                    PendingPublishTarget::Reply { .. } => {
                        self.reply_draft = None;
                        self.sync_routes();
                        ("reply", "")
                    }
                };
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
                        "Published {publish_label} to {relay_count} relay{}{suffix}.{status_suffix}",
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
