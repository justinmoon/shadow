export type NostrAccountSource = "generated" | "imported" | "env";

export type NostrAccountSummary = {
  npub: string;
  source: NostrAccountSource;
};

export type NostrEventReference = {
  eventId: string;
  marker?: string;
};

export type NostrEvent = {
  content: string;
  created_at: number;
  id: string;
  kind: number;
  pubkey: string;
  identifier?: string;
  rootEventId?: string;
  replyToEventId?: string;
  references?: NostrEventReference[];
};

export type NostrQuery = {
  ids?: string[];
  authors?: string[];
  kinds?: number[];
  referencedIds?: string[];
  replyToIds?: string[];
  since?: number;
  until?: number;
  limit?: number;
};

export type NostrReplaceableQuery = {
  kind: number;
  pubkey: string;
  identifier?: string;
};

export type NostrSyncRequest = NostrQuery & {
  relayUrls?: string[];
  timeoutMs?: number;
};

export type NostrSyncReceipt = {
  relayUrls: string[];
  fetchedCount: number;
  importedCount: number;
};

export type NostrPublishRequest = {
  kind: number;
  content: string;
  rootEventId?: string;
  replyToEventId?: string;
  relayUrls?: string[];
  timeoutMs?: number;
};

export type NostrPublishedRelayFailure = {
  relayUrl: string;
  error: string;
};

export type NostrPublishReceipt = {
  event: NostrEvent;
  relayUrls: string[];
  publishedRelays: string[];
  failedRelays: NostrPublishedRelayFailure[];
};
