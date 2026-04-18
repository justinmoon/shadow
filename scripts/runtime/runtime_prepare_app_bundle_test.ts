import * as path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

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
    'import { listKind1 } from "@shadow/app-runtime-os";',
    'import { For } from "@shadow/app-runtime-solid";',
    'import "@shadow/sdk";',
  ].join("\n");

  const rewritten = rewriteRuntimeImportAliases(source);

  assertIncludes(rewritten, 'from "./shadow_sdk.js"', "rewritten source");
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
    assertIncludes(
      runner,
      "__initialLifecycleState",
      "bundle runner lifecycle bootstrap",
    );
    assert(
      await fileExists(path.join(bundleDir, "shadow_sdk.js")),
      "missing shadow_sdk.js",
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
