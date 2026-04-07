const DEFAULT_PUBLISH_PUBKEY = "npub-shadow-os";
const INITIAL_KIND1_NOTES = [
  {
    content: "local cache warmed from the system service",
    created_at: 1_700_000_003,
    id: "shadow-note-3",
    kind: 1,
    pubkey: "npub-feed-b",
  },
  {
    content: "relay subscriptions will live below app code",
    created_at: 1_700_000_002,
    id: "shadow-note-2",
    kind: 1,
    pubkey: "npub-feed-a",
  },
  {
    content: "shadow os owns nostr for tiny apps",
    created_at: 1_700_000_001,
    id: "shadow-note-1",
    kind: 1,
    pubkey: "npub-feed-a",
  },
];

export function ensureShadowRuntimeOs() {
  const shadow = globalThis.Shadow ?? {};
  const os = shadow.os ?? {};
  const nextOs = { ...os };
  let changed = false;

  if (!nextOs.nostr) {
    nextOs.nostr = createMockNostrApi();
    changed = true;
  }
  if (!nextOs.audio) {
    nextOs.audio = createMockAudioApi();
    changed = true;
  }

  if (!changed) {
    return globalThis.Shadow;
  }

  return installShadowRuntimeOs(nextOs);
}

export function listKind1(query = {}) {
  return getNostrApi().listKind1(query);
}

export function syncKind1(request = {}) {
  return getNostrApi().syncKind1(request);
}

export function publishKind1(request) {
  return getNostrApi().publishKind1(request);
}

export function publishEphemeralKind1(request) {
  return getNostrApi().publishEphemeralKind1(request);
}

export function createPlayer(request = {}) {
  return getAudioApi().createPlayer(request);
}

export function play(request) {
  return getAudioApi().play(request);
}

export function pause(request) {
  return getAudioApi().pause(request);
}

export function stop(request) {
  return getAudioApi().stop(request);
}

export function release(request) {
  return getAudioApi().release(request);
}

export function getStatus(request) {
  return getAudioApi().getStatus(request);
}

function getNostrApi() {
  const nostr = globalThis.Shadow?.os?.nostr;
  if (!nostr) {
    throw new Error("Shadow.os.nostr is not installed");
  }
  return nostr;
}

function getAudioApi() {
  const audio = globalThis.Shadow?.os?.audio;
  if (!audio) {
    throw new Error("Shadow.os.audio is not installed");
  }
  return audio;
}

function installShadowRuntimeOs(os) {
  globalThis.Shadow = {
    ...(globalThis.Shadow ?? {}),
    os,
  };
  return globalThis.Shadow;
}

function createMockNostrApi() {
  let events = INITIAL_KIND1_NOTES.map(cloneKind1Event);
  let latestTimestamp = Math.max(...events.map((event) => event.created_at));
  let sequence = events.length;

  return {
    listKind1(query = {}) {
      return queryKind1Events(events, query);
    },
    syncKind1(request = {}) {
      const relayUrls = Array.isArray(request?.relayUrls) &&
          request.relayUrls.length > 0
        ? request.relayUrls.map(String)
        : ["wss://relay.primal.net/", "wss://relay.damus.io/"];
      return {
        fetchedCount: 0,
        importedCount: 0,
        relayUrls,
      };
    },
    publishKind1(request) {
      const content = typeof request?.content === "string"
        ? request.content.trim()
        : "";
      if (!content) {
        throw new TypeError("nostr.publishKind1 requires non-empty content");
      }

      sequence += 1;
      latestTimestamp += 1;
      const event = {
        content,
        created_at: latestTimestamp,
        id: `shadow-note-${sequence}`,
        kind: 1,
        pubkey: typeof request?.pubkey === "string" && request.pubkey
          ? request.pubkey
          : DEFAULT_PUBLISH_PUBKEY,
      };
      events = [event, ...events];
      return cloneKind1Event(event);
    },
    async publishEphemeralKind1(request) {
      const content = typeof request?.content === "string"
        ? request.content.trim()
        : "";
      if (!content) {
        throw new TypeError(
          "nostr.publishEphemeralKind1 requires non-empty content",
        );
      }

      sequence += 1;
      latestTimestamp += 1;
      const relayUrls = Array.isArray(request?.relayUrls) &&
          request.relayUrls.length > 0
        ? request.relayUrls.map(String)
        : ["wss://relay.primal.net/", "wss://relay.damus.io/"];
      const eventIdHex = `mock-gm-${sequence.toString().padStart(4, "0")}`;
      const noteId = `note1mockgm${sequence.toString().padStart(4, "0")}`;
      const primalUrl = `https://primal.net/e/${noteId}`;
      const event = {
        content,
        created_at: latestTimestamp,
        id: eventIdHex,
        kind: 1,
        pubkey: DEFAULT_PUBLISH_PUBKEY,
      };
      events = [event, ...events];

      return {
        content,
        createdAt: latestTimestamp,
        failedRelays: [],
        id: eventIdHex,
        noteId,
        npub: DEFAULT_PUBLISH_PUBKEY,
        primalUrl,
        publishedRelays: relayUrls,
        qrRows: buildMockQrRows(primalUrl),
        relayUrls,
      };
    },
  };
}

