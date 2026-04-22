use super::{
    super::{
        publish, sync, NostrError, NostrHostError, NostrPublishRequest, NostrQuery,
        NostrSyncRequest,
    },
    load_cached_home_notes, load_contact_references_for_account, load_explore_notes,
    load_home_feed_scope_for_account, NostrContactListUpdateAction,
    NostrContactListUpdateOutcome, NostrContactListUpdateRequest, NostrExploreSyncOutcome,
    NostrExploreSyncRequest, NostrHomeRefreshOutcome, NostrHomeRefreshRequest,
    NostrReplyPublishOutcome, NostrReplyPublishRequest, NostrThreadSyncOutcome,
    NostrThreadSyncRequest,
};

pub fn refresh_home_feed(
    request: NostrHomeRefreshRequest,
) -> Result<NostrHomeRefreshOutcome, NostrError> {
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());
    let mut fetched_count = 0_usize;
    let mut imported_count = 0_usize;

    let account_receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: Some(vec![request.account_npub.clone()]),
            kinds: Some(vec![0, 3]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(4),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })?;
    fetched_count += account_receipt.fetched_count;
    imported_count += account_receipt.imported_count;

    let feed_scope = load_home_feed_scope_for_account(&request.account_npub)?;
    if let Some(authors) = feed_scope.authors.clone() {
        let profile_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors.clone()),
                kinds: Some(vec![0]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(authors.len().max(1)),
            },
            relay_urls: relay_urls.clone(),
            timeout_ms: Some(8_000),
        })?;
        fetched_count += profile_receipt.fetched_count;
        imported_count += profile_receipt.imported_count;

        let note_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors),
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(request.limit),
            },
            relay_urls,
            timeout_ms: Some(8_000),
        })?;
        fetched_count += note_receipt.fetched_count;
        imported_count += note_receipt.imported_count;
    }

    let notes = load_cached_home_notes(request.limit, &feed_scope)?;

    Ok(NostrHomeRefreshOutcome {
        feed_scope,
        fetched_count,
        imported_count,
        notes,
    })
}

pub fn sync_explore_feed(
    request: NostrExploreSyncRequest,
) -> Result<NostrExploreSyncOutcome, NostrError> {
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());
    let note_receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: None,
            kinds: Some(vec![1]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(request.limit),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })?;
    let notes = load_explore_notes(request.limit)?;
    let authors = notes
        .iter()
        .map(|note| note.pubkey.clone())
        .collect::<Vec<_>>();
    let mut fetched_count = note_receipt.fetched_count;
    let mut imported_count = note_receipt.imported_count;
    if !authors.is_empty() {
        let profile_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors),
                kinds: Some(vec![0]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(request.limit),
            },
            relay_urls,
            timeout_ms: Some(8_000),
        })?;
        fetched_count += profile_receipt.fetched_count;
        imported_count += profile_receipt.imported_count;
    }

    Ok(NostrExploreSyncOutcome {
        fetched_count,
        imported_count,
    })
}

pub fn sync_thread(
    request: NostrThreadSyncRequest,
) -> Result<NostrThreadSyncOutcome, NostrError> {
    let mut fetched_count = 0_usize;
    let mut imported_count = 0_usize;
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());

    if !request.parent_ids.is_empty() {
        let receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: Some(request.parent_ids.clone()),
                authors: None,
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(request.parent_ids.len()),
            },
            relay_urls: relay_urls.clone(),
            timeout_ms: Some(8_000),
        })?;
        fetched_count += receipt.fetched_count;
        imported_count += receipt.imported_count;
    }

    let receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: None,
            kinds: Some(vec![1]),
            referenced_ids: Some(vec![request.note_id]),
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(48),
        },
        relay_urls,
        timeout_ms: Some(8_000),
    })?;
    fetched_count += receipt.fetched_count;
    imported_count += receipt.imported_count;

    Ok(NostrThreadSyncOutcome {
        fetched_count,
        imported_count,
    })
}

pub fn update_contact_list(
    request: NostrContactListUpdateRequest,
) -> Result<NostrContactListUpdateOutcome, NostrError> {
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());
    let _ = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: Some(vec![request.account_npub.clone()]),
            kinds: Some(vec![3]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(1),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })
    .map_err(|error| {
        NostrHostError::from(format!("Could not refresh the latest contact list: {error}"))
    })
    .map_err(NostrError::from)?;

    let mut public_keys = load_contact_references_for_account(&request.account_npub)?;
    match request.action {
        NostrContactListUpdateAction::Add { npub } => {
            if public_keys
                .iter()
                .all(|reference| reference.public_key != npub)
            {
                public_keys.push(super::super::NostrPublicKeyReference {
                    public_key: npub,
                    relay_url: None,
                    alias: None,
                });
            }
        }
        NostrContactListUpdateAction::Remove { npub } => {
            public_keys.retain(|reference| reference.public_key != npub);
        }
    }

    let receipt = publish(NostrPublishRequest::ContactList {
        public_keys,
        relay_urls,
        timeout_ms: Some(12_000),
    })?;

    Ok(NostrContactListUpdateOutcome { receipt })
}

pub fn publish_reply(
    request: NostrReplyPublishRequest,
) -> Result<NostrReplyPublishOutcome, NostrError> {
    let receipt = publish(NostrPublishRequest::TextNote {
        content: request.content,
        root_event_id: request.root_event_id,
        reply_to_event_id: Some(request.reply_to_event_id),
        relay_urls: (!request.relay_urls.is_empty()).then_some(request.relay_urls),
        timeout_ms: Some(12_000),
    })?;

    Ok(NostrReplyPublishOutcome { receipt })
}
