import * as path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type {
  NostrAccountSummary,
  NostrPublishReceipt,
  NostrPublishRequest,
} from "@shadow/sdk/nostr";

import {
  prepareRuntimeAppBundle,
  rewriteRuntimeImportAliases,
} from "./runtime_prepare_app_bundle.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

function assertIncludes(value: string, expected: string, label: string) {
  assert(
    value.includes(expected),
    `${label} should include ${JSON.stringify(expected)}`,
  );
}

function assertNotIncludes(value: string, expected: string, label: string) {
  assert(
    !value.includes(expected),
    `${label} should not include ${JSON.stringify(expected)}`,
  );
}

function repoRoot() {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
}

Deno.test("rewriteRuntimeImportAliases rewrites sdk and legacy runtime imports", () => {
  const source = [
    'import { createSignal } from "@shadow/sdk";',
    'import type { NostrEvent } from "@shadow/sdk/nostr";',
    'import { listKind1 } from "@shadow/app-runtime-os";',
    'import { For } from "@shadow/app-runtime-solid";',
    'import "@shadow/sdk";',
  ].join("\n");

  const rewritten = rewriteRuntimeImportAliases(source);

  assertIncludes(rewritten, 'from "./shadow_sdk.js"', "rewritten source");
  assertIncludes(
    rewritten,
    'from "./shadow_sdk_nostr.js"',
    "rewritten source",
  );
  assertIncludes(
    rewritten,
    'from "./shadow_runtime_os.js"',
    "rewritten source",
  );
  assertIncludes(
    rewritten,
    'from "./shadow_runtime_solid.js"',
    "rewritten source",
  );
  assertIncludes(rewritten, 'import "./shadow_sdk.js"', "rewritten source");
  assertNotIncludes(rewritten, "@shadow/sdk", "rewritten source");
  assertNotIncludes(rewritten, "@shadow/sdk/nostr", "rewritten source");
  assertNotIncludes(rewritten, "@shadow/app-runtime-os", "rewritten source");
  assertNotIncludes(
    rewritten,
    "@shadow/app-runtime-solid",
    "rewritten source",
  );
});

Deno.test("prepareRuntimeAppBundle stages sdk entrypoint files", async () => {
  const cwd = repoRoot();
  const cacheDir = await Deno.makeTempDir({
    prefix: "shadow-runtime-prepare-app-bundle-",
  });

  try {
    const prepared = await prepareRuntimeAppBundle({
      cacheDir,
      cwd,
      inputPath: "runtime/app-counter/app.tsx",
    });

    const outputPath = path.resolve(cwd, prepared.outputPath);
    const runnerPath = path.resolve(cwd, prepared.runnerPath);
    const bundlePath = path.resolve(cwd, prepared.bundlePath);
    const bundleDir = path.resolve(cwd, prepared.bundleDir);
    const output = await Deno.readTextFile(outputPath);
    const runner = await Deno.readTextFile(runnerPath);

    assertIncludes(output, 'from "./shadow_sdk.js"', "compiled app output");
    assertNotIncludes(output, "@shadow/sdk", "compiled app output");
    assertIncludes(runner, 'from "./shadow_sdk.js"', "bundle runner");
    assertIncludes(
      runner,
      "platformLifecycleChange",
      "bundle runner lifecycle bridge",
    );
    assert(
      await fileExists(path.join(bundleDir, "shadow_sdk.js")),
      "missing shadow_sdk.js",
    );
    assert(
      await fileExists(path.join(bundleDir, "shadow_sdk_nostr.js")),
      "missing shadow_sdk_nostr.js",
    );
    assert(
      await fileExists(path.join(bundleDir, "shadow_sdk_services.js")),
      "missing shadow_sdk_services.js",
    );
    assert(
      await fileExists(path.join(bundleDir, "shadow_runtime_os.js")),
      "missing shadow_runtime_os.js",
    );
    assert(
      await fileExists(path.join(bundleDir, "shadow_runtime_solid.js")),
      "missing shadow_runtime_solid.js",
    );
    assert(await fileExists(bundlePath), "missing bundle.js");
  } finally {
    await Deno.remove(cacheDir, { recursive: true });
  }
});