function createMockAudioApi() {
  let nextId = 1;
  const players = new Map();

  return {
    async createPlayer(request = {}) {
      const source = normalizeAudioSource(request?.source);
      const status = buildAudioStatus({
        backend: "mock",
        durationMs: source.durationMs,
        frequencyHz: source.frequencyHz,
        id: nextId,
        path: source.path,
        sourceKind: source.kind,
        state: "idle",
      });
      players.set(nextId, {
        durationMs: source.durationMs,
        elapsedBeforePauseMs: 0,
        frequencyHz: source.frequencyHz,
        finishedAtMs: null,
        path: source.path,
        startedAtMs: null,
        sourceKind: source.kind,
        state: "idle",
      });
      nextId += 1;
      return status;
    },
    async play(request = {}) {
      const player = requireAudioPlayer(players, request?.id, "audio.play");
      reconcileMockAudioPlayer(player);
      if (player.state !== "playing") {
        if (player.state === "paused") {
          player.startedAtMs = Date.now();
        } else {
          player.startedAtMs = Date.now();
          player.elapsedBeforePauseMs = 0;
          player.finishedAtMs = null;
        }
        player.state = "playing";
      }
      return buildAudioStatusFromMockPlayer(request.id, player);
    },
    async pause(request = {}) {
      const player = requireAudioPlayer(players, request?.id, "audio.pause");
      reconcileMockAudioPlayer(player);
      if (
        player.state === "playing" && typeof player.startedAtMs === "number"
      ) {
        player.elapsedBeforePauseMs += Date.now() - player.startedAtMs;
        player.startedAtMs = null;
        player.state = "paused";
      }
      return buildAudioStatusFromMockPlayer(request.id, player);
    },
    async stop(request = {}) {
      const player = requireAudioPlayer(players, request?.id, "audio.stop");
      player.elapsedBeforePauseMs = 0;
      player.finishedAtMs = null;
      player.startedAtMs = null;
      player.state = "stopped";
      return buildAudioStatusFromMockPlayer(request.id, player);
    },
    async release(request = {}) {
      const player = requireAudioPlayer(players, request?.id, "audio.release");
      player.elapsedBeforePauseMs = 0;
      player.finishedAtMs = null;
      player.startedAtMs = null;
      player.state = "released";
      players.delete(request.id);
      return buildAudioStatusFromMockPlayer(request.id, player);
    },
    async getStatus(request = {}) {
      const player = requireAudioPlayer(
        players,
        request?.id,
        "audio.getStatus",
      );
      reconcileMockAudioPlayer(player);
      return buildAudioStatusFromMockPlayer(request.id, player);
    },
  };
}

function normalizeAudioSource(source) {
  const kind = typeof source?.kind === "string" && source.kind.trim()
    ? source.kind.trim()
    : "tone";
  const durationMs = normalizePositiveNumber(
    source?.durationMs,
    2400,
    "durationMs",
  );
  if (kind === "tone") {
    const frequencyHz = normalizePositiveNumber(
      source?.frequencyHz,
      440,
      "frequencyHz",
    );
    return {
      durationMs,
      frequencyHz,
      kind,
      path: undefined,
    };
  }
  if (kind === "file") {
    const path = normalizeNonEmptyString(source?.path, "path");
    return {
      durationMs,
      frequencyHz: undefined,
      kind,
      path,
    };
  }

  throw new TypeError(
    `audio.createPlayer does not support source kind: ${kind}`,
  );
}

