use std::{
    env, fmt,
    path::{Path, PathBuf},
    process::Command,
};

pub type EnvAssignment = (String, String);

pub fn first_env_value(keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        env::var(key)
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
    })
}

pub fn runtime_dir_from_env_or<F>(fallback: F) -> PathBuf
where
    F: FnOnce() -> PathBuf,
{
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(fallback)
}

pub fn apply_env_assignments(command: &mut Command, spec: &str) -> Result<(), InvalidEnvSpec> {
    for (key, value) in parse_env_assignments(spec)? {
        command.env(key, value);
    }

    Ok(())
}

pub fn parse_env_assignments(spec: &str) -> Result<Vec<EnvAssignment>, InvalidEnvSpec> {
    let mut assignments = Vec::new();

    for assignment in spec.split_whitespace() {
        let Some((key, value)) = assignment.split_once('=') else {
            return Err(InvalidEnvSpec {
                assignment: assignment.to_string(),
                reason: InvalidEnvSpecReason::MissingEquals,
            });
        };
        if key.is_empty() {
            return Err(InvalidEnvSpec {
                assignment: assignment.to_string(),
                reason: InvalidEnvSpecReason::EmptyKey,
            });
        }
        assignments.push((key.to_string(), value.to_string()));
    }

    Ok(assignments)
}

pub fn sibling_binary_path(name: &str) -> Option<PathBuf> {
    let current = env::current_exe().ok()?;
    Some(current.with_file_name(name))
}

pub fn workspace_manifest() -> Option<PathBuf> {
    let mut roots = Vec::new();
    roots.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")));
    if let Ok(current) = env::current_dir() {
        roots.push(current);
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(parent) = exe.parent() {
            roots.push(parent.to_path_buf());
        }
    }

    for root in roots {
        if let Some(manifest) = find_manifest_upwards(&root) {
            return Some(manifest);
        }
    }

    None
}

fn find_manifest_upwards(start: &Path) -> Option<PathBuf> {
    for ancestor in start.ancestors() {
        let manifest = ancestor.join("Cargo.toml");
        if manifest.exists() {
            let contents = std::fs::read_to_string(&manifest).ok()?;
            if contents.contains("[workspace]") {
                return Some(manifest);
            }
        }
    }

    None
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InvalidEnvSpec {
    assignment: String,
    reason: InvalidEnvSpecReason,
}

impl fmt::Display for InvalidEnvSpec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.reason {
            InvalidEnvSpecReason::MissingEquals => {
                write!(
                    f,
                    "invalid env assignment {:?}: missing '='",
                    self.assignment
                )
            }
            InvalidEnvSpecReason::EmptyKey => {
                write!(f, "invalid env assignment {:?}: empty key", self.assignment)
            }
        }
    }
}

impl std::error::Error for InvalidEnvSpec {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum InvalidEnvSpecReason {
    MissingEquals,
    EmptyKey,
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::OsStr,
        path::PathBuf,
        process::Command,
        sync::{Mutex, OnceLock},
    };

    use super::{apply_env_assignments, parse_env_assignments, runtime_dir_from_env_or};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn apply_env_assignments_sets_each_assignment() {
        let mut command = Command::new("env");
        apply_env_assignments(&mut command, "A=1 B=two").expect("valid env spec");

        let vars = command.get_envs().collect::<Vec<_>>();
        assert!(vars
            .iter()
            .any(|(key, value)| *key == "A" && value == &Some(OsStr::new("1"))));
        assert!(vars
            .iter()
            .any(|(key, value)| *key == "B" && value == &Some(OsStr::new("two"))));
    }

    #[test]
    fn apply_env_assignments_rejects_invalid_tokens() {
        let mut command = Command::new("env");
        let error = apply_env_assignments(&mut command, "A=1 not-an-assignment")
            .expect_err("invalid env spec");
        assert_eq!(
            error.to_string(),
            "invalid env assignment \"not-an-assignment\": missing '='"
        );
    }

    #[test]
    fn parse_env_assignments_preserves_key_value_pairs() {
        let assignments = parse_env_assignments("A=1 B=two").expect("valid env spec");
        assert_eq!(
            assignments,
            vec![
                ("A".to_string(), "1".to_string()),
                ("B".to_string(), "two".to_string()),
            ]
        );
    }

    #[test]
    fn runtime_dir_from_env_uses_env_when_present() {
        let _guard = env_lock().lock().expect("lock env");
        unsafe {
            std::env::set_var("XDG_RUNTIME_DIR", "/tmp/shadow-runtime-test");
        }
        let runtime_dir = runtime_dir_from_env_or(|| PathBuf::from("/fallback"));
        assert_eq!(runtime_dir, PathBuf::from("/tmp/shadow-runtime-test"));
        unsafe {
            std::env::remove_var("XDG_RUNTIME_DIR");
        }
    }

    #[test]
    fn runtime_dir_from_env_uses_fallback_when_missing() {
        let _guard = env_lock().lock().expect("lock env");
        unsafe {
            std::env::remove_var("XDG_RUNTIME_DIR");
        }
        let runtime_dir = runtime_dir_from_env_or(|| PathBuf::from("/fallback"));
        assert_eq!(runtime_dir, PathBuf::from("/fallback"));
    }
}
