import { transformAsync } from "npm:@babel/core@7.28.5";
import presetTypescript from "npm:@babel/preset-typescript@7.28.5";
import presetSolid from "npm:babel-preset-solid@1.9.10";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

export const GENERATE_MODE = "universal";
export const DEFAULT_CACHE_DIR = "build/runtime/app-compile-smoke";
export const DEFAULT_MODULE_NAME = "@shadow/app-runtime-solid";
const EXPECTED_TOKENS = [
  "createElement",
  "createTextNode",
  "setProp",
];

type CliOptions = {
  inputPath: string;
  cacheDir: string;
  moduleName: string;
  expectCacheHit: boolean;
};

type CompileMetadata = {
  cacheKey: string;
  configHash: string;
  generate: string;
  inputPath: string;
  moduleName: string;
  outputPath: string;
  sourceHash: string;
  toolchain: {
    babelCore: string;
    presetSolid: string;
    presetTypescript: string;
  };
};

const toolchain = {
  babelCore: "7.28.5",
  presetSolid: "1.9.10",
  presetTypescript: "7.28.5",
};

export type CompileSolidModuleOptions = {
  cwd?: string;
  inputPath: string;
  cacheDir?: string;
  moduleName?: string;
  expectCacheHit?: boolean;
};

export type CompileSolidModuleResult = {
  cacheDir: string;
  cacheHit: boolean;
  cacheKey: string;
  inputPath: string;
  metadataPath: string;
  moduleName: string;
  outputPath: string;
};

export async function compileSolidModule(
  options: CompileSolidModuleOptions,
): Promise<CompileSolidModuleResult> {
  const cwd = options.cwd ?? Deno.cwd();
  const moduleName = options.moduleName ?? DEFAULT_MODULE_NAME;
  const expectCacheHit = options.expectCacheHit ?? false;
  const inputPath = path.resolve(cwd, options.inputPath);
  const cacheRoot = path.resolve(cwd, options.cacheDir ?? DEFAULT_CACHE_DIR);
  const source = await Deno.readTextFile(inputPath);
  const sourceHash = await sha256Hex(source);
  const configHash = await sha256Hex(
    JSON.stringify({
      generate: GENERATE_MODE,
      inputPath: path.relative(cwd, inputPath),
      moduleName,
      toolchain,
    }),
  );
  const cacheKey = await sha256Hex(JSON.stringify({ configHash, sourceHash }));
  const cacheDir = path.join(cacheRoot, cacheKey);
  const outputPath = path.join(
    cacheDir,
    `${path.basename(inputPath, path.extname(inputPath))}.js`,
  );
  const metadataPath = path.join(cacheDir, "metadata.json");

  let cacheHit = false;
  if (await fileExists(outputPath) && await fileExists(metadataPath)) {
    cacheHit = true;
  } else {
    const result = await transformAsync(source, {
      babelrc: false,
      configFile: false,
      filename: inputPath,
      presets: [
        [
          presetSolid,
          {
            generate: GENERATE_MODE,
            moduleName,
          },
        ],
        [
          presetTypescript,
          {
            allExtensions: true,
            isTSX: true,
          },
        ],
      ],
      sourceType: "module",
    });
    const code = result?.code;
    if (!code) {
      throw new Error(`solid compile produced no output for ${inputPath}`);
    }

    validateOutput(code, moduleName);
    await Deno.mkdir(cacheDir, { recursive: true });
    await Deno.writeTextFile(outputPath, `${code}\n`);

    const metadata: CompileMetadata = {
      cacheKey,
      configHash,
      generate: GENERATE_MODE,
      inputPath: path.relative(cwd, inputPath),
      moduleName,
      outputPath: path.relative(cwd, outputPath),
      sourceHash,
      toolchain,
    };
    await Deno.writeTextFile(
      metadataPath,
      `${JSON.stringify(metadata, null, 2)}\n`,
    );
  }

  if (expectCacheHit && !cacheHit) {
    throw new Error(
      `expected a cache hit for ${path.relative(cwd, inputPath)}`,
    );
  }

  const outputCode = await Deno.readTextFile(outputPath);
  validateOutput(outputCode, moduleName);

  return {
    cacheDir,
    cacheHit,
    cacheKey,
    inputPath,
    metadataPath,
    moduleName,
    outputPath,
  };
}

async function main() {
  const options = parseArgs(Deno.args);
  const result = await compileSolidModule(options);
  const cwd = options.cwd ?? Deno.cwd();
  console.log(
    JSON.stringify(
      {
        cacheDir: path.relative(cwd, result.cacheDir),
        cacheHit: result.cacheHit,
        cacheKey: result.cacheKey,
        inputPath: path.relative(cwd, result.inputPath),
        metadataPath: path.relative(cwd, result.metadataPath),
        moduleName: result.moduleName,
        outputPath: path.relative(cwd, result.outputPath),
      },
      null,
      2,
    ),
  );
}

function parseArgs(args: string[]): CliOptions & { cwd?: string } {
  const options: CliOptions & { cwd?: string } = {
    cacheDir: DEFAULT_CACHE_DIR,
    expectCacheHit: false,
    inputPath: "",
    moduleName: DEFAULT_MODULE_NAME,
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
      case "--module-name":
        options.moduleName = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--expect-cache-hit":
        options.expectCacheHit = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (!options.inputPath) {
    throw new Error("missing required --input argument");
  }

  return options;
}

function requireValue(flag: string, value: string | undefined): string {
  if (!value) {
    throw new Error(`missing value for ${flag}`);
  }
  return value;
}

function validateOutput(code: string, moduleName: string) {
  const expectedSnippets = [`from "${moduleName}"`, ...EXPECTED_TOKENS];
  for (const snippet of expectedSnippets) {
    if (!code.includes(snippet)) {
      throw new Error(`compiled output is missing ${snippet}`);
    }
  }
}

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

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
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
