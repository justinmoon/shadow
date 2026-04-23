use std::collections::BTreeMap;

use shadow_sdk::services::nostr::{
    get_event,
    timeline::{
        load_explore_cache_state, load_home_cache_state_for_account,
        load_home_feed_scope_for_account, load_note_cache_state, load_profile_cache_state,
        NostrExploreCacheState, NostrNoteCacheState, NostrProfileCacheState, NostrProfileSummary,
        NostrThreadContext,
    },
    NostrEvent,
};

use crate::{ActiveAccount, FeedScope, Route};

#[derive(Clone, Debug)]
pub(crate) struct TimelineCachedData {
    feed_scope: FeedScope,
    home_notes: Vec<NostrEvent>,
    explore_cache: Option<NostrExploreCacheState>,
    note_caches: BTreeMap<String, NostrNoteCacheState>,
    profile_caches: BTreeMap<String, NostrProfileCacheState>,
}

impl TimelineCachedData {
    pub(crate) fn unavailable() -> Self {
        Self::from_home(FeedScope::unavailable(), Vec::new())
    }

    pub(crate) fn fallback_home(account: &ActiveAccount) -> Self {
        Self::from_home(Self::fallback_feed_scope(account), Vec::new())
    }

    pub(crate) fn from_home(feed_scope: FeedScope, home_notes: Vec<NostrEvent>) -> Self {
        Self {
            feed_scope,
            home_notes,
            explore_cache: None,
            note_caches: BTreeMap::new(),
            profile_caches: BTreeMap::new(),
        }
    }

    pub(crate) fn load_home(account: &ActiveAccount, limit: usize) -> Result<Self, String> {
        let cache = load_home_cache_state_for_account(&account.npub, limit)
            .map_err(|error| error.to_string())?;
        Ok(Self::from_home(
            FeedScope::from(cache.feed_scope),
            cache.notes,
        ))
    }

    pub(crate) fn fallback_feed_scope(account: &ActiveAccount) -> FeedScope {
        load_home_feed_scope_for_account(&account.npub)
            .map(FeedScope::from)
            .unwrap_or_else(|_| FeedScope::no_contacts())
    }

    pub(crate) fn reload_home(
        &mut self,
        account: Option<&ActiveAccount>,
        limit: usize,
    ) -> Result<(), String> {
        *self = match account {
            Some(account) => Self::load_home(account, limit)?,
            None => Self::unavailable(),
        };
        Ok(())
    }

    pub(crate) fn replace_home(&mut self, feed_scope: FeedScope, home_notes: Vec<NostrEvent>) {
        self.feed_scope = feed_scope;
        self.home_notes = home_notes;
        self.invalidate_routes();
    }

    pub(crate) fn feed_scope(&self) -> &FeedScope {
        &self.feed_scope
    }

    pub(crate) fn home_notes(&self) -> &[NostrEvent] {
        &self.home_notes
    }

    // Route-local cache reads stay synchronous here so app-level navigation can
    // transition the visible stack without repeating hydrate calls at each site.
    pub(crate) fn push_onto_route_stack(
        &mut self,
        route_stack: &mut Vec<Route>,
        route: Route,
        limit: usize,
    ) {
        if route_stack.last() == Some(&route) {
            return;
        }
        route_stack.push(route);
        self.hydrate_current_route(route_stack, limit);
    }

    pub(crate) fn pop_route_stack(&mut self, route_stack: &mut Vec<Route>, limit: usize) {
        if route_stack.len() > 1 {
            route_stack.pop();
        }
        self.hydrate_current_route(route_stack, limit);
    }

    pub(crate) fn reset_route_stack(
        &mut self,
        route_stack: &mut Vec<Route>,
        route: Route,
        limit: usize,
    ) {
        route_stack.clear();
        route_stack.push(route);
        self.hydrate_current_route(route_stack, limit);
    }

    pub(crate) fn hydrate_current_route(&mut self, route_stack: &[Route], limit: usize) {
        let route = route_stack.last().cloned().unwrap_or(Route::Timeline);
        self.hydrate_route(&route, limit);
    }

    // Route-local cache reads stay explicit: hydrate the active route up front,
    // then render from the cached state without hidden work.
    pub(crate) fn hydrate_route(&mut self, route: &Route, limit: usize) {
        match route {
            Route::Account | Route::Onboarding | Route::Timeline => {}
            Route::Explore => self.hydrate_explore_route(limit.max(24)),
            Route::Note { id } => self.hydrate_note_route(id),
            Route::Profile { pubkey } => self.hydrate_profile_route(pubkey, limit.max(24)),
        }
    }

    pub(crate) fn invalidate_routes(&mut self) {
        self.explore_cache = None;
        self.note_caches.clear();
        self.profile_caches.clear();
    }

    pub(crate) fn cached_note_by_id(&self, id: &str) -> Option<NostrEvent> {
        self.note_caches
            .get(id)
            .and_then(|state| state.note.clone())
            .or_else(|| self.note_by_id(id))
            .or_else(|| get_event(id).ok().flatten())
    }

    pub(crate) fn explore_state(&self) -> NostrExploreCacheState {
        self.explore_cache.clone().unwrap_or_default()
    }

    pub(crate) fn profile_state(&self, pubkey: &str) -> NostrProfileCacheState {
        self.profile_caches.get(pubkey).cloned().unwrap_or_else(|| {
            let notes = self
                .home_notes
                .iter()
                .filter(|note| note.pubkey == pubkey)
                .cloned()
                .collect();
            NostrProfileCacheState {
                summary: NostrProfileSummary::default(),
                notes,
            }
        })
    }

