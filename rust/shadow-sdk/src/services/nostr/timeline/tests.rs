use super::{
    load_home_cache_state_for_account, load_home_feed_scope_for_account, load_note_cache_state,
    load_profile_summary, load_thread_context, run_refresh_home_feed_task,
    run_sync_explore_feed_task, run_sync_thread_task, run_update_contact_list_task,
    thread_parent_ids, NostrContactListUpdateAction, NostrContactListUpdateRequest,
    NostrExploreSyncRequest, NostrHomeFeedSource, NostrHomeRefreshRequest,
    NostrThreadSyncRequest, NostrTimelinePublishRequest,
};
use crate::services::nostr::{
    NostrEvent, SqliteNostrService, NOSTR_ACCOUNT_NSEC_ENV, NOSTR_ACCOUNT_PATH_ENV,
    NOSTR_DB_PATH_ENV, NOSTR_SERVICE_SOCKET_ENV,
};
use crate::services::session_config::RUNTIME_SESSION_CONFIG_ENV;
use crate::services::test_env_lock;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn with_temp_db<T>(f: impl FnOnce() -> T) -> T {
    let _guard = test_env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time")
        .as_nanos();
    let db_path =
        std::env::temp_dir().join(format!("shadow-sdk-nostr-timeline-{timestamp}.sqlite"));
    let account_path =
        db_path.with_file_name(format!("shadow-sdk-nostr-timeline-{timestamp}.json"));
    std::env::set_var(NOSTR_DB_PATH_ENV, &db_path);
    std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
    std::env::set_var(NOSTR_ACCOUNT_PATH_ENV, &account_path);
    std::env::remove_var(NOSTR_SERVICE_SOCKET_ENV);
    let output = f();
    std::env::remove_var(NOSTR_DB_PATH_ENV);
    std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
    let _ = fs::remove_file(&db_path);
    let _ = fs::remove_file(&account_path);
    output
}

fn with_missing_nostr_service_config<T>(f: impl FnOnce() -> T) -> T {
    let _guard = test_env_lock()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    std::env::remove_var(NOSTR_DB_PATH_ENV);
    std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
    std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
    std::env::remove_var(NOSTR_SERVICE_SOCKET_ENV);
    std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);
    f()
}

