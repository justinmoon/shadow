use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::{
    super::{
        get_event, get_replaceable, query, NostrError, NostrEvent, NostrPublicKeyReference,
        NostrQuery, NostrReplaceableQuery,
    },
    NostrExploreCacheState, NostrExploreProfileEntry, NostrHomeCacheState, NostrHomeFeedScope,
    NostrNoteCacheState, NostrProfileCacheState, NostrProfileSummary, NostrThreadContext,
};

pub fn load_home_feed_scope_for_account(
    npub: impl AsRef<str>,
) -> Result<NostrHomeFeedScope, NostrError> {
    let Some(contact_list) = load_contact_list_event_for_account(npub.as_ref())? else {
        return Ok(NostrHomeFeedScope::no_contacts());
    };
    let mut authors = Vec::new();
    for reference in contact_list.public_keys {
        if authors.iter().all(|author| author != &reference.public_key) {
            authors.push(reference.public_key);
        }
    }
    if authors.is_empty() {
        Ok(NostrHomeFeedScope::no_contacts())
    } else {
        Ok(NostrHomeFeedScope::following(authors))
    }
}

pub fn load_cached_home_notes(
    limit: usize,
    feed_scope: &NostrHomeFeedScope,
) -> Result<Vec<NostrEvent>, NostrError> {
    let Some(authors) = feed_scope.authors.clone() else {
        return Ok(Vec::new());
    };
    query(NostrQuery {
        ids: None,
        authors: Some(authors),
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit),
    })
}

pub fn load_home_cache_state_for_account(
    npub: impl AsRef<str>,
    limit: usize,
) -> Result<NostrHomeCacheState, NostrError> {
    let feed_scope = load_home_feed_scope_for_account(npub)?;
    let notes = load_cached_home_notes(limit, &feed_scope)?;
    Ok(NostrHomeCacheState { feed_scope, notes })
}

pub fn load_explore_notes(limit: usize) -> Result<Vec<NostrEvent>, NostrError> {
    query(NostrQuery {
        ids: None,
        authors: None,
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit),
    })
}

pub fn load_explore_cache_state(limit: usize) -> Result<NostrExploreCacheState, NostrError> {
    let notes = load_explore_notes(limit)?;
    let profiles = build_explore_profile_entries(&notes)?;
    Ok(NostrExploreCacheState { notes, profiles })
}

pub fn load_contact_references_for_account(
    npub: impl AsRef<str>,
) -> Result<Vec<NostrPublicKeyReference>, NostrError> {
    Ok(load_contact_list_event_for_account(npub.as_ref())?
        .map(|event| event.public_keys)
        .unwrap_or_default())
}

pub fn load_profile_summary(pubkey: impl AsRef<str>) -> Result<NostrProfileSummary, NostrError> {
    let Some(event) = get_replaceable(NostrReplaceableQuery {
        kind: 0,
        pubkey: pubkey.as_ref().to_owned(),
        identifier: None,
    })?
    else {
        return Ok(NostrProfileSummary::default());
    };

    let Ok(metadata) = serde_json::from_str::<Value>(&event.content) else {
        return Ok(NostrProfileSummary {
            metadata_event_id: Some(event.id),
            ..NostrProfileSummary::default()
        });
    };

    Ok(NostrProfileSummary {
        about: metadata
            .get("about")
            .and_then(Value::as_str)
            .map(str::to_owned),
        display_name: metadata
            .get("display_name")
            .and_then(Value::as_str)
            .or_else(|| metadata.get("displayName").and_then(Value::as_str))
            .or_else(|| metadata.get("name").and_then(Value::as_str))
            .map(str::to_owned),
        metadata_event_id: Some(event.id),
        nip05: metadata
            .get("nip05")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

pub fn load_profile_cache_state(
    pubkey: impl AsRef<str>,
    limit: usize,
) -> Result<NostrProfileCacheState, NostrError> {
    let pubkey = pubkey.as_ref();
    let summary = load_profile_summary(pubkey)?;
    let notes = load_profile_notes(pubkey, limit)?;
    Ok(NostrProfileCacheState { summary, notes })
}

pub fn load_thread_context(note: &NostrEvent) -> Result<NostrThreadContext, NostrError> {
    let parent = note
        .reply_to_event_id
        .as_ref()
        .and_then(|event_id| get_event(event_id).ok().flatten());
    let replies = query(NostrQuery {
        ids: None,
        authors: None,
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: Some(vec![note.id.clone()]),
        since: None,
        until: None,
        limit: Some(24),
    })?;

    Ok(NostrThreadContext { parent, replies })
}

pub fn load_note_cache_state(note_id: impl AsRef<str>) -> Result<NostrNoteCacheState, NostrError> {
    let Some(note) = get_event(note_id.as_ref())? else {
        return Ok(NostrNoteCacheState::default());
    };
    let profile = load_profile_summary(&note.pubkey)?;
    let thread = load_thread_context(&note)?;
    Ok(NostrNoteCacheState {
        note: Some(note),
        profile,
        thread,
    })
}

pub fn thread_parent_ids(note: &NostrEvent) -> Vec<String> {
    let mut parent_ids = Vec::new();
    if let Some(reply_to_event_id) = note.reply_to_event_id.as_ref() {
        parent_ids.push(reply_to_event_id.clone());
    }
    if let Some(root_event_id) = note.root_event_id.as_ref() {
        if !parent_ids.iter().any(|id| id == root_event_id) {
            parent_ids.push(root_event_id.clone());
        }
    }
    parent_ids
}

fn load_contact_list_event_for_account(npub: &str) -> Result<Option<NostrEvent>, NostrError> {
    get_replaceable(NostrReplaceableQuery {
        kind: 3,
        pubkey: npub.to_owned(),
        identifier: None,
    })
}

fn load_profile_notes(pubkey: &str, limit: usize) -> Result<Vec<NostrEvent>, NostrError> {
    query(NostrQuery {
        ids: None,
        authors: Some(vec![pubkey.to_owned()]),
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit.max(24)),
    })
}

fn build_explore_profile_entries(
    notes: &[NostrEvent],
) -> Result<Vec<NostrExploreProfileEntry>, NostrError> {
    let mut note_counts = BTreeMap::new();
    for note in notes {
        *note_counts.entry(note.pubkey.clone()).or_insert(0_usize) += 1;
    }

    let mut seen = BTreeSet::new();
    let mut entries = Vec::new();
    for note in notes {
        if !seen.insert(note.pubkey.clone()) {
            continue;
        }
        entries.push(NostrExploreProfileEntry {
            latest_note_preview: note_preview(&note.content),
            note_count: *note_counts.get(&note.pubkey).unwrap_or(&1),
            profile: load_profile_summary(&note.pubkey).unwrap_or_default(),
            pubkey: note.pubkey.clone(),
            updated_at: note.created_at,
        });
    }
    Ok(entries)
}

fn note_preview(content: &str) -> String {
    let preview = content.lines().next().unwrap_or("").trim();
    if preview.is_empty() {
        String::from("No preview available.")
    } else {
        preview.to_owned()
    }
}