    pub(crate) fn note_state(&self, note_id: &str) -> NostrNoteCacheState {
        self.note_caches
            .get(note_id)
            .cloned()
            .unwrap_or_else(|| NostrNoteCacheState {
                note: self.cached_note_by_id(note_id),
                profile: NostrProfileSummary::default(),
                thread: NostrThreadContext::default(),
            })
    }

    fn hydrate_explore_route(&mut self, limit: usize) {
        if self.explore_cache.is_some() {
            return;
        }
        self.explore_cache = load_explore_cache_state(limit).ok();
    }

    fn hydrate_profile_route(&mut self, pubkey: &str, limit: usize) {
        if self.profile_caches.contains_key(pubkey) {
            return;
        }
        if let Ok(cache) = load_profile_cache_state(pubkey, limit) {
            self.profile_caches.insert(pubkey.to_owned(), cache);
        }
    }

    fn hydrate_note_route(&mut self, note_id: &str) {
        if self.note_caches.contains_key(note_id) {
            return;
        }
        if let Ok(cache) = load_note_cache_state(note_id) {
            self.note_caches.insert(note_id.to_owned(), cache);
        }
    }

    fn note_by_id(&self, id: &str) -> Option<NostrEvent> {
        self.home_notes.iter().find(|note| note.id == id).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::TimelineCachedData;
    use crate::{FeedScope, Route};
    use shadow_sdk::services::nostr::NostrEvent;

    fn test_note(id: &str, pubkey: &str, content: &str) -> NostrEvent {
        NostrEvent {
            content: content.to_owned(),
            created_at: 1_700_000_000,
            id: id.to_owned(),
            kind: 1,
            pubkey: pubkey.to_owned(),
            identifier: None,
            root_event_id: None,
            reply_to_event_id: None,
            references: Vec::new(),
            public_keys: Vec::new(),
        }
    }

    #[test]
    fn profile_state_falls_back_to_cached_home_notes_without_route_cache() {
        let cached_data = TimelineCachedData::from_home(
            FeedScope::no_contacts(),
            vec![test_note("note-1", "npub-alice", "note")],
        );

        let profile = cached_data.profile_state("npub-alice");

        assert_eq!(profile.notes.len(), 1);
        assert_eq!(profile.notes[0].id, "note-1");
        assert!(profile.summary.display_name.is_none());
    }

    #[test]
    fn note_state_falls_back_to_cached_note_without_route_cache() {
        let cached_data = TimelineCachedData::from_home(
            FeedScope::no_contacts(),
            vec![test_note("note-1", "npub-alice", "note")],
        );

        let note = cached_data.note_state("note-1");

        assert_eq!(
            note.note.as_ref().map(|event| event.id.as_str()),
            Some("note-1")
        );
        assert!(note.profile.display_name.is_none());
        assert!(note.thread.parent.is_none());
        assert!(note.thread.replies.is_empty());
    }

    #[test]
    fn push_onto_route_stack_skips_duplicate_top_route() {
        let mut cached_data = TimelineCachedData::from_home(FeedScope::no_contacts(), Vec::new());
        let mut route_stack = vec![Route::Timeline];

        cached_data.push_onto_route_stack(&mut route_stack, Route::Timeline, 18);

        assert_eq!(route_stack, vec![Route::Timeline]);
    }

    #[test]
    fn pop_route_stack_keeps_root_route() {
        let mut cached_data = TimelineCachedData::from_home(FeedScope::no_contacts(), Vec::new());
        let mut route_stack = vec![Route::Timeline];

        cached_data.pop_route_stack(&mut route_stack, 18);

        assert_eq!(route_stack, vec![Route::Timeline]);
    }

    #[test]
    fn reset_route_stack_replaces_existing_stack() {
        let mut cached_data = TimelineCachedData::from_home(FeedScope::no_contacts(), Vec::new());
        let mut route_stack = vec![Route::Timeline, Route::Account];

        cached_data.reset_route_stack(&mut route_stack, Route::Onboarding, 18);

        assert_eq!(route_stack, vec![Route::Onboarding]);
    }

    #[test]
    fn invalidate_routes_clears_route_local_state() {
        let mut cached_data = TimelineCachedData::from_home(FeedScope::no_contacts(), Vec::new());
        cached_data.explore_cache = Some(Default::default());
        cached_data
            .profile_caches
            .insert(String::from("npub-alice"), Default::default());
        cached_data
            .note_caches
            .insert(String::from("note-1"), Default::default());

        cached_data.invalidate_routes();

        assert!(cached_data.explore_cache.is_none());
        assert!(cached_data.profile_caches.is_empty());
        assert!(cached_data.note_caches.is_empty());
    }

    #[test]
    fn reload_home_without_account_resets_to_unavailable() {
        let mut cached_data = TimelineCachedData::from_home(
            FeedScope::no_contacts(),
            vec![test_note("note-1", "npub-alice", "note")],
        );
        cached_data.explore_cache = Some(Default::default());

        cached_data
            .reload_home(None, 18)
            .expect("reload without account");

        assert_eq!(cached_data.feed_scope(), &FeedScope::unavailable());
        assert!(cached_data.home_notes().is_empty());
        assert!(cached_data.explore_cache.is_none());
    }
}
