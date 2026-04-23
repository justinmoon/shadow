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
    ui::{task_decoration, with_tasks, TaskHandle, TaskSlot, WidgetView},
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

    pub(crate) fn publish_note_pending(&self) -> bool {
        self.publish
            .pending()
            .is_some_and(|pending| pending.job().is_note())
    }

    pub(crate) fn publish_reply_pending_for(&self, note_id: &str) -> bool {
        self.publish
            .pending()
            .is_some_and(|pending| pending.job().is_reply_to(note_id))
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

    pub(crate) fn publish_pending(&self) -> bool {
        self.publish.is_some()
    }

    pub(crate) fn publish_reply_pending_for(&self, note_id: &str) -> bool {
        self.publish
            .as_ref()
            .is_some_and(|job| job.job().is_reply_to(note_id))
    }

    pub(crate) fn publish_note_pending(&self) -> bool {
        self.publish.as_ref().is_some_and(|job| job.job().is_note())
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
    with_tasks(
        content,
        [
            task_decoration(
                tasks.account_action,
                run_account_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingAccountAction>, result| {
                    app.finish_account_action(task, result);
                },
            ),
            task_decoration(
                tasks.clipboard_write,
                run_write_text_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingClipboardWrite>, result| {
                    app.finish_clipboard_write(task, result);
                },
            ),
            task_decoration(
                tasks.explore_sync,
                run_sync_explore_feed_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingExploreSync>, result| {
                    app.finish_explore_sync(task, result);
                },
            ),
            task_decoration(
                tasks.follow_update,
                run_update_contact_list_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingFollowUpdate>, result| {
                    app.finish_follow_update(task, result);
                },
            ),
            task_decoration(
                tasks.thread_sync,
                run_sync_thread_task,
                |app: &mut TimelineApp, task: TaskHandle<PendingThreadSync>, result| {
                    app.finish_thread_sync(task, result);
                },
            ),
            task_decoration(
                tasks.publish,
                run_publish,
                |app: &mut TimelineApp, task: TaskHandle<PendingPublish>, result| {
                    app.finish_publish(task, result);
                },
            ),
            task_decoration(
                tasks.refresh,
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
