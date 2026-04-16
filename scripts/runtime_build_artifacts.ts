import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
  type PreparedRuntimeAppBundle,
  prepareRuntimeAppBundle,
} from "./runtime_prepare_app_bundle.ts";

type Profile = "single" | "vm-shell" | "pixel-shell";

type CliOptions = {
  appId: string;
  artifactGuestRoot: string;
  artifactRoot: string;
  audioBackend: string;
  bundleRewriteFrom: string;
  bundleRewriteTo: string;
  cacheDir: string;
  configJson: string;
  expectCacheHit: boolean;
  extraAssetDir: string;
  includePodcast: boolean;
  inputPath: string;
  manifestOut: string;
  profile: Profile;
  runtimeHostBinaryPath: string;
  runtimeHostPackageAttr: string;
  stateDir: string;
  writeEnv: string;
};

type AppSpec = {
  cacheDir: string;
  config: unknown;
  extraAssetDir: string | null;
  id: string;
  inputPath: string;
};

type BuiltApp = PreparedRuntimeAppBundle & {
  artifactBundlePath: string | null;
  artifactDir: string | null;
  effectiveBundleDir: string;
  effectiveBundlePath: string;
  extraAssetDir: string | null;
  guestBundlePath: string;
  id: string;
  runtimeAppConfig: unknown;
};

type ArtifactManifest = {
  apps: Record<string, BuiltApp>;
  artifactGuestRoot: string | null;
  artifactRoot: string | null;
  audioBackend: string | null;
  generatedAt: string;
  profile: Profile;
  runtimeHostBinaryPath: string | null;
  runtimeHostPackageAttr: string | null;
  schemaVersion: 1;
  stateDir: string;
};

const DEFAULT_TIMELINE_CONFIG = { limit: 12, syncOnStart: true };

async function main() {
  const options = parseArgs(Deno.args);
  const cwd = Deno.cwd();
  const artifactRoot = options.artifactRoot
    ? path.resolve(cwd, options.artifactRoot)
    : "";
  const artifactGuestRoot = options.artifactGuestRoot;

  const specs = await buildSpecs(options, cwd);
  const apps: Record<string, BuiltApp> = {};
  for (const spec of specs) {
    apps[spec.id] = await buildApp(spec, {
      artifactGuestRoot,
      artifactRoot,
      cwd,
      expectCacheHit: options.expectCacheHit,
    });
  }

  const manifest: ArtifactManifest = {
    apps,
    artifactGuestRoot: artifactGuestRoot || null,
    artifactRoot: artifactRoot || null,
    audioBackend: options.audioBackend || null,
    generatedAt: new Date().toISOString(),
    profile: options.profile,
    runtimeHostBinaryPath: options.runtimeHostBinaryPath || null,
    runtimeHostPackageAttr: options.runtimeHostPackageAttr || null,
    schemaVersion: 1,
    stateDir: await resolveStateDir(options.stateDir),
  };

  const manifestJson = `${JSON.stringify(manifest, null, 2)}\n`;
  const manifestOut = options.manifestOut ||
    (artifactRoot ? path.join(artifactRoot, "artifact-manifest.json") : "");
  if (manifestOut) {
    await Deno.mkdir(path.dirname(path.resolve(cwd, manifestOut)), {
      recursive: true,
    });
    await Deno.writeTextFile(path.resolve(cwd, manifestOut), manifestJson);
  }

  if (options.writeEnv) {
    await Deno.mkdir(path.dirname(path.resolve(cwd, options.writeEnv)), {
      recursive: true,
    });
    await Deno.writeTextFile(
      path.resolve(cwd, options.writeEnv),
      buildEnvScript(manifest, {
        from: options.bundleRewriteFrom,
        to: options.bundleRewriteTo,
      }),
    );
  }

  console.log(manifestJson.trimEnd());
}

