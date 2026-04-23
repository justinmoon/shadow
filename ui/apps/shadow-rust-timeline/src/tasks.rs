mod finish;
mod start;

use shadow_sdk::{
    services::{
        clipboard::{run_write_text_task, ClipboardWriteRequest},
        nostr::{
            run_account_task,
            timeline::{
                publish_note_or_reply, run_refresh_home_feed_task, run_sync_explore_feed_task,
                run_sync_thread_task, run_update_contact_list_task, NostrContactListUpdateAction,
                NostrContactListUpdateOutcome, NostrContactListUpdateRequest,
                NostrExploreSyncOutcome, NostrExploreSyncRequest, NostrHomeRefreshOutcome,
                NostrHomeRefreshRequest, NostrThreadSyncOutcome, NostrThreadSyncRequest,
                NostrTimelinePublishRequest,
            },
            NostrAccountSummary, NostrAccountTask, NostrPublishReceipt,
        },
    },
    ui::{with_tasks, TaskGroupSnapshot, TaskHandle, TaskSlotBinding, WidgetView},
};

use crate::TimelineApp;

#[derive(Clone, Copy, Debug)]
pub(crate) enum RefreshSource {
    Startup,
    Manual,
    FollowUpdate,
}

pub(crate) type FollowActionKind = NostrContactListUpdateAction;
pub(crate) type RefreshOutcome = NostrHomeRefreshOutcome;
pub(crate) type ExploreSyncOutcome = NostrExploreSyncOutcome;
pub(crate) type ThreadSyncOutcome = NostrThreadSyncOutcome;
pub(crate) type FollowUpdateOutcome = NostrContactListUpdateOutcome;
pub(crate) type PublishOutcome = NostrPublishReceipt;
pub(crate) type AccountActionOutcome = NostrAccountSummary;

type TimelineTask<Job, Output> = TaskSlotBinding<TimelineApp, Job, Output>;

#[derive(Clone, Debug)]
pub(crate) struct TimelineTasks {
    pub(crate) account_action: TimelineTask<NostrAccountTask, AccountActionOutcome>,
    pub(crate) clipboard_write: TimelineTask<ClipboardWriteRequest, ()>,
    pub(crate) explore_sync: TimelineTask<NostrExploreSyncRequest, ExploreSyncOutcome>,
    pub(crate) follow_update: TimelineTask<NostrContactListUpdateRequest, FollowUpdateOutcome>,
    pub(crate) publish: TimelineTask<NostrTimelinePublishRequest, PublishOutcome>,
    pub(crate) refresh: TimelineTask<NostrHomeRefreshRequest, RefreshOutcome>,
    pub(crate) thread_sync: TimelineTask<NostrThreadSyncRequest, ThreadSyncOutcome>,
}

impl Default for TimelineTasks {
    fn default() -> Self {
        Self {
            account_action: TimelineTask::new(run_account_task, TimelineApp::finish_account_action),
            clipboard_write: TimelineTask::new(
                run_write_text_task,
                TimelineApp::finish_clipboard_write,
            ),
            explore_sync: TimelineTask::new(
                run_sync_explore_feed_task,
                TimelineApp::finish_explore_sync,
            ),
            follow_update: TimelineTask::new(
                run_update_contact_list_task,
                TimelineApp::finish_follow_update,
            ),
            publish: TimelineTask::new(run_publish, TimelineApp::finish_publish),
            refresh: TimelineTask::new(run_refresh_home_feed_task, TimelineApp::finish_refresh),
            thread_sync: TimelineTask::new(run_sync_thread_task, TimelineApp::finish_thread_sync),
        }
    }
}

impl TimelineTasks {
    pub(crate) fn start_refresh(
        &mut self,
        account_npub: String,
        limit: usize,
        relay_urls: Vec<String>,
    ) -> bool {
        self.refresh.start(NostrHomeRefreshRequest {
            account_npub,
            limit,
            relay_urls,
        })
    }

    pub(crate) fn start_explore_sync(&mut self, limit: usize, relay_urls: Vec<String>) -> bool {
        self.explore_sync
            .start(NostrExploreSyncRequest { limit, relay_urls })
    }

    pub(crate) fn start_account_generate(&mut self) -> bool {
        self.account_action.start(NostrAccountTask::generate())
    }