#[test]
fn home_feed_scope_uses_unique_public_keys_from_cached_contact_list() {
    with_temp_db(|| {
        let service = SqliteNostrService::from_env().expect("open sqlite service");
        service
            .store_event(&NostrEvent {
                content: String::new(),
                created_at: 1_700_000_000,
                id: String::from("contact-list"),
                kind: 3,
                pubkey: String::from("npub-owner"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: vec![
                    crate::services::nostr::NostrPublicKeyReference {
                        public_key: String::from("npub-follow-a"),
                        relay_url: None,
                        alias: None,
                    },
                    crate::services::nostr::NostrPublicKeyReference {
                        public_key: String::from("npub-follow-b"),
                        relay_url: None,
                        alias: None,
                    },
                    crate::services::nostr::NostrPublicKeyReference {
                        public_key: String::from("npub-follow-a"),
                        relay_url: None,
                        alias: None,
                    },
                ],
            })
            .expect("store contact list");

        let scope = load_home_feed_scope_for_account("npub-owner").expect("load home feed scope");

        assert_eq!(scope.source, NostrHomeFeedSource::Following { count: 2 });
        assert_eq!(
            scope.authors,
            Some(vec![
                String::from("npub-follow-a"),
                String::from("npub-follow-b")
            ])
        );
    });
}

#[test]
fn home_cache_state_reads_followed_notes() {
    with_temp_db(|| {
        let service = SqliteNostrService::from_env().expect("open sqlite service");
        service
            .store_event(&NostrEvent {
                content: String::new(),
                created_at: 1_700_000_000,
                id: String::from("contact-list"),
                kind: 3,
                pubkey: String::from("npub-owner"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: vec![crate::services::nostr::NostrPublicKeyReference {
                    public_key: String::from("npub-follow-a"),
                    relay_url: None,
                    alias: None,
                }],
            })
            .expect("store contact list");
        service
            .store_event(&NostrEvent {
                content: String::from("followed note"),
                created_at: 1_700_000_001,
                id: String::from("note-a"),
                kind: 1,
                pubkey: String::from("npub-follow-a"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store followed note");

        let cache = load_home_cache_state_for_account("npub-owner", 20).expect("load home cache");

        assert_eq!(
            cache.feed_scope.source,
            NostrHomeFeedSource::Following { count: 1 }
        );
        assert_eq!(cache.notes.len(), 1);
        assert_eq!(cache.notes[0].id, "note-a");
    });
}

#[test]
fn load_profile_summary_reads_metadata_json() {
    with_temp_db(|| {
        let service = SqliteNostrService::from_env().expect("open sqlite service");
        service
            .store_event(&NostrEvent {
                content: String::from(
                    r#"{"display_name":"alice","about":"hello","nip05":"alice@example.com"}"#,
                ),
                created_at: 1_700_000_001,
                id: String::from("metadata"),
                kind: 0,
                pubkey: String::from("npub-alice"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store metadata");

        let summary = load_profile_summary("npub-alice").expect("load profile summary");

        assert_eq!(summary.display_name.as_deref(), Some("alice"));
        assert_eq!(summary.about.as_deref(), Some("hello"));
        assert_eq!(summary.nip05.as_deref(), Some("alice@example.com"));
        assert_eq!(summary.metadata_event_id.as_deref(), Some("metadata"));
    });
}

#[test]
fn load_thread_context_only_uses_direct_reply_ids() {
    with_temp_db(|| {
        let service = SqliteNostrService::from_env().expect("open sqlite service");
        service
            .store_event(&NostrEvent {
                content: String::from("root"),
                created_at: 1_700_000_000,
                id: String::from("root"),
                kind: 1,
                pubkey: String::from("npub-owner"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store root");
        service
            .store_event(&NostrEvent {
                content: String::from("reply"),
                created_at: 1_700_000_001,
                id: String::from("reply"),
                kind: 1,
                pubkey: String::from("npub-reply"),
                identifier: None,
                root_event_id: Some(String::from("root")),
                reply_to_event_id: Some(String::from("root")),
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store direct reply");
        service
            .store_event(&NostrEvent {
                content: String::from("mention only"),
                created_at: 1_700_000_002,
                id: String::from("mention"),
                kind: 1,
                pubkey: String::from("npub-mention"),
                identifier: None,
                root_event_id: Some(String::from("root")),
                reply_to_event_id: None,
                references: vec![crate::services::nostr::NostrEventReference {
                    event_id: String::from("root"),
                    marker: Some(String::from("mention")),
                }],
                public_keys: Vec::new(),
            })
            .expect("store mention");

        let context = load_thread_context(&NostrEvent {
            content: String::from("root"),
            created_at: 1_700_000_000,
            id: String::from("root"),
            kind: 1,
            pubkey: String::from("npub-owner"),
            identifier: None,
            root_event_id: None,
            reply_to_event_id: None,
            references: Vec::new(),
            public_keys: Vec::new(),
        })
        .expect("load thread context");

        assert_eq!(context.parent, None);
        assert_eq!(context.replies.len(), 1);
        assert_eq!(context.replies[0].id, "reply");
    });
}

#[test]
fn load_note_cache_state_reads_note_profile_and_thread() {
    with_temp_db(|| {
        let service = SqliteNostrService::from_env().expect("open sqlite service");
        service
            .store_event(&NostrEvent {
                content: String::from(r#"{"display_name":"alice"}"#),
                created_at: 1_700_000_000,
                id: String::from("metadata"),
                kind: 0,
                pubkey: String::from("npub-alice"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store metadata");
        service
            .store_event(&NostrEvent {
                content: String::from("root"),
                created_at: 1_700_000_001,
                id: String::from("root"),
                kind: 1,
                pubkey: String::from("npub-alice"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store root");
        service
            .store_event(&NostrEvent {
                content: String::from("reply"),
                created_at: 1_700_000_002,
                id: String::from("reply"),
                kind: 1,
                pubkey: String::from("npub-bob"),
                identifier: None,
                root_event_id: Some(String::from("root")),
                reply_to_event_id: Some(String::from("root")),
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store reply");

        let cache = load_note_cache_state("root").expect("load note cache");

        assert_eq!(
            cache.note.as_ref().map(|note| note.id.as_str()),
            Some("root")
        );
        assert_eq!(cache.profile.display_name.as_deref(), Some("alice"));
        assert!(cache.thread.parent.is_none());
        assert_eq!(cache.thread.replies.len(), 1);
        assert_eq!(cache.thread.replies[0].id, "reply");
    });
}

#[test]
fn timeline_publish_request_helpers_expose_content_and_target() {
    let note = NostrTimelinePublishRequest::note(
        String::from("top-level note"),
        vec![String::from("wss://relay.example")],
    );
    assert!(note.is_note());
    assert_eq!(note.content(), "top-level note");
    assert!(!note.is_reply_to("note-1"));

    let reply = NostrTimelinePublishRequest::reply(
        String::from("reply body"),
        vec![String::from("wss://relay.example")],
        String::from("note-1"),
        Some(String::from("root-1")),
    );
    assert!(!reply.is_note());
    assert_eq!(reply.content(), "reply body");
    assert!(reply.is_reply_to("note-1"));
    assert!(!reply.is_reply_to("note-2"));
}

#[test]
fn run_refresh_home_feed_task_stringifies_missing_service_config() {
    with_missing_nostr_service_config(|| {
        let error = run_refresh_home_feed_task(NostrHomeRefreshRequest {
            account_npub: String::from("npub-owner"),
            limit: 20,
            relay_urls: Vec::new(),
        })
        .expect_err("missing nostr service config should fail");

        assert!(error.contains("shadow nostr service socket is not configured"));
    });
}

#[test]
fn run_sync_explore_feed_task_stringifies_missing_service_config() {
    with_missing_nostr_service_config(|| {
        let error = run_sync_explore_feed_task(NostrExploreSyncRequest {
            limit: 24,
            relay_urls: Vec::new(),
        })
        .expect_err("missing nostr service config should fail");

        assert!(error.contains("shadow nostr service socket is not configured"));
    });
}

#[test]
fn run_sync_thread_task_stringifies_missing_service_config() {
    with_missing_nostr_service_config(|| {
        let error = run_sync_thread_task(NostrThreadSyncRequest {
            note_id: String::from("note-1"),
            parent_ids: vec![String::from("root-1")],
            relay_urls: Vec::new(),
        })
        .expect_err("missing nostr service config should fail");

        assert!(error.contains("shadow nostr service socket is not configured"));
    });
}

#[test]
fn run_update_contact_list_task_stringifies_missing_service_config() {
    with_missing_nostr_service_config(|| {
        let error = run_update_contact_list_task(NostrContactListUpdateRequest {
            account_npub: String::from("npub-owner"),
            action: NostrContactListUpdateAction::Add {
                npub: String::from("npub-follow"),
            },
            relay_urls: Vec::new(),
        })
        .expect_err("missing nostr service config should fail");

        assert!(error.contains("shadow nostr service socket is not configured"));
    });
}

#[test]
fn thread_parent_ids_deduplicates_root_and_reply() {
    let ids = thread_parent_ids(&NostrEvent {
        content: String::new(),
        created_at: 1_700_000_000,
        id: String::from("note"),
        kind: 1,
        pubkey: String::from("npub-owner"),
        identifier: None,
        root_event_id: Some(String::from("root")),
        reply_to_event_id: Some(String::from("root")),
        references: Vec::new(),
        public_keys: Vec::new(),
    });

    assert_eq!(ids, vec![String::from("root")]);
}
