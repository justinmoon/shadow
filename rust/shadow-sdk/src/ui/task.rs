use std::{
    fmt::Debug,
    sync::atomic::{AtomicU64, Ordering},
};

use xilem::{AnyWidgetView, WidgetView};

use super::widgets::task_decoration;

type TaskDecorationFn<State> =
    dyn FnOnce(Box<AnyWidgetView<State>>) -> Box<AnyWidgetView<State>> + Send + Sync;
type TaskDecorationFactory<State, Registry> = fn(&Registry) -> TaskDecoration<State>;
type TaskRunFn<Job, Output> = fn(Job) -> Result<Output, String>;
type TaskApplyFn<State, Job, Output> = fn(&mut State, TaskHandle<Job>, Result<Output, String>);

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

#[derive(Clone, Copy)]
pub struct TaskDecorationRegistry<State, Registry, const N: usize> {
    decorate: [TaskDecorationFactory<State, Registry>; N],
}

impl<State, Registry, const N: usize> TaskDecorationRegistry<State, Registry, N> {
    pub const fn new(decorate: [TaskDecorationFactory<State, Registry>; N]) -> Self {
        Self { decorate }
    }

    pub fn apply(
        &self,
        content: impl WidgetView<State>,
        registry: &Registry,
    ) -> Box<AnyWidgetView<State>>
    where
        State: Send + Sync + 'static,
    {
        apply_task_decorations(
            content,
            self.decorate.iter().map(|decorate| decorate(registry)),
        )
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

    pub fn finish_handle(&mut self, task: TaskHandle<Job>) -> Option<Job> {
        self.finish(task.id())
    }

    pub fn finish_matches(&mut self, task: &TaskHandle<Job>) -> bool {
        self.finish(task.id()).is_some()
    }

    pub fn decoration<State, Output>(
        &self,
        run: impl Fn(Job) -> Result<Output, String> + Clone + Send + Sync + 'static,
        apply: impl Fn(&mut State, TaskHandle<Job>, Result<Output, String>)
            + Clone
            + Send
            + Sync
            + 'static,
    ) -> TaskDecoration<State>
    where
        State: Send + Sync + 'static,
        Job: Clone + Send + Sync + 'static,
        Output: Debug + Send + 'static,
    {
        task_decoration(self.pending_cloned(), run, apply)
    }
}

#[derive(Debug)]
pub struct TaskSlotBinding<State, Job, Output> {
    slot: TaskSlot<Job>,
    run: TaskRunFn<Job, Output>,
    apply: TaskApplyFn<State, Job, Output>,
}

impl<State, Job, Output> Clone for TaskSlotBinding<State, Job, Output>
where
    Job: Clone,
{
    fn clone(&self) -> Self {
        Self {
            slot: self.slot.clone(),
            run: self.run,
            apply: self.apply,
        }
    }
}

impl<State, Job, Output> TaskSlotBinding<State, Job, Output> {
    pub const fn new(run: TaskRunFn<Job, Output>, apply: TaskApplyFn<State, Job, Output>) -> Self {
        Self {
            slot: TaskSlot::new(),
            run,
            apply,
        }
    }

    pub const fn is_pending(&self) -> bool {
        self.slot.is_pending()
    }

    pub fn pending(&self) -> Option<&TaskHandle<Job>> {
        self.slot.pending()
    }

    pub fn pending_cloned(&self) -> Option<TaskHandle<Job>>
    where
        Job: Clone,
    {
        self.slot.pending_cloned()
    }

    pub fn pending_matches(&self, select: impl FnOnce(&Job) -> bool) -> bool {
        self.slot.pending_matches(select)
    }

    pub fn snapshot(&self) -> TaskSnapshot<Job>
    where
        Job: Clone,
    {
        self.slot.snapshot()
    }

    pub fn start(&mut self, job: Job) -> bool {
        self.slot.start(job)
    }

    pub fn finish(&mut self, task: TaskHandle<Job>) -> Option<Job> {
        self.slot.finish_handle(task)
    }

    pub fn finish_matches(&mut self, task: TaskHandle<Job>) -> bool {
        self.slot.finish_matches(&task)
    }

    pub fn decoration(&self) -> TaskDecoration<State>
    where
        State: Send + Sync + 'static,
        Job: Clone + Send + Sync + 'static,
        Output: Debug + Send + 'static,
    {
        self.slot.decoration(self.run, self.apply)
    }
}

fn next_task_id() -> u64 {
    static NEXT_TASK_ID: AtomicU64 = AtomicU64::new(1);
    NEXT_TASK_ID.fetch_add(1, Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use xilem::view::label;

    use super::{TaskDecoration, TaskDecorationRegistry, TaskSlot, TaskSlotBinding, TaskSnapshot};

    fn run_bound_task(job: String) -> Result<usize, String> {
        if job == "error" {
            return Err(String::from("error"));
        }
        Ok(job.len())
    }

    fn apply_bound_task(
        _state: &mut (),
        _task: super::TaskHandle<String>,
        _result: Result<usize, String>,
    ) {
    }

    #[test]
    fn task_decoration_registry_invokes_factories_in_order() {
        struct Registry {
            visited: Arc<Mutex<Vec<&'static str>>>,
        }

        fn first(registry: &Registry) -> TaskDecoration<()> {
            registry
                .visited
                .lock()
                .expect("first visit lock")
                .push("first");
            TaskDecoration::new(|content| content)
        }

        fn second(registry: &Registry) -> TaskDecoration<()> {
            registry
                .visited
                .lock()
                .expect("second visit lock")
                .push("second");
            TaskDecoration::new(|content| content)
        }

        let visited = Arc::new(Mutex::new(Vec::new()));
        let registry = Registry {
            visited: Arc::clone(&visited),
        };
        let decorations = TaskDecorationRegistry::new([first, second]);

        let _ = decorations.apply(label("content"), &registry);

        assert_eq!(
            visited.lock().expect("visited lock").as_slice(),
            ["first", "second"]
        );
    }

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
    fn task_slot_can_finish_by_handle() {
        let mut slot = TaskSlot::new();
        assert!(slot.start(String::from("job")));

        let pending = slot.pending_cloned().expect("pending task");

        assert_eq!(slot.finish_handle(pending), Some(String::from("job")));
        assert!(!slot.is_pending());
    }

    #[test]
    fn task_slot_binding_can_finish_matching_handle_as_bool() {
        let mut slot = TaskSlotBinding::new(run_bound_task, apply_bound_task);
        assert!(slot.start(String::from("job")));

        let pending = slot.pending_cloned().expect("pending task");

        assert!(slot.finish_matches(pending));
        assert!(!slot.is_pending());
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

    #[test]
    fn task_slot_binding_delegates_to_bound_slot() {
        let mut slot = TaskSlotBinding::new(run_bound_task, apply_bound_task);

        assert!(slot.start(String::from("note")));
        assert!(slot.is_pending());
        assert!(slot.pending_matches(|job| job == "note"));
        assert_eq!(
            slot.pending().map(|pending| pending.job().as_str()),
            Some("note")
        );

        let pending = slot.pending_cloned().expect("pending task");
        assert_eq!(slot.finish(pending), Some(String::from("note")));
        assert!(!slot.is_pending());
    }
}