    pub(crate) fn start_account_import(&mut self, nsec: String) -> bool {
        self.account_action.start(NostrAccountTask::import(nsec))
    }

    pub(crate) fn start_thread_sync(
        &mut self,
        note_id: String,
        parent_ids: Vec<String>,
        relay_urls: Vec<String>,
    ) -> bool {
        self.thread_sync.start(NostrThreadSyncRequest {
            note_id,
            parent_ids,
            relay_urls,
        })
    }

    pub(crate) fn start_clipboard_write(&mut self, text: String) -> bool {
        self.clipboard_write.start(ClipboardWriteRequest::new(text))
    }

    pub(crate) fn start_follow_add(
        &mut self,
        account_npub: String,
        npub: String,
        relay_urls: Vec<String>,
    ) -> bool {
        self.start_follow_update(account_npub, FollowActionKind::Add { npub }, relay_urls)
    }

    pub(crate) fn start_follow_remove(
        &mut self,
        account_npub: String,
        npub: String,
        relay_urls: Vec<String>,
    ) -> bool {
        self.start_follow_update(account_npub, FollowActionKind::Remove { npub }, relay_urls)
    }

    fn start_follow_update(
        &mut self,
        account_npub: String,
        action: FollowActionKind,
        relay_urls: Vec<String>,
    ) -> bool {
        self.follow_update.start(NostrContactListUpdateRequest {
            account_npub,
            action,
            relay_urls,
        })
    }

    pub(crate) fn start_reply_publish(
        &mut self,
        content: String,
        relay_urls: Vec<String>,
        reply_to_event_id: String,
        root_event_id: Option<String>,
    ) -> bool {
        self.publish.start(NostrTimelinePublishRequest::reply(
            content,
            relay_urls,
            reply_to_event_id,
            root_event_id,
        ))
    }

    pub(crate) fn start_note_publish(&mut self, content: String, relay_urls: Vec<String>) -> bool {
        self.publish
            .start(NostrTimelinePublishRequest::note(content, relay_urls))
    }

    pub(crate) fn finish_refresh(&mut self, task: TaskHandle<NostrHomeRefreshRequest>) -> bool {
        self.refresh.finish_matches(task)
    }

    pub(crate) fn finish_explore_sync(
        &mut self,
        task: TaskHandle<NostrExploreSyncRequest>,
    ) -> bool {
        self.explore_sync.finish_matches(task)
    }

    pub(crate) fn finish_account_action(&mut self, task: TaskHandle<NostrAccountTask>) -> bool {
        self.account_action.finish_matches(task)
    }

    pub(crate) fn finish_thread_sync(&mut self, task: TaskHandle<NostrThreadSyncRequest>) -> bool {
        self.thread_sync.finish_matches(task)
    }

    pub(crate) fn finish_clipboard_write(
        &mut self,
        task: TaskHandle<ClipboardWriteRequest>,
    ) -> bool {
        self.clipboard_write.finish_matches(task)
    }

    pub(crate) fn finish_follow_update(
        &mut self,
        task: TaskHandle<NostrContactListUpdateRequest>,
    ) -> Option<NostrContactListUpdateRequest> {
        self.follow_update.finish(task)
    }

    pub(crate) fn finish_publish(
        &mut self,
        task: TaskHandle<NostrTimelinePublishRequest>,
    ) -> Option<NostrTimelinePublishRequest> {
        self.publish.finish(task)
    }
}

pub(crate) fn decorate_with_tasks(
    content: impl WidgetView<TimelineApp>,
    tasks: &TimelineTasks,
) -> impl WidgetView<TimelineApp> {
    let (
        account_action,
        clipboard_write,
        explore_sync,
        follow_update,
        thread_sync,
        publish,
        refresh,
    ) = (
        &tasks.account_action,
        &tasks.clipboard_write,
        &tasks.explore_sync,
        &tasks.follow_update,
        &tasks.thread_sync,
        &tasks.publish,
        &tasks.refresh,
    )
        .snapshot_group();

    with_tasks(
        content,
        [
            account_action.decoration(),
            clipboard_write.decoration(),
            explore_sync.decoration(),
            follow_update.decoration(),
            thread_sync.decoration(),
            publish.decoration(),
            refresh.decoration(),
        ],
    )
}