function normalizePositiveNumber(value, fallback, label) {
  if (value == null) {
    return fallback;
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new TypeError(`audio.createPlayer requires positive ${label}`);
  }
  return Math.round(value);
}

function normalizeNonEmptyString(value, label) {
  if (typeof value !== "string" || !value.trim()) {
    throw new TypeError(`audio.createPlayer requires non-empty ${label}`);
  }
  return value.trim();
}

function requireAudioPlayer(players, id, opName) {
  if (!Number.isInteger(id) || id <= 0 || !players.has(id)) {
    throw new TypeError(`${opName} requires a known positive integer id`);
  }
  return players.get(id);
}

function reconcileMockAudioPlayer(player) {
  if (player.state !== "playing" || typeof player.startedAtMs !== "number") {
    return;
  }

  const elapsedMs = player.elapsedBeforePauseMs +
    (Date.now() - player.startedAtMs);
  if (elapsedMs < player.durationMs) {
    return;
  }

  player.elapsedBeforePauseMs = player.durationMs;
  player.finishedAtMs = Date.now();
  player.startedAtMs = null;
  player.state = "completed";
}

function buildAudioStatusFromMockPlayer(id, player) {
  return buildAudioStatus({
    backend: "mock",
    durationMs: player.durationMs,
    frequencyHz: player.frequencyHz,
    id,
    path: player.path,
    sourceKind: player.sourceKind,
    state: player.state,
  });
}

function buildAudioStatus({
  backend,
  durationMs,
  frequencyHz,
  id,
  path,
  sourceKind,
  state,
}) {
  return {
    backend,
    durationMs,
    frequencyHz,
    id,
    path,
    sourceKind,
    state,
  };
}

function queryKind1Events(events, query) {
  let filtered = events.filter((event) => event.kind === 1);
  if (Array.isArray(query.authors) && query.authors.length > 0) {
    const authors = new Set(query.authors);
    filtered = filtered.filter((event) => authors.has(event.pubkey));
  }
  if (typeof query.since === "number") {
    filtered = filtered.filter((event) => event.created_at >= query.since);
  }
  if (typeof query.until === "number") {
    filtered = filtered.filter((event) => event.created_at <= query.until);
  }

  filtered = [...filtered].sort((left, right) =>
    right.created_at - left.created_at
  );

  if (typeof query.limit === "number" && query.limit >= 0) {
    filtered = filtered.slice(0, query.limit);
  }

  return filtered.map(cloneKind1Event);
}

function cloneKind1Event(event) {
  return {
    content: event.content,
    created_at: event.created_at,
    id: event.id,
    kind: event.kind,
    pubkey: event.pubkey,
  };
}

function buildMockQrRows(data) {
  const size = 29;
  const rows = [];
  let seed = 0;
  for (const char of data) {
    seed = (seed * 131 + char.charCodeAt(0)) >>> 0;
  }

  for (let y = 0; y < size; y += 1) {
    let row = "";
    for (let x = 0; x < size; x += 1) {
      const finder = isFinderModule(x, y, size);
      if (finder != null) {
        row += finder ? "1" : "0";
        continue;
      }

      seed = (seed * 1664525 + 1013904223) >>> 0;
      row += (seed & 1) === 0 ? "1" : "0";
    }
    rows.push(row);
  }
  return rows;
}

function isFinderModule(x, y, size) {
  for (const [originX, originY] of [[0, 0], [size - 7, 0], [0, size - 7]]) {
    if (x < originX || y < originY || x >= originX + 7 || y >= originY + 7) {
      continue;
    }

    const localX = x - originX;
    const localY = y - originY;
    const outer = localX === 0 || localY === 0 || localX === 6 || localY === 6;
    const inner = localX >= 2 && localX <= 4 && localY >= 2 && localY <= 4;
    return outer || inner;
  }

  return null;
}
