use shadow_sdk::services::{
    clipboard::ClipboardWriteRequest,
    nostr::{
        timeline::{
            thread_parent_ids, NostrContactListUpdateRequest, NostrExploreSyncRequest,
            NostrHomeRefreshRequest, NostrThreadSyncRequest, NostrTimelinePublishRequest,
        },
        NostrAccountTask,
    },
};

use super::{FollowActionKind, RefreshSource};
use crate::{socket_available, TimelineApp, TimelineStatus, Tone};

impl TimelineApp {
    pub(crate) fn account_action_pending(&self) -> bool {
        self.tasks.account_action.is_pending()
    }

    pub(crate) fn clipboard_write_pending(&self) -> bool {
        self.tasks.clipboard_write.is_pending()
    }

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
        self.tasks.refresh.start(NostrHomeRefreshRequest {
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
        self.tasks.explore_sync.start(NostrExploreSyncRequest {
            limit: self.config.limit.max(24),
            relay_urls: self.config.relay_urls.clone(),
        });
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Fetching recent relay notes for Explore..."),
        };
    }

    pub(crate) fn explore_sync_pending(&self) -> bool {
        self.tasks.explore_sync.is_pending()
    }

    pub(crate) fn begin_account_generate(&mut self) {
        if self.tasks.account_action.is_pending() {
            return;
        }
        self.tasks.account_action.start(NostrAccountTask::generate());
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
        self.tasks
            .account_action
            .start(NostrAccountTask::import(nsec.to_owned()));
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
        self.tasks.thread_sync.start(NostrThreadSyncRequest {
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
        self.tasks
            .clipboard_write
            .start(ClipboardWriteRequest::new(account.npub.clone()));
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
        self.tasks.follow_update.start(NostrContactListUpdateRequest {
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
        self.tasks.follow_update.start(NostrContactListUpdateRequest {
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
        self.tasks.publish.start(NostrTimelinePublishRequest::reply(
            content.to_owned(),
            self.config.relay_urls.clone(),
            note.id.clone(),
            note.root_event_id.clone().or_else(|| Some(note.id)),
        ));
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Publishing reply through the shared Nostr account..."),
        };
    }

    pub(crate) fn begin_note_publish(&mut self) {
        if self.tasks.publish.is_pending() {
            return;
        }
        if !matches!(self.current_route(), crate::Route::Timeline) {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Return to Home before publishing the top-level note draft."),
            };
            return;
        }
        if !socket_available() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from(
                    "Publishing notes needs the shared relay engine. Start a session with Nostr services enabled.",
                ),
            };
            return;
        }
        let Some(content) = self.note_draft.clone() else {
            return;
        };
        let content = content.trim();
        if content.is_empty() {
            self.status = TimelineStatus {
                tone: Tone::Danger,
                message: String::from("Write a note before trying to publish."),
            };
            return;
        }
        self.tasks.publish.start(NostrTimelinePublishRequest::note(
            content.to_owned(),
            self.config.relay_urls.clone(),
        ));
        self.status = TimelineStatus {
            tone: Tone::Accent,
            message: String::from("Publishing note through the shared Nostr account..."),
        };
    }

    pub(crate) fn pending_follow_update_target(&self) -> Option<&str> {
        self.tasks.pending_follow_update_target()
    }

    pub(crate) fn publish_pending(&self) -> bool {
        self.tasks.publish.is_pending()
    }

    pub(crate) fn note_publish_pending(&self) -> bool {
        self.tasks.publish_note_pending()
    }

    pub(crate) fn reply_publish_pending_for(&self, note_id: &str) -> bool {
        self.tasks.publish_reply_pending_for(note_id)
    }

    pub(crate) fn thread_sync_pending_for(&self, note_id: &str) -> bool {
        self.tasks.thread_sync_pending_for(note_id)
    }

    pub(crate) fn follow_update_pending_for(&self, pubkey: &str) -> bool {
        self.tasks.follow_update_pending_for(pubkey)
    }
}