fn run_publish(job: NostrTimelinePublishRequest) -> Result<PublishOutcome, String> {
    publish_note_or_reply(job).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use shadow_sdk::services::nostr::timeline::NostrTimelinePublishRequest;

    use super::TimelineTasks;

    fn follow_update_target(
        job: &shadow_sdk::services::nostr::timeline::NostrContactListUpdateRequest,
    ) -> &str {
        match &job.action {
            super::FollowActionKind::Add { npub } | super::FollowActionKind::Remove { npub } => {
                npub
            }
        }
    }

    #[test]
    fn refresh_start_builds_pending_request() {
        let mut tasks = TimelineTasks::default();
        assert!(tasks.start_refresh(
            String::from("npub-account"),
            42,
            vec![String::from("wss://relay.example")],
        ));

        let pending = tasks.refresh.pending().expect("pending refresh").job();
        assert_eq!(pending.account_npub, "npub-account");
        assert_eq!(pending.limit, 42);
        assert_eq!(
            pending.relay_urls,
            vec![String::from("wss://relay.example")]
        );
    }

    #[test]
    fn follow_update_helpers_track_pending_target() {
        let mut tasks = TimelineTasks::default();
        assert!(tasks.start_follow_add(
            String::from("npub-account"),
            String::from("npub-target"),
            Vec::new(),
        ));

        assert_eq!(
            tasks.follow_update.pending_job().map(follow_update_target),
            Some("npub-target")
        );
        assert!(
            tasks
                .follow_update
                .pending_matches(|job| follow_update_target(job) == "npub-target")
        );
        assert!(
            !tasks
                .follow_update
                .pending_matches(|job| follow_update_target(job) == "npub-other")
        );
    }

    #[test]
    fn refresh_finish_helper_clears_matching_pending_task() {
        let mut tasks = TimelineTasks::default();
        assert!(tasks.start_refresh(String::from("npub-account"), 42, Vec::new()));

        let pending = tasks.refresh.pending_cloned().expect("pending refresh");
        assert!(tasks.finish_refresh(pending));
        assert!(!tasks.refresh.is_pending());
    }

    #[test]
    fn follow_update_finish_returns_matching_pending_job() {
        let mut tasks = TimelineTasks::default();
        assert!(tasks.start_follow_remove(
            String::from("npub-account"),
            String::from("npub-target"),
            vec![String::from("wss://relay.example")],
        ));

        let pending = tasks
            .follow_update
            .pending_cloned()
            .expect("pending follow update");
        let finished = tasks
            .finish_follow_update(pending)
            .expect("matching finished follow update");

        assert_eq!(follow_update_target(&finished), "npub-target");
        assert!(!tasks.follow_update.is_pending());
    }

    #[test]
    fn publish_start_helpers_build_note_and_reply_requests() {
        let mut note_tasks = TimelineTasks::default();
        assert!(note_tasks.start_note_publish(
            String::from("hello"),
            vec![String::from("wss://relay.example")],
        ));
        assert!(note_tasks.publish.pending_matches(|job| job.is_note()));
        let note = note_tasks
            .publish
            .pending()
            .expect("pending note publish")
            .job();
        assert!(note.is_note());
        assert_eq!(note.content(), "hello");

        let mut reply_tasks = TimelineTasks::default();
        assert!(reply_tasks.start_reply_publish(
            String::from("reply"),
            vec![String::from("wss://relay.example")],
            String::from("note-1"),
            Some(String::from("root-1")),
        ));
        assert!(!reply_tasks.publish.pending_matches(|job| job.is_note()));
        assert!(reply_tasks.publish.pending_matches(|job| job.is_reply_to("note-1")));

        match reply_tasks
            .publish
            .pending()
            .expect("pending reply publish")
            .job()
        {
            NostrTimelinePublishRequest::Reply(request) => {
                assert_eq!(request.reply_to_event_id, "note-1");
                assert_eq!(request.root_event_id.as_deref(), Some("root-1"));
                assert_eq!(request.content, "reply");
            }
            NostrTimelinePublishRequest::Note(_) => panic!("expected reply request"),
        }
    }
}
