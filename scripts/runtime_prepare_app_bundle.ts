import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
  compileSolidModule,
  type CompileSolidModuleOptions,
  DEFAULT_MODULE_NAME,
} from "./runtime_compile_solid.ts";

const DEFAULT_CACHE_DIR = "build/runtime/app-counter";
const DEFAULT_INPUT_PATH = "runtime/app-counter/app.tsx";
const OS_MODULE_ALIAS = "@shadow/app-runtime-os";
const OS_MODULE_NAME = "./shadow_runtime_os.js";
const OS_SOURCE_PATH = "runtime/app-runtime/shadow_runtime_os.js";
const RENDERER_MODULE_NAME = "./shadow_runtime_solid.js";
const RENDERER_SOURCE_PATH = "runtime/app-runtime/shadow_runtime_solid.js";

type CliOptions = {
  cacheDir: string;
  expectCacheHit: boolean;
  inputPath: string;
};

async function main() {
  const options = parseArgs(Deno.args);
  const cwd = Deno.cwd();
  const compileOptions: CompileSolidModuleOptions = {
    cacheDir: options.cacheDir,
    expectCacheHit: options.expectCacheHit,
    inputPath: options.inputPath,
    moduleName: RENDERER_MODULE_NAME,
  };
  const compiled = await compileSolidModule(compileOptions);
  const rendererSourcePath = path.resolve(cwd, RENDERER_SOURCE_PATH);
  const osSourcePath = path.resolve(cwd, OS_SOURCE_PATH);
  const rendererPath = path.join(compiled.cacheDir, "shadow_runtime_solid.js");
  const osPath = path.join(compiled.cacheDir, "shadow_runtime_os.js");
  const runnerPath = path.join(compiled.cacheDir, "runner.js");
  const bundlePath = path.join(compiled.cacheDir, "bundle.js");

  await Deno.copyFile(rendererSourcePath, rendererPath);
  await Deno.copyFile(osSourcePath, osPath);
  await rewriteRuntimeAliasImports(compiled.outputPath);
  await Deno.writeTextFile(runnerPath, buildRunnerSource());
  await bundleRunner(runnerPath, bundlePath);

  console.log(
    JSON.stringify(
      {
        bundlePath: path.relative(cwd, bundlePath),
        cacheDir: path.relative(cwd, compiled.cacheDir),
        cacheHit: compiled.cacheHit,
        inputPath: path.relative(cwd, compiled.inputPath),
        outputPath: path.relative(cwd, compiled.outputPath),
        osPath: path.relative(cwd, osPath),
        rendererPath: path.relative(cwd, rendererPath),
        runnerPath: path.relative(cwd, runnerPath),
      },
      null,
      2,
    ),
  );
}

function buildRunnerSource(): string {
  return `import * as appModule from "./app.js";
import { ensureShadowRuntimeOs } from "./shadow_runtime_os.js";
import { createRuntimeApp } from "./shadow_runtime_solid.js";

const renderApp = appModule.renderApp ?? appModule.default;
if (typeof renderApp !== "function") {
  throw new TypeError("compiled app module must export renderApp or default");
}
const runtimeDocumentCss =
  typeof appModule.runtimeDocumentCss === "string"
    ? appModule.runtimeDocumentCss
    : null;

ensureShadowRuntimeOs();
const runtimeApp = createRuntimeApp(renderApp, { css: runtimeDocumentCss });
const documentPayload = runtimeApp.renderDocument();
globalThis.SHADOW_RUNTIME_APP = runtimeApp;
globalThis.SHADOW_RUNTIME_HOST = {
  dispatch(event) {
    return JSON.stringify(runtimeApp.dispatch(event));
  },
  render() {
    return JSON.stringify(runtimeApp.renderDocument());
  },
};
globalThis.RUNTIME_APP_DOCUMENT = documentPayload;
globalThis.RUNTIME_SMOKE_RESULT = JSON.stringify(documentPayload);
`;
}

async function rewriteRuntimeAliasImports(outputPath: string) {
  const output = await Deno.readTextFile(outputPath);
  const rewritten = output
    .replaceAll(
      `from "${DEFAULT_MODULE_NAME}"`,
      `from "${RENDERER_MODULE_NAME}"`,
    )
    .replaceAll(
      `from '${DEFAULT_MODULE_NAME}'`,
      `from '${RENDERER_MODULE_NAME}'`,
    )
    .replaceAll(`from "${OS_MODULE_ALIAS}"`, `from "${OS_MODULE_NAME}"`)
    .replaceAll(`from '${OS_MODULE_ALIAS}'`, `from '${OS_MODULE_NAME}'`);

  if (rewritten !== output) {
    await Deno.writeTextFile(outputPath, rewritten);
  }
}

async function bundleRunner(runnerPath: string, bundlePath: string) {
  const command = new Deno.Command(Deno.execPath(), {
    args: [
      "bundle",
      "--quiet",
      "--platform",
      "deno",
      "--packages",
      "bundle",
      "--output",
      bundlePath,
      runnerPath,
    ],
    stderr: "piped",
    stdout: "piped",
  });
  const result = await command.output();
  if (result.success) {
    return;
  }

  const stderr = new TextDecoder().decode(result.stderr).trim();
  const stdout = new TextDecoder().decode(result.stdout).trim();
  throw new Error(stderr || stdout || `bundle failed for ${runnerPath}`);
}

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    cacheDir: DEFAULT_CACHE_DIR,
    expectCacheHit: false,
    inputPath: DEFAULT_INPUT_PATH,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    switch (arg) {
      case "--input":
        options.inputPath = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--cache-dir":
        options.cacheDir = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--expect-cache-hit":
        options.expectCacheHit = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  return options;
}

function requireValue(flag: string, value: string | undefined): string {
  if (!value) {
    throw new Error(`missing value for ${flag}`);
  }
  return value;
}

if (import.meta.main) {
  try {
    await main();
  } catch (error) {
    const scriptPath = fileURLToPath(import.meta.url);
    const label = path.relative(Deno.cwd(), scriptPath) || scriptPath;
    const message = error instanceof Error ? error.message : String(error);
    console.error(`${label}: ${message}`);
    Deno.exit(1);
  }
}
