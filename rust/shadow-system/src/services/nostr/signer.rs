use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use shadow_runtime_protocol::{
    SystemPromptAction, SystemPromptActionStyle, SystemPromptRequest, SystemPromptResponse,
};
use shadow_sdk::services::nostr::{
    NostrAccountSummary, NostrPublishRequest, SqliteNostrService, NOSTR_ACCOUNT_PATH_ENV,
    NOSTR_DB_PATH_ENV,
};
use shadow_sdk::services::session_config::{self, RUNTIME_SESSION_CONFIG_ENV};

use crate::services::system_prompt;

const SIGNER_POLICY_PATH_ENV: &str = "SHADOW_RUNTIME_NOSTR_SIGNER_POLICY_PATH";
const SIGNER_POLICY_BASENAME: &str = "runtime-nostr-signer-policy.json";
const ALLOW_ONCE_ACTION_ID: &str = "allow_once";
const ALLOW_ALWAYS_ACTION_ID: &str = "allow_always";
const DENY_ACTION_ID: &str = "deny";
const PREVIEW_LIMIT: usize = 160;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum PersistedSignerPolicy {
    AllowAlways,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
struct PersistedSignerPolicies {
    #[serde(default, rename = "byAccount")]
    by_account: BTreeMap<String, BTreeMap<String, PersistedSignerPolicy>>,
}

pub fn ensure_publish_approved(
    service: &SqliteNostrService,
    caller_app_id: &str,
    caller_app_title: Option<&str>,
    request: &NostrPublishRequest,
) -> Result<(), String> {
    let caller_app_id = caller_app_id.trim();
    if caller_app_id.is_empty() {
        return Err(String::from(
            "nostr.publish requires an app identity for signer approval",
        ));
    }

    let account = service
        .current_account()
        .map_err(|error| error.to_string())?
        .ok_or_else(|| String::from("nostr.publish requires an active shared Nostr account"))?;
    if load_policy(&account, caller_app_id)? == Some(PersistedSignerPolicy::AllowAlways) {
        return Ok(());
    }

    let response = system_prompt::request(&build_publish_prompt(
        caller_app_id,
        caller_app_title,
        &account,
        request,
    ))?;
    handle_prompt_response(&account, caller_app_id, response)
}

fn handle_prompt_response(
    account: &NostrAccountSummary,
    caller_app_id: &str,
    response: SystemPromptResponse,
) -> Result<(), String> {
    match response.action_id.as_str() {
        ALLOW_ONCE_ACTION_ID => Ok(()),
        ALLOW_ALWAYS_ACTION_ID => {
            store_policy(account, caller_app_id, PersistedSignerPolicy::AllowAlways)?;
            Ok(())
        }
        DENY_ACTION_ID => Err(String::from("nostr.publish denied by the system signer")),
        other => Err(format!(
            "nostr.publish received an unknown signer approval action: {other}"
        )),
    }
}

fn build_publish_prompt(
    caller_app_id: &str,
    caller_app_title: Option<&str>,
    account: &NostrAccountSummary,
    request: &NostrPublishRequest,
) -> SystemPromptRequest {
    let app_title =
        normalize_optional_string(caller_app_title).unwrap_or_else(|| caller_app_id.to_owned());
    let mut detail_lines = vec![
        format!("Account: {}", account.npub),
        format!("Kind: {}", request.kind),
    ];
    if request.reply_to_event_id.is_some() {
        detail_lines.push(String::from(
            "Reply: this note references an existing thread.",
        ));
    }
    detail_lines.push(format!("Preview: {}", preview_text(&request.content)));

    SystemPromptRequest {
        source_app_id: caller_app_id.to_owned(),
        source_app_title: (app_title != caller_app_id).then_some(app_title.clone()),
        title: String::from("Allow Nostr publish?"),
        message: format!(
            "{app_title} wants to sign and publish a Nostr event with the shared account."
        ),
        detail_lines,
        actions: vec![
            SystemPromptAction {
                id: DENY_ACTION_ID.to_owned(),
                label: String::from("Deny"),
                style: SystemPromptActionStyle::Danger,
            },
            SystemPromptAction {
                id: ALLOW_ONCE_ACTION_ID.to_owned(),
                label: String::from("Allow Once"),
                style: SystemPromptActionStyle::Default,
            },
            SystemPromptAction {
                id: ALLOW_ALWAYS_ACTION_ID.to_owned(),
                label: String::from("Always Allow"),
                style: SystemPromptActionStyle::Normal,
            },
        ],
    }
}

fn load_policy(
    account: &NostrAccountSummary,
    caller_app_id: &str,
) -> Result<Option<PersistedSignerPolicy>, String> {
    let Some(path) = signer_policy_path() else {
        return Ok(None);
    };
    let policies = read_persisted_policies(&path)?;
    Ok(policies
        .by_account
        .get(&account.npub)
        .and_then(|apps| apps.get(caller_app_id))
        .copied())
}

fn store_policy(
    account: &NostrAccountSummary,
    caller_app_id: &str,
    policy: PersistedSignerPolicy,
) -> Result<(), String> {
    let path = signer_policy_path().ok_or_else(|| {
        format!(
            "nostr signer policy cannot resolve a writable path; set {SIGNER_POLICY_PATH_ENV}, {NOSTR_ACCOUNT_PATH_ENV}, {RUNTIME_SESSION_CONFIG_ENV}, or {NOSTR_DB_PATH_ENV}"
        )
    })?;
    let mut policies = read_persisted_policies(&path)?;
    policies
        .by_account
        .entry(account.npub.clone())
        .or_default()
        .insert(caller_app_id.to_owned(), policy);
    write_persisted_policies(&path, &policies)
}

fn signer_policy_path() -> Option<PathBuf> {
    std::env::var(SIGNER_POLICY_PATH_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var(NOSTR_ACCOUNT_PATH_ENV)
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .and_then(|path| {
                    path.parent()
                        .filter(|parent| !parent.as_os_str().is_empty())
                        .map(|parent| parent.join(SIGNER_POLICY_BASENAME))
                })
        })
        .or_else(default_signer_policy_path)
}

