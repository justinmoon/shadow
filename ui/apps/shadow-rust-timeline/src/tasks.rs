mod finish;
mod start;

use shadow_sdk::{
    services::{
        clipboard::{run_write_text_task, ClipboardWriteRequest},
        nostr::{
            run_account_task,
            timeline::{
                publish_note_or_reply, run_refresh_home_feed_task, run_sync_explore_feed_task,
                run_sync_thread_task, run_update_contact_list_task,
                NostrContactListUpdateAction, NostrContactListUpdateOutcome,
                NostrContactListUpdateRequest, NostrExploreSyncOutcome, NostrExploreSyncRequest,
                NostrHomeRefreshOutcome, NostrHomeRefreshRequest, NostrThreadSyncOutcome,
                NostrThreadSyncRequest, NostrTimelinePublishRequest,
            },
            NostrAccountSummary, NostrAccountTask, NostrPublishReceipt,
        },
    },
    ui::{task_decoration, with_tasks, TaskHandle, TaskSlot, TaskSnapshot, WidgetView},
};

use crate::TimelineApp;

#[derive(Clone, Copy, Debug)]
pub(crate) enum RefreshSource {
    Startup,
    Manual,
    FollowUpdate,
}

pub(crate) type PendingRefresh = NostrHomeRefreshRequest;
pub(crate) type PendingExploreSync = NostrExploreSyncRequest;
pub(crate) type PendingThreadSync = NostrThreadSyncRequest;
pub(crate) type FollowActionKind = NostrContactListUpdateAction;
pub(crate) type PendingFollowUpdate = NostrContactListUpdateRequest;
pub(crate) type RefreshOutcome = NostrHomeRefreshOutcome;
pub(crate) type ExploreSyncOutcome = NostrExploreSyncOutcome;
pub(crate) type ThreadSyncOutcome = NostrThreadSyncOutcome;
pub(crate) type FollowUpdateOutcome = NostrContactListUpdateOutcome;
pub(crate) type PendingPublish = NostrTimelinePublishRequest;
pub(crate) type PublishOutcome = NostrPublishReceipt;
pub(crate) type AccountActionOutcome = NostrAccountSummary;
pub(crate) type PendingAccountAction = NostrAccountTask;
pub(crate) type PendingClipboardWrite = ClipboardWriteRequest;

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
    pub(crate) account_action: TaskSnapshot<PendingAccountAction>,
    pub(crate) clipboard_write: TaskSnapshot<PendingClipboardWrite>,
    pub(crate) explore_sync: TaskSnapshot<PendingExploreSync>,
    pub(crate) follow_update: TaskSnapshot<PendingFollowUpdate>,
    pub(crate) publish: TaskSnapshot<PendingPublish>,
    pub(crate) refresh: TaskSnapshot<PendingRefresh>,
    pub(crate) thread_sync: TaskSnapshot<PendingThreadSync>,
}

impl TimelineTasks {
    pub(crate) fn snapshot(&self) -> TimelineTaskSnapshot {
        TimelineTaskSnapshot {
            account_action: self.account_action.snapshot(),
            clipboard_write: self.clipboard_write.snapshot(),
            explore_sync: self.explore_sync.snapshot(),
            follow_update: self.follow_update.snapshot(),
            publish: self.publish.snapshot(),
            refresh: self.refresh.snapshot(),
            thread_sync: self.thread_sync.snapshot(),
        }
    }

    pub(crate) fn account_action_pending(&self) -> bool {
        self.account_action.is_pending()
    }

    pub(crate) fn clipboard_write_pending(&self) -> bool {
        self.clipboard_write.is_pending()
    }

    pub(crate) fn explore_sync_pending(&self) -> bool {
        self.explore_sync.is_pending()
    }

    pub(crate) fn pending_follow_update_target(&self) -> Option<&str> {
        self.follow_update
            .pending()
            .map(|pending| follow_update_target(pending.job()))
    }

    pub(crate) fn publish_pending(&self) -> bool {
        self.publish.is_pending()
    }

    pub(crate) fn publish_note_pending(&self) -> bool {
        self.publish.pending_matches(PendingPublish::is_note)
    }

    pub(crate) fn publish_reply_pending_for(&self, note_id: &str) -> bool {
        self.publish.pending_matches(|job| job.is_reply_to(note_id))
    }

    pub(crate) fn follow_update_pending_for(&self, pubkey: &str) -> bool {
        self.follow_update
            .pending_matches(|job| follow_update_target(job) == pubkey)
    }

    pub(crate) fn thread_sync_pending_for(&self, note_id: &str) -> bool {
        self.thread_sync
            .pending_matches(|job| job.note_id == note_id)
    }
}

pub(crate) fn decorate_with_tasks(
    content: impl WidgetView<TimelineApp>,
    tasks: TimelineTaskSnapshot,
) -> impl WidgetView<TimelineApp> {
    let TimelineTaskSnapshot {
        account_action,
        clipboard_write,
        explore_sync,
        follow_update,
        publish,
        refresh,
        thread_sync,
    } = tasks;
    with_tasks(
        content,
        [
            task_decoration(
                account_action.into_pending(),
                run_account_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingAccountAction>, result| {
                    app.finish_account_action(task, result);
                },
            ),
            task_decoration(
                clipboard_write.into_pending(),
                run_write_text_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingClipboardWrite>, result| {
                    app.finish_clipboard_write(task, result);
                },
            ),
            task_decoration(
                explore_sync.into_pending(),
                run_sync_explore_feed_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingExploreSync>, result| {
                    app.finish_explore_sync(task, result);
                },
            ),
            task_decoration(
                follow_update.into_pending(),
                run_update_contact_list_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingFollowUpdate>, result| {
                    app.finish_follow_update(task, result);
                },
            ),
            task_decoration(
                thread_sync.into_pending(),
                run_sync_thread_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingThreadSync>, result| {
                    app.finish_thread_sync(task, result);
                },
            ),
            task_decoration(
                publish.into_pending(),
                run_publish,
                |app: &mut TimelineApp, task: TaskHandle<PendingPublish>, result| {
                    app.finish_publish(task, result);
                },
            ),
            task_decoration(
                refresh.into_pending(),
                run_refresh_home_feed_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingRefresh>, result| {
                    app.finish_refresh(task, result);
                },
            ),
        ],
    )
}

fn run_publish(job: PendingPublish) -> Result<PublishOutcome, String> {
    publish_note_or_reply(job).map_err(|error| error.to_string())
}

fn follow_update_target(job: &PendingFollowUpdate) -> &str {
    match &job.action {
        FollowActionKind::Add { npub } | FollowActionKind::Remove { npub } => npub,
    }
}

#[cfg(test)]
mod tests {
    use super::{FollowActionKind, PendingFollowUpdate, TimelineTasks};

    #[test]
    fn follow_update_helpers_track_pending_target() {
        let mut tasks = TimelineTasks::default();
        assert!(tasks.follow_update.start(PendingFollowUpdate {
            account_npub: String::from("npub-account"),
            action: FollowActionKind::Add {
                npub: String::from("npub-target"),
            },
            relay_urls: Vec::new(),
        }));

        assert_eq!(tasks.pending_follow_update_target(), Some("npub-target"));
        assert!(tasks.follow_update_pending_for("npub-target"));
        assert!(!tasks.follow_update_pending_for("npub-other"));
    }
}