async function buildSpecs(
  options: CliOptions,
  cwd: string,
): Promise<AppSpec[]> {
  if (options.profile === "single") {
    return [
      {
        cacheDir: options.cacheDir,
        config: parseConfigJson(options.configJson),
        extraAssetDir: options.extraAssetDir || null,
        id: options.appId,
        inputPath: options.inputPath,
      },
    ];
  }

  const specs: AppSpec[] = [
    {
      cacheDir: profileEnv(options.profile, "COUNTER_CACHE_DIR") ??
        defaultCacheDir(options.profile, "counter"),
      config: null,
      extraAssetDir: null,
      id: "counter",
      inputPath: profileEnv(options.profile, "COUNTER_INPUT_PATH") ??
        "runtime/app-counter/app.tsx",
    },
    {
      cacheDir: profileEnv(options.profile, "CAMERA_CACHE_DIR") ??
        defaultCacheDir(options.profile, "camera"),
      config: null,
      extraAssetDir: null,
      id: "camera",
      inputPath: profileEnv(options.profile, "CAMERA_INPUT_PATH") ??
        "runtime/app-camera/app.tsx",
    },
    {
      cacheDir: profileEnv(options.profile, "TIMELINE_CACHE_DIR") ??
        defaultCacheDir(options.profile, "timeline"),
      config: parseConfigJson(
        Deno.env.get("SHADOW_RUNTIME_APP_TIMELINE_CONFIG_JSON") ??
          JSON.stringify(DEFAULT_TIMELINE_CONFIG),
      ),
      extraAssetDir: null,
      id: "timeline",
      inputPath: profileEnv(options.profile, "TIMELINE_INPUT_PATH") ??
        "runtime/app-nostr-timeline/app.tsx",
    },
    {
      cacheDir: profileEnv(options.profile, "CASHU_CACHE_DIR") ??
        defaultCacheDir(options.profile, "cashu"),
      config: null,
      extraAssetDir: null,
      id: "cashu",
      inputPath: profileEnv(options.profile, "CASHU_INPUT_PATH") ??
        "runtime/app-cashu-wallet/app.tsx",
    },
  ];

  if (options.includePodcast) {
    const podcast = await resolvePodcastAssets(cwd);
    specs.push({
      cacheDir: profileEnv(options.profile, "PODCAST_CACHE_DIR") ??
        defaultCacheDir(options.profile, "podcast"),
      config: podcast.config,
      extraAssetDir: podcast.assetDir,
      id: "podcast",
      inputPath: profileEnv(options.profile, "PODCAST_INPUT_PATH") ??
        "runtime/app-podcast-player/app.tsx",
    });
  }

  return specs;
}

async function buildApp(
  spec: AppSpec,
  options: {
    artifactGuestRoot: string;
    artifactRoot: string;
    cwd: string;
    expectCacheHit: boolean;
  },
): Promise<BuiltApp> {
  const prepared = await prepareRuntimeAppBundle({
    cacheDir: spec.cacheDir,
    cwd: options.cwd,
    expectCacheHit: options.expectCacheHit,
    inputPath: spec.inputPath,
    runtimeAppConfig: spec.config,
  });
  const bundleDir = path.resolve(options.cwd, prepared.bundleDir);
  const bundlePath = path.resolve(options.cwd, prepared.bundlePath);
  const assetDir = prepared.assetDir
    ? path.resolve(options.cwd, prepared.assetDir)
    : null;
  const extraAssetDir = spec.extraAssetDir
    ? path.resolve(options.cwd, spec.extraAssetDir)
    : null;

  let artifactDir: string | null = null;
  let artifactBundlePath: string | null = null;
  if (options.artifactRoot) {
    artifactDir = path.join(options.artifactRoot, "apps", spec.id);
    await removeDirIfExists(artifactDir);
    await Deno.mkdir(artifactDir, { recursive: true });
    await copyDirRecursive(bundleDir, artifactDir);
    if (extraAssetDir) {
      await overlayExternalAssets(extraAssetDir, artifactDir);
    }
    artifactBundlePath = path.join(artifactDir, "bundle.js");
  } else if (extraAssetDir) {
    await overlayExternalAssets(extraAssetDir, bundleDir);
  }

  const effectiveBundlePath = artifactBundlePath ?? bundlePath;
  const effectiveBundleDir = artifactDir ?? bundleDir;

  return {
    ...prepared,
    artifactBundlePath,
    artifactDir,
    assetDir,
    bundleDir,
    bundlePath,
    effectiveBundleDir,
    effectiveBundlePath,
    extraAssetDir,
    guestBundlePath: guestPath(
      effectiveBundlePath,
      options.artifactRoot,
      options.artifactGuestRoot,
    ),
    id: spec.id,
    runtimeAppConfig: spec.config,
  };
}

function profileEnv(profile: Profile, suffix: string): string | null {
  if (profile === "pixel-shell") {
    return Deno.env.get(`PIXEL_SHELL_${suffix}`) ?? null;
  }
  if (profile === "vm-shell") {
    return Deno.env.get(`SHADOW_VM_SHELL_${suffix}`) ?? null;
  }
  return null;
}