fn default_signer_policy_path() -> Option<PathBuf> {
    let db_path = session_config::runtime_services_config()
        .ok()
        .flatten()
        .and_then(|services| {
            services
                .nostr_db_path
                .map(|path| path.to_string_lossy().into_owned())
        })
        .or_else(|| {
            std::env::var(NOSTR_DB_PATH_ENV)
                .ok()
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        })?;
    if db_path == ":memory:" {
        return None;
    }
    let parent = Path::new(&db_path)
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())?;
    Some(parent.join(SIGNER_POLICY_BASENAME))
}

fn read_persisted_policies(path: &Path) -> Result<PersistedSignerPolicies, String> {
    if !path.exists() {
        return Ok(PersistedSignerPolicies::default());
    }
    let encoded = fs::read_to_string(path)
        .map_err(|error| format!("read signer policy file {}: {error}", path.display()))?;
    serde_json::from_str(&encoded)
        .map_err(|error| format!("decode signer policy file {}: {error}", path.display()))
}

fn write_persisted_policies(path: &Path, policies: &PersistedSignerPolicies) -> Result<(), String> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent)
            .map_err(|error| format!("create signer policy dir {}: {error}", parent.display()))?;
    }
    let encoded = serde_json::to_string(policies)
        .map_err(|error| format!("encode signer policy file {}: {error}", path.display()))?;
    let temp_path = path.with_extension("tmp");
    fs::write(&temp_path, encoded.as_bytes()).map_err(|error| {
        format!(
            "write signer policy temp file {}: {error}",
            temp_path.display()
        )
    })?;
    fs::rename(&temp_path, path).map_err(|error| {
        format!(
            "rename signer policy temp file {} -> {}: {error}",
            temp_path.display(),
            path.display()
        )
    })
}