Deno.test("shadow sdk lifecycle state honors runner-seeded initial state", async () => {
  const cwd = repoRoot();
  const lifecycleStateKey = Symbol.for("shadow.runtime.lifecycle.state");
  const runtimeGlobal = globalThis as typeof globalThis & {
    Shadow?: Record<string, unknown>;
    [key: symbol]: unknown;
  };
  const moduleUrl = `${
    pathToFileURL(path.resolve(
      cwd,
      "runtime/app-runtime/shadow_sdk_services.js",
    )).href
  }?test=${crypto.randomUUID()}`;

  runtimeGlobal.Shadow = {
    os: {},
    __initialLifecycleState: "background",
  };
  delete runtimeGlobal[lifecycleStateKey];

  try {
    const services = await import(moduleUrl);
    assert(
      services.getLifecycleState() === "background",
      "seeded lifecycle state should be background",
    );
  } finally {
    delete runtimeGlobal.Shadow;
    delete runtimeGlobal[lifecycleStateKey];
  }
});

Deno.test("shadow sdk nostr account helpers delegate to the runtime host", async () => {
  const cwd = repoRoot();
  const runtimeGlobal = globalThis as typeof globalThis & {
    Shadow?: Record<string, unknown>;
  };
  const moduleUrl = `${
    pathToFileURL(path.resolve(
      cwd,
      "runtime/app-runtime/shadow_sdk_services.js",
    )).href
  }?test=${crypto.randomUUID()}`;

  const importedCalls: string[] = [];
  const accountFixture = (
    npub: string,
    source: NostrAccountSummary["source"],
  ): NostrAccountSummary => ({ npub, source });
  runtimeGlobal.Shadow = {
    os: {
      nostr: {
        currentAccount: async () =>
          accountFixture("npub1testcurrent", "generated"),
        generateAccount: async () =>
          accountFixture("npub1testgenerated", "generated"),
        importAccountNsec: async (nsec: string) => {
          importedCalls.push(nsec);
          return accountFixture("npub1testimported", "imported");
        },
      },
    },
  };

  try {
    const services = await import(moduleUrl);
    const current = await services.currentNostrAccount();
    const generated = await services.generateNostrAccount();
    const imported = await services.importNostrAccountNsec("nsec1test");

    assert(
      current.npub === "npub1testcurrent",
      "current account should round-trip",
    );
    assert(
      generated.npub === "npub1testgenerated",
      "generated account should round-trip",
    );
    assert(
      imported.npub === "npub1testimported",
      "imported account should round-trip",
    );
    assert(
      JSON.stringify(importedCalls) === JSON.stringify(["nsec1test"]),
      "importAccountNsec should forward the provided nsec",
    );

    const nostrCurrent = await services.nostr.currentAccount();
    assert(
      nostrCurrent.npub === "npub1testcurrent",
      "nostr.currentAccount should be exposed on the grouped api",
    );
  } finally {
    delete runtimeGlobal.Shadow;
  }
});

Deno.test("shadow sdk nostr publish helper delegates to the runtime host", async () => {
  const cwd = repoRoot();
  const runtimeGlobal = globalThis as typeof globalThis & {
    Shadow?: Record<string, unknown>;
  };
  const moduleUrl = `${
    pathToFileURL(path.resolve(
      cwd,
      "runtime/app-runtime/shadow_sdk_services.js",
    )).href
  }?test=${crypto.randomUUID()}`;

  const publishCalls: NostrPublishRequest[] = [];
  const receiptFixture = (
    content: string,
  ): NostrPublishReceipt => ({
    event: {
      content,
      created_at: 1_700_000_001,
      id: "test-event-id",
      kind: 1,
      pubkey: "npub1testpublish",
    },
    relayUrls: ["wss://relay.test/"],
    publishedRelays: ["wss://relay.test/"],
    failedRelays: [],
  });
  runtimeGlobal.Shadow = {
    os: {
      nostr: {
        publish: async (request: NostrPublishRequest) => {
          publishCalls.push(request);
          return receiptFixture(request.content);
        },
      },
    },
  };

  try {
    const services = await import(moduleUrl);
    const receipt = await services.publishNostr({
      kind: 1,
      content: "gm",
      replyToEventId: "reply-id",
    });

    assert(publishCalls.length === 1, "publish should be forwarded exactly once");
    assert(
      publishCalls[0].replyToEventId === "reply-id",
      "reply target should round-trip",
    );
    assert(receipt.event.content === "gm", "publish receipt should round-trip");
  } finally {
    delete runtimeGlobal.Shadow;
  }
});