function defaultCacheDir(profile: Profile, appId: string): string {
  if (profile === "pixel-shell") {
    return {
      camera: "build/runtime/pixel-shell-camera",
      cashu: "build/runtime/pixel-shell-cashu",
      counter: "build/runtime/pixel-shell-counter",
      podcast: "build/runtime/pixel-shell-podcast",
      timeline: "build/runtime/pixel-shell-timeline",
    }[appId] ?? `build/runtime/pixel-shell-${appId}`;
  }
  return {
    camera: "build/runtime/app-camera-host",
    cashu: "build/runtime/app-cashu-wallet-host",
    counter: "build/runtime/app-counter-host",
    podcast: "build/runtime/app-podcast-player-host",
    timeline: "build/runtime/app-nostr-timeline-host",
  }[appId] ?? `build/runtime/app-${appId}-host`;
}

async function resolvePodcastAssets(
  cwd: string,
): Promise<{ assetDir: string; config: unknown }> {
  const command = new Deno.Command(
    path.join(cwd, "scripts", "prepare_podcast_player_demo_assets.sh"),
    {
      stderr: "inherit",
      stdout: "piped",
    },
  );
  const result = await command.output();
  if (!result.success) {
    throw new Error(
      `prepare_podcast_player_demo_assets.sh exited with ${result.code}`,
    );
  }
  const data = JSON.parse(new TextDecoder().decode(result.stdout));
  const assetDir = data.assetDir;
  if (typeof assetDir !== "string" || assetDir.length === 0) {
    throw new Error("podcast asset resolver did not return assetDir");
  }
  delete data.assetDir;
  return { assetDir, config: data };
}

async function resolveStateDir(override: string): Promise<string> {
  if (override) {
    return override;
  }
  try {
    const stat = await Deno.stat("/var/lib/shadow-ui");
    if (stat.isDirectory) {
      return "/var/lib/shadow-ui";
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) {
      throw error;
    }
  }

  const xdg = Deno.env.get("XDG_DATA_HOME") ??
    path.join(Deno.env.get("HOME") ?? ".", ".local", "share");
  return path.join(xdg, "shadow-ui");
}

function buildEnvScript(
  manifest: ArtifactManifest,
  bundleRewrite: { from: string; to: string },
): string {
  const apps = manifest.apps;
  const defaultApp = apps.counter ?? Object.values(apps)[0];
  if (!defaultApp) {
    throw new Error("cannot write env for manifest with no apps");
  }

  const exports: Record<string, string> = {
    SHADOW_RUNTIME_APP_BUNDLE_PATH: rewriteBundlePath(
      defaultApp.guestBundlePath,
      bundleRewrite,
    ),
    SHADOW_RUNTIME_CASHU_DATA_DIR: path.join(
      manifest.stateDir,
      "runtime-cashu",
    ),
    SHADOW_RUNTIME_NOSTR_DB_PATH: path.join(
      manifest.stateDir,
      "runtime-nostr.sqlite3",
    ),
  };

  if (manifest.runtimeHostBinaryPath) {
    exports.SHADOW_RUNTIME_HOST_BINARY_PATH = manifest.runtimeHostBinaryPath;
  }
  if (apps.counter) {
    exports.SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH = rewriteBundlePath(
      apps.counter.guestBundlePath,
      bundleRewrite,
    );
  }
  if (apps.camera) {
    exports.SHADOW_RUNTIME_APP_CAMERA_BUNDLE_PATH = rewriteBundlePath(
      apps.camera.guestBundlePath,
      bundleRewrite,
    );
  }
  if (apps.timeline) {
    exports.SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH = rewriteBundlePath(
      apps.timeline.guestBundlePath,
      bundleRewrite,
    );
  }
  if (apps.cashu) {
    exports.SHADOW_RUNTIME_APP_CASHU_BUNDLE_PATH = rewriteBundlePath(
      apps.cashu.guestBundlePath,
      bundleRewrite,
    );
  }
  if (apps.podcast) {
    exports.SHADOW_RUNTIME_APP_PODCAST_BUNDLE_PATH = rewriteBundlePath(
      apps.podcast.guestBundlePath,
      bundleRewrite,
    );
  }
  if (manifest.audioBackend) {
    exports.SHADOW_RUNTIME_AUDIO_BACKEND = manifest.audioBackend;
  }

  return Object.entries(exports)
    .map(([key, value]) => `export ${key}=${shellQuote(value)}`)
    .join("\n") + "\n";
}

function rewriteBundlePath(
  value: string,
  bundleRewrite: { from: string; to: string },
): string {
  if (!bundleRewrite.from || !value.startsWith(bundleRewrite.from)) {
    return value;
  }
  return `${bundleRewrite.to}${value.slice(bundleRewrite.from.length)}`;
}