fn normalize_optional_string(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn preview_text(content: &str) -> String {
    let trimmed = content.split_whitespace().collect::<Vec<_>>().join(" ");
    if trimmed.chars().count() <= PREVIEW_LIMIT {
        return trimmed;
    }
    let preview = trimmed.chars().take(PREVIEW_LIMIT).collect::<String>();
    format!("{preview}...")
}

#[cfg(test)]
mod tests {
    use super::{
        build_publish_prompt, load_policy, preview_text, signer_policy_path, store_policy,
        PersistedSignerPolicy, SIGNER_POLICY_BASENAME, SIGNER_POLICY_PATH_ENV,
    };
    use crate::services::test_env_lock;
    use shadow_sdk::services::nostr::{
        NostrAccountSource, NostrAccountSummary, NostrPublishRequest, NOSTR_DB_PATH_ENV,
    };
    use shadow_sdk::services::session_config::RUNTIME_SESSION_CONFIG_ENV;
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn preview_text_trims_and_truncates() {
        let preview = preview_text(
            "hello    world   hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world hello world",
        );

        assert!(preview.starts_with("hello world"));
        assert!(preview.len() <= 163);
    }

    #[test]
    fn signer_policy_round_trips_by_account_and_app() {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let temp_dir = std::env::temp_dir().join(format!("shadow-nostr-signer-{timestamp}"));
        let policy_path = temp_dir.join("signer-policy.json");
        std::env::set_var(SIGNER_POLICY_PATH_ENV, &policy_path);

        let account = NostrAccountSummary {
            npub: String::from("npub1example"),
            source: NostrAccountSource::Generated,
        };
        store_policy(
            &account,
            "rust-timeline",
            PersistedSignerPolicy::AllowAlways,
        )
        .expect("store policy");

        assert_eq!(
            load_policy(&account, "rust-timeline").expect("load policy"),
            Some(PersistedSignerPolicy::AllowAlways)
        );
        assert_eq!(signer_policy_path().as_deref(), Some(policy_path.as_path()));

        std::env::remove_var(SIGNER_POLICY_PATH_ENV);
        let _ = std::fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn signer_policy_path_prefers_session_config_db_parent() {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let temp_dir = std::env::temp_dir().join(format!("shadow-nostr-signer-config-{timestamp}"));
        let config_db_dir = temp_dir.join("config-db");
        let env_db_dir = temp_dir.join("env-db");
        let config_path = temp_dir.join("session-config.json");
        fs::create_dir_all(&temp_dir).expect("create temp dir");
        fs::write(
            &config_path,
            format!(
                r#"{{
                    "services": {{
                        "nostrDbPath": "{}"
                    }}
                }}"#,
                config_db_dir.join("runtime-nostr.sqlite3").display()
            ),
        )
        .expect("write session config");
        std::env::set_var(RUNTIME_SESSION_CONFIG_ENV, &config_path);
        std::env::set_var(NOSTR_DB_PATH_ENV, env_db_dir.join("runtime-nostr.sqlite3"));

        assert_eq!(
            signer_policy_path().as_deref(),
            Some(
                Path::new(&config_db_dir)
                    .join(SIGNER_POLICY_BASENAME)
                    .as_path()
            )
        );

        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);
        std::env::remove_var(NOSTR_DB_PATH_ENV);
        let _ = fs::remove_dir_all(temp_dir);
    }

    #[test]
    fn publish_prompt_mentions_account_preview_and_actions() {
        let request = build_publish_prompt(
            "rust-timeline",
            Some("Rust Timeline"),
            &NostrAccountSummary {
                npub: String::from("npub1test"),
                source: NostrAccountSource::Generated,
            },
            &NostrPublishRequest {
                kind: 1,
                content: String::from("Hello from Shadow"),
                root_event_id: None,
                reply_to_event_id: Some(String::from("abc123")),
                relay_urls: None,
                timeout_ms: None,
            },
        );

        assert_eq!(request.title, "Allow Nostr publish?");
        assert_eq!(request.source_app_id, "rust-timeline");
        assert_eq!(request.actions.len(), 3);
        assert!(request
            .detail_lines
            .iter()
            .any(|line| line.contains("npub1test")));
        assert!(request
            .detail_lines
            .iter()
            .any(|line| line.contains("Hello from Shadow")));
    }
}
