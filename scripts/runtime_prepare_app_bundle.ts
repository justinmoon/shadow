import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
  compileSolidModule,
  type CompileSolidModuleOptions,
} from "./runtime_compile_solid.ts";

const DEFAULT_CACHE_DIR = "build/runtime/app-document-smoke";
const DEFAULT_INPUT_PATH = "runtime/app-compile-smoke/app.tsx";
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
  const rendererPath = path.join(compiled.cacheDir, "shadow_runtime_solid.js");
  const runnerPath = path.join(compiled.cacheDir, "runner.js");

  await Deno.copyFile(rendererSourcePath, rendererPath);
  await Deno.writeTextFile(runnerPath, buildRunnerSource());

  console.log(
    JSON.stringify(
      {
        cacheDir: path.relative(cwd, compiled.cacheDir),
        cacheHit: compiled.cacheHit,
        inputPath: path.relative(cwd, compiled.inputPath),
        outputPath: path.relative(cwd, compiled.outputPath),
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
import { renderToDocument } from "./shadow_runtime_solid.js";

const renderApp = appModule.renderApp ?? appModule.default;
if (typeof renderApp !== "function") {
  throw new TypeError("compiled app module must export renderApp or default");
}

const documentPayload = renderToDocument(renderApp());
globalThis.RUNTIME_APP_DOCUMENT = documentPayload;
globalThis.RUNTIME_SMOKE_RESULT = JSON.stringify(documentPayload);
`;
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
