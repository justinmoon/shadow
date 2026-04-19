import { core } from "ext:core/mod.js";

function installShadowRuntimeOs() {
  const shadow = globalThis.Shadow ?? {};
  const os = shadow.os ?? {};
  const nostr = {
    query(query = {}) {
      return core.ops.op_runtime_nostr_query(normalizeQuery(query));
    },
    count(query = {}) {
      return core.ops.op_runtime_nostr_count(normalizeQuery(query));
    },
    getEvent(id) {
      return core.ops.op_runtime_nostr_get_event(String(id));
    },
    getReplaceable(query = {}) {
      return core.ops.op_runtime_nostr_get_replaceable(query);
    },
    listKind1(query = {}) {
      return core.ops.op_runtime_nostr_list_kind1(query);
    },
    syncKind1(request = {}) {
      return core.ops.op_runtime_nostr_sync_kind1(request);
    },
    publishKind1(request = {}) {
      return core.ops.op_runtime_nostr_publish_kind1(request);
    },
    async publishEphemeralKind1(request = {}) {
      return await core.ops.op_runtime_nostr_publish_ephemeral_kind1(request);
    },
  };

  globalThis.Shadow = {
    ...shadow,
    os: {
      ...os,
      nostr,
    },
  };
}

function normalizeQuery(query) {
  if (Array.isArray(query)) {
    if (query.length === 0) {
      return {};
    }
    if (query.length === 1) {
      return query[0];
    }
    throw new TypeError(
      "Shadow.os.nostr.query currently accepts a single filter object",
    );
  }
  if (query == null) {
    return {};
  }
  return query;
}

installShadowRuntimeOs();