function guestPath(
  hostPath: string,
  artifactRoot: string,
  artifactGuestRoot: string,
): string {
  if (!artifactRoot || !artifactGuestRoot) {
    return hostPath;
  }
  const relative = path.relative(artifactRoot, hostPath);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    return hostPath;
  }
  return path.posix.join(
    artifactGuestRoot,
    ...relative.split(path.sep),
  );
}

function parseConfigJson(value: string): unknown {
  if (!value.trim()) {
    return null;
  }
  try {
    return JSON.parse(value);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`invalid config JSON: ${message}`);
  }
}

async function copyDirRecursive(sourceDir: string, targetDir: string) {
  await Deno.mkdir(targetDir, { recursive: true });
  for await (const entry of Deno.readDir(sourceDir)) {
    const sourcePath = path.join(sourceDir, entry.name);
    const targetPath = path.join(targetDir, entry.name);
    if (entry.isDirectory) {
      await copyDirRecursive(sourcePath, targetPath);
      continue;
    }
    if (entry.isFile) {
      await Deno.copyFile(sourcePath, targetPath);
      continue;
    }
    if (entry.isSymlink) {
      const resolvedPath = await Deno.realPath(sourcePath);
      const stat = await Deno.stat(resolvedPath);
      if (stat.isDirectory) {
        await copyDirRecursive(resolvedPath, targetPath);
      } else {
        await Deno.copyFile(resolvedPath, targetPath);
      }
    }
  }
}

async function overlayExternalAssets(sourceDir: string, targetDir: string) {
  await removeDirIfExists(path.join(targetDir, "assets"));
  await copyDirRecursive(sourceDir, targetDir);
}

async function removeDirIfExists(dirPath: string) {
  try {
    await Deno.remove(dirPath, { recursive: true });
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return;
    }
    throw error;
  }
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    appId: "app",
    artifactGuestRoot: "",
    artifactRoot: "",
    audioBackend: "",
    bundleRewriteFrom: "",
    bundleRewriteTo: "",
    cacheDir: Deno.env.get("SHADOW_RUNTIME_APP_CACHE_DIR") ??
      "build/runtime/app-counter-host",
    configJson: Deno.env.get("SHADOW_RUNTIME_APP_CONFIG_JSON") ?? "",
    expectCacheHit: false,
    extraAssetDir: Deno.env.get("SHADOW_RUNTIME_APP_EXTRA_ASSET_DIR") ?? "",
    includePodcast: false,
    inputPath: Deno.env.get("SHADOW_RUNTIME_APP_INPUT_PATH") ??
      "runtime/app-counter/app.tsx",
    manifestOut: "",
    profile: "single",
    runtimeHostBinaryPath: "",
    runtimeHostPackageAttr: "",
    stateDir: "",
    writeEnv: "",
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    switch (arg) {
      case "--profile":
        options.profile = parseProfile(requireValue(arg, args[index + 1]));
        index += 1;
        break;
      case "--app-id":
        options.appId = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--input":
        options.inputPath = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--cache-dir":
        options.cacheDir = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--config-json":
        options.configJson = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--extra-asset-dir":
        options.extraAssetDir = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--artifact-root":
        options.artifactRoot = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--artifact-guest-root":
        options.artifactGuestRoot = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--manifest-out":
        options.manifestOut = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--write-env":
        options.writeEnv = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--runtime-host-binary-path":
        options.runtimeHostBinaryPath = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--runtime-host-package":
        options.runtimeHostPackageAttr = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--audio-backend":
        options.audioBackend = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--bundle-rewrite-from":
        options.bundleRewriteFrom = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--bundle-rewrite-to":
        options.bundleRewriteTo = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--state-dir":
        options.stateDir = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--include-podcast":
        options.includePodcast = true;
        break;
      case "--expect-cache-hit":
        options.expectCacheHit = true;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (options.profile !== "single" && options.configJson) {
    throw new Error("--config-json is only valid with --profile single");
  }
  if (options.artifactGuestRoot && !options.artifactRoot) {
    throw new Error("--artifact-guest-root requires --artifact-root");
  }
  if (
    (options.bundleRewriteFrom && !options.bundleRewriteTo) ||
    (!options.bundleRewriteFrom && options.bundleRewriteTo)
  ) {
    throw new Error(
      "--bundle-rewrite-from and --bundle-rewrite-to must be paired",
    );
  }

  return options;
}

function parseProfile(value: string): Profile {
  if (value === "single" || value === "vm-shell" || value === "pixel-shell") {
    return value;
  }
  throw new Error(`unsupported profile: ${value}`);
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