Deno.test("shadow sdk getNostrReplaceable accepts object and legacy positional forms", async () => {
  const cwd = repoRoot();
  const runtimeGlobal = globalThis as typeof globalThis & {
    Shadow?: Record<string, unknown>;
  };
  const moduleUrl = `${
    pathToFileURL(path.resolve(
      cwd,
      "runtime/app-runtime/shadow_sdk_services.js",
    )).href
  }?test=${crypto.randomUUID()}`;

  const calls: unknown[] = [];
  runtimeGlobal.Shadow = {
    os: {
      nostr: {
        getReplaceable: async (query: unknown) => {
          calls.push(query);
          return null;
        },
      },
    },
  };

  try {
    const services = await import(moduleUrl);
    await services.getNostrReplaceable({
      kind: 0,
      pubkey: "npub1testobject",
      identifier: "profile",
    });
    await services.getNostrReplaceable(30023, "npub1testlegacy", "note");

    assert(
      JSON.stringify(calls) === JSON.stringify([
        { kind: 0, pubkey: "npub1testobject", identifier: "profile" },
        { kind: 30023, pubkey: "npub1testlegacy", identifier: "note" },
      ]),
      "getNostrReplaceable should normalize both public call forms",
    );
  } finally {
    delete runtimeGlobal.Shadow;
  }
});

Deno.test("shadow sdk clipboard helpers delegate to the runtime host", async () => {
  const cwd = repoRoot();
  const runtimeGlobal = globalThis as typeof globalThis & {
    Shadow?: Record<string, unknown>;
  };
  const moduleUrl = `${
    pathToFileURL(path.resolve(
      cwd,
      "runtime/app-runtime/shadow_sdk_services.js",
    )).href
  }?test=${crypto.randomUUID()}`;

  const writes: string[] = [];
  runtimeGlobal.Shadow = {
    os: {
      clipboard: {
        writeText: async (text: string) => {
          writes.push(text);
        },
      },
    },
  };

  try {
    const services = await import(moduleUrl);
    await services.writeClipboardText("npub1shadowclipboard");
    await services.clipboard.writeText("npub1shadowgrouped");

    assert(
      JSON.stringify(writes) ===
        JSON.stringify(["npub1shadowclipboard", "npub1shadowgrouped"]),
      "clipboard helpers should forward write requests to the runtime host",
    );
  } finally {
    delete runtimeGlobal.Shadow;
  }
});

Deno.test("shadow sdk window metrics honors runner-seeded initial metrics", async () => {
  const cwd = repoRoot();
  const windowMetricsKey = Symbol.for("shadow.runtime.window_metrics");
  const runtimeGlobal = globalThis as typeof globalThis & {
    Shadow?: Record<string, unknown>;
    [key: symbol]: unknown;
  };
  const moduleUrl = `${
    pathToFileURL(path.resolve(
      cwd,
      "runtime/app-runtime/shadow_sdk_services.js",
    )).href
  }?test=${crypto.randomUUID()}`;

  runtimeGlobal.Shadow = {
    os: {},
    __initialWindowMetrics: {
      surfaceWidth: 540,
      surfaceHeight: 1042,
      safeAreaInsets: {
        left: 8,
        top: 12,
        right: 6,
        bottom: 4,
      },
    },
  };
  delete runtimeGlobal[windowMetricsKey];

  try {
    const services = await import(moduleUrl);
    const metrics = services.getWindowMetrics();
    assert(metrics.surfaceWidth === 540, "seeded surface width should match");
    assert(
      metrics.surfaceHeight === 1042,
      "seeded surface height should match",
    );
    assert(
      JSON.stringify(metrics.safeAreaInsets) ===
        JSON.stringify({ left: 8, top: 12, right: 6, bottom: 4 }),
      "seeded safe area should match",
    );
  } finally {
    delete runtimeGlobal.Shadow;
    delete runtimeGlobal[windowMetricsKey];
  }
});

Deno.test(
  "shadow sdk window metrics throws when the runtime host omits them",
  async () => {
    const cwd = repoRoot();
    const windowMetricsKey = Symbol.for("shadow.runtime.window_metrics");
    const runtimeGlobal = globalThis as typeof globalThis & {
      Shadow?: Record<string, unknown>;
      [key: symbol]: unknown;
    };
    const moduleUrl = `${
      pathToFileURL(path.resolve(
        cwd,
        "runtime/app-runtime/shadow_sdk_services.js",
      )).href
    }?test=${crypto.randomUUID()}`;

    runtimeGlobal.Shadow = { os: {} };
    delete runtimeGlobal[windowMetricsKey];

    try {
      const services = await import(moduleUrl);
      let error: unknown = null;
      try {
        services.getWindowMetrics();
      } catch (thrown) {
        error = thrown;
      }
      assert(error instanceof Error, "missing window metrics should throw");
      assertIncludes(
        error.message,
        "window metrics are not installed by the runtime host",
        "window metrics error",
      );
    } finally {
      delete runtimeGlobal.Shadow;
      delete runtimeGlobal[windowMetricsKey];
    }
  },
);

async function fileExists(filePath: string): Promise<boolean> {
  try {
    const stat = await Deno.stat(filePath);
    return stat.isFile;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return false;
    }
    throw error;
  }
}
