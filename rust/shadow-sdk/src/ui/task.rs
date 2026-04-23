use std::sync::atomic::{AtomicU64, Ordering};

use xilem::{AnyWidgetView, WidgetView};

type TaskDecorationFn<State> =
    dyn FnOnce(Box<AnyWidgetView<State>>) -> Box<AnyWidgetView<State>> + Send + Sync;

// Type-erase heterogeneous task wrappers so apps can apply them as one list.
pub struct TaskDecoration<State> {
    decorate: Box<TaskDecorationFn<State>>,
}

impl<State> TaskDecoration<State> {
    pub fn new(
        decorate: impl FnOnce(Box<AnyWidgetView<State>>) -> Box<AnyWidgetView<State>>
            + Send
            + Sync
            + 'static,
    ) -> Self {
        Self {
            decorate: Box::new(decorate),
        }
    }

    pub fn apply(self, content: Box<AnyWidgetView<State>>) -> Box<AnyWidgetView<State>> {
        (self.decorate)(content)
    }
}

pub fn apply_task_decorations<State>(
    content: impl WidgetView<State>,
    decorations: impl IntoIterator<Item = TaskDecoration<State>>,
) -> Box<AnyWidgetView<State>>
where
    State: Send + Sync + 'static,
{
    decorations
        .into_iter()
        .fold(content.boxed(), |content, decoration| {
            decoration.apply(content)
        })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskHandle<Job> {
    id: u64,
    job: Job,
}

impl<Job> TaskHandle<Job> {
    pub const fn id(&self) -> u64 {
        self.id
    }

    pub const fn job(&self) -> &Job {
        &self.job
    }

    pub fn into_job(self) -> Job {
        self.job
    }
}

#[derive(Clone, Debug, Default)]
pub struct TaskSnapshot<Job> {
    pending: Option<TaskHandle<Job>>,
}

impl<Job> TaskSnapshot<Job> {
    pub fn is_pending(&self) -> bool {
        self.pending.is_some()
    }

    pub fn pending(&self) -> Option<&TaskHandle<Job>> {
        self.pending.as_ref()
    }

    pub fn pending_matches(&self, select: impl FnOnce(&Job) -> bool) -> bool {
        self.pending
            .as_ref()
            .is_some_and(|pending| select(pending.job()))
    }

    pub fn into_pending(self) -> Option<TaskHandle<Job>> {
        self.pending
    }
}

#[derive(Clone, Debug)]
pub struct TaskSlot<Job> {
    pending: Option<TaskHandle<Job>>,
}

impl<Job> Default for TaskSlot<Job> {
    fn default() -> Self {
        Self::new()
    }
}

impl<Job> TaskSlot<Job> {
    pub const fn new() -> Self {
        Self { pending: None }
    }

    pub const fn is_pending(&self) -> bool {
        self.pending.is_some()
    }

    pub fn pending(&self) -> Option<&TaskHandle<Job>> {
        self.pending.as_ref()
    }

    pub fn pending_cloned(&self) -> Option<TaskHandle<Job>>
    where
        Job: Clone,
    {
        self.snapshot().into_pending()
    }

    pub fn pending_matches(&self, select: impl FnOnce(&Job) -> bool) -> bool {
        self.pending
            .as_ref()
            .is_some_and(|pending| select(pending.job()))
    }

    pub fn snapshot(&self) -> TaskSnapshot<Job>
    where
        Job: Clone,
    {
        TaskSnapshot {
            pending: self.pending.clone(),
        }
    }

    pub fn start(&mut self, job: Job) -> bool {
        if self.pending.is_some() {
            return false;
        }
        let handle = TaskHandle {
            id: next_task_id(),
            job,
        };
        self.pending = Some(handle);
        true
    }

    pub fn finish(&mut self, id: u64) -> Option<Job> {
        let matches = self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.id == id);
        if !matches {
            return None;
        }
        self.pending.take().map(TaskHandle::into_job)
    }
}

fn next_task_id() -> u64 {
    static NEXT_TASK_ID: AtomicU64 = AtomicU64::new(1);
    NEXT_TASK_ID.fetch_add(1, Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::{TaskSlot, TaskSnapshot};

    #[test]
    fn task_slot_rejects_overlap_and_finishes_by_id() {
        let mut slot = TaskSlot::new();
        assert!(slot.start(String::from("first")));
        assert!(!slot.start(String::from("second")));
        let pending = slot.pending().expect("pending task");
        let pending_id = pending.id();
        let pending_job = pending.job().clone();
        assert_eq!(pending_job, "first");
        assert_eq!(slot.finish(pending_id + 1), None);
        assert_eq!(slot.finish(pending_id), Some(String::from("first")));
        assert!(!slot.is_pending());
        assert!(slot.start(String::from("second")));
    }

    #[test]
    fn task_slots_of_same_job_type_do_not_collide() {
        let mut first = TaskSlot::new();
        let mut second = TaskSlot::new();

        assert!(first.start(String::from("first")));
        assert!(second.start(String::from("second")));

        let first_id = first.pending().expect("first pending task").id();
        let second_id = second.pending().expect("second pending task").id();

        assert_ne!(first_id, second_id);
        assert_eq!(first.finish(second_id), None);
        assert_eq!(first.finish(first_id), Some(String::from("first")));
        assert_eq!(second.finish(second_id), Some(String::from("second")));
    }

    #[test]
    fn task_snapshots_expose_pending_selectors() {
        let mut slot = TaskSlot::new();
        let empty = slot.snapshot();
        assert!(!empty.is_pending());
        assert_eq!(empty.pending(), None);
        assert!(!empty.pending_matches(|job: &String| job == "note"));

        assert!(slot.start(String::from("note")));

        let snapshot = slot.snapshot();
        assert!(snapshot.is_pending());
        assert_eq!(
            snapshot.pending().map(|pending| pending.job().as_str()),
            Some("note")
        );
        assert!(snapshot.pending_matches(|job| job == "note"));
        assert!(!snapshot.pending_matches(|job| job == "reply"));
        assert!(slot.pending_matches(|job| job == "note"));
        assert!(!slot.pending_matches(|job| job == "reply"));

        let snapshot_handle = snapshot.into_pending().expect("pending task");
        assert_eq!(snapshot_handle.job(), "note");

        let empty_snapshot = TaskSnapshot::<String>::default();
        assert!(!empty_snapshot.is_pending());
    }
}
