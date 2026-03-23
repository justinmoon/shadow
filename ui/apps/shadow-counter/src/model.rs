#![allow(dead_code)]

#[derive(Default)]
pub struct CounterModel {
    count: u64,
    pressed: bool,
}

impl CounterModel {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn count(&self) -> u64 {
        self.count
    }

    pub fn pressed(&self) -> bool {
        self.pressed
    }

    pub fn press(&mut self) {
        self.pressed = true;
    }

    pub fn release(&mut self) {
        if self.pressed {
            self.count = self.count.saturating_add(1);
        }
        self.pressed = false;
    }

    #[cfg(target_os = "linux")]
    pub fn cancel_press(&mut self) {
        self.pressed = false;
    }
}
