use std::sync::atomic::{AtomicU64, Ordering};

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
        self.pending.clone()
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
    use super::TaskSlot;

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
}
