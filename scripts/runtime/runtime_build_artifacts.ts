import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
  type PreparedRuntimeAppBundle,
  prepareRuntimeAppBundle,
} from "./runtime_prepare_app_bundle.ts";

type Profile = "single" | "vm-shell" | "pixel-shell";
type ShellProfile = Exclude<Profile, "single">;
type AppModel = "typescript" | "rust";

type CliOptions = {
  appId: string;
  artifactGuestRoot: string;
  artifactRoot: string;
  audioBackend: string;
  cameraAllowMock: string;
  cameraEndpoint: string;
  cameraTimeoutMs: string;
  bundleRewriteFrom: string;
  bundleRewriteTo: string;
  cacheDir: string;
  configJson: string;
  expectCacheHit: boolean;
  extraAssetDir: string;
  includeAppIds: string[];
  includePodcast: boolean;
  inputPath: string;
  manifestOut: string;
  profile: Profile;
  startupAppId: string;
  systemBinaryPath: string;
  systemPackageAttr: string;
  stateDir: string;
  writeEnv: string;
  writeSessionConfig: string;
};

type AppSpec = {
  bundleEnv: string | null;
  bundleFilename: string | null;
  cacheDir: string;
  config: unknown;
  extraAssetDir: string | null;
  id: string;
  inputPath: string;
};

type BuiltApp = PreparedRuntimeAppBundle & {
  artifactBundlePath: string | null;
  artifactDir: string | null;
  bundleEnv: string | null;
  bundleFilename: string | null;
  effectiveBundleDir: string;
  effectiveBundlePath: string;
  extraAssetDir: string | null;
  guestBundlePath: string;
  id: string;
  runtimeAppConfig: unknown;
};

type TypeScriptRuntimeAppMetadata = {
  assetResolver?: "podcast-demo";
  bundleEnv: string;
  bundleFilename: string;
  cacheDirs: Partial<Record<ShellProfile, string>>;
  config?: unknown;
  configEnv?: string;
  inputPath: string;
  optionalBundle?: boolean;
};

type RuntimeAppMetadata = {
  id: string;
  model: AppModel;
  profiles: ShellProfile[];
  runtime?: TypeScriptRuntimeAppMetadata;
};

type RuntimeAppsManifest = {
  apps: RuntimeAppMetadata[];
  schemaVersion: 1;
};

type ArtifactManifest = {
  apps: Record<string, BuiltApp>;
  artifactGuestRoot: string | null;
  artifactRoot: string | null;
  audioBackend: string | null;
  generatedAt: string;
  profile: Profile;
  systemBinaryPath: string | null;
  systemPackageAttr: string | null;
  schemaVersion: 1;
  stateDir: string;
};

type RuntimeSessionAppConfig = {
  bundleEnv: string | null;
  bundlePath: string;
  config: unknown;
};

type SessionCameraConfig = {
  allowMock: boolean | null;
  endpoint: string | null;
  timeoutMs: number | null;
};

type SessionConfig = {
  artifacts: {
    guestRoot: string | null;
    root: string | null;
  };
  generatedAt: string;
  profile: Profile;
  runtime: {
    apps: Record<string, RuntimeSessionAppConfig>;
    defaultAppId: string | null;
    defaultBundlePath: string | null;
  };
  schemaVersion: 1;
  services: {
    audioBackend: string | null;
    camera: SessionCameraConfig | null;
    cashuDataDir: string;
    nostrDbPath: string;
    nostrServiceSocket: string;
  };
  startup: {
    appId: string | null;
  };
  stateDir: string;
  system: {
    binaryPath: string | null;
    packageAttr: string | null;
  };
};

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
    systemBinaryPath: options.systemBinaryPath || null,
    systemPackageAttr: options.systemPackageAttr || null,
    schemaVersion: 1,
    stateDir: await resolveStateDir(options.stateDir),
  };
  const sessionConfig = buildSessionConfig(manifest, {
    camera: buildCameraServiceConfig(options),
    startupAppId: options.startupAppId || null,
  });

  const manifestJson = `${JSON.stringify(manifest, null, 2)}\n`;
  const manifestOut = options.manifestOut ||
    (artifactRoot ? path.join(artifactRoot, "artifact-manifest.json") : "");
  if (manifestOut) {
    await Deno.mkdir(path.dirname(path.resolve(cwd, manifestOut)), {
      recursive: true,
    });
    await Deno.writeTextFile(path.resolve(cwd, manifestOut), manifestJson);
  }

  if (options.writeSessionConfig) {
    await Deno.mkdir(
      path.dirname(path.resolve(cwd, options.writeSessionConfig)),
      {
        recursive: true,
      },
    );
    await Deno.writeTextFile(
      path.resolve(cwd, options.writeSessionConfig),
      `${JSON.stringify(sessionConfig, null, 2)}\n`,
    );
  }

  if (options.writeEnv) {
    await Deno.mkdir(path.dirname(path.resolve(cwd, options.writeEnv)), {
      recursive: true,
    });
    await Deno.writeTextFile(
      path.resolve(cwd, options.writeEnv),
      buildEnvScript(resolveRuntimeSessionConfigEnvPath(options, cwd)),
    );
  }

  console.log(manifestJson.trimEnd());
}

async function buildSpecs(
  options: CliOptions,
  cwd: string,
): Promise<AppSpec[]> {
  const profile = options.profile;
  if (profile === "single") {
    if (options.includeAppIds.length > 0) {
      throw new Error(
        "--include-app is only valid with vm-shell and pixel-shell profiles",
      );
    }
    const defaults = await defaultSingleAppSpec(cwd);
    return [
      {
        bundleEnv: null,
        bundleFilename: null,
        cacheDir: options.cacheDir || defaults.cacheDir,
        config: parseConfigJson(options.configJson),
        extraAssetDir: options.extraAssetDir || null,
        id: options.appId,
        inputPath: options.inputPath || defaults.inputPath,
      },
    ];
  }

  const manifest = await loadRuntimeAppsManifest(cwd);
  const requestedAppIds = options.includeAppIds;
  const selectedAppIds = requestedAppIds.length > 0 ? requestedAppIds : null;
  const manifestAppsById = new Map(
    manifest.apps.map((app) => [app.id, app] as const),
  );
  const specsById = new Map<string, AppSpec>();
  for (const app of manifest.apps) {
    if (!app.profiles.includes(profile)) {
      continue;
    }
    if (app.model !== "typescript") {
      continue;
    }
    const runtime = app.runtime;
    if (!runtime) {
      throw new Error(
        `runtime/apps.json: app ${app.id} uses model typescript but is missing runtime`,
      );
    }
    if (selectedAppIds && !selectedAppIds.includes(app.id)) {
      continue;
    }
    if (
      runtime.optionalBundle &&
      !options.includePodcast &&
      !(selectedAppIds?.includes(app.id))
    ) {
      continue;
    }

    let config = runtimeAppConfig(runtime);
    let extraAssetDir: string | null = null;
    if (runtime.assetResolver === "podcast-demo") {
      const podcast = await resolvePodcastAssets(cwd);
      config = podcast.config;
      extraAssetDir = podcast.assetDir;
    }
    const prefix = appEnvPrefix(app.id);
    const cacheDir = runtime.cacheDirs[profile];
    if (!cacheDir) {
      throw new Error(
        `runtime/apps.json: app ${app.id} is missing runtime.cacheDirs.${profile}`,
      );
    }
    specsById.set(app.id, {
      bundleEnv: runtime.bundleEnv,
      bundleFilename: runtime.bundleFilename,
      cacheDir: profileEnv(profile, `${prefix}_CACHE_DIR`) ??
        cacheDir,
      config,
      extraAssetDir,
      id: app.id,
      inputPath: profileEnv(profile, `${prefix}_INPUT_PATH`) ??
        runtime.inputPath,
    });
  }

  if (selectedAppIds) {
    return selectedAppIds.map((appId) => {
      const manifestApp = manifestAppsById.get(appId);
      if (!manifestApp) {
        throw new Error(`unsupported app ${appId} for profile ${profile}`);
      }
      if (manifestApp.model !== "typescript") {
        throw new Error(
          `app ${appId} uses model ${manifestApp.model}; runtime_build_artifacts only supports typescript apps`,
        );
      }
      const spec = specsById.get(appId);
      if (!spec) {
        throw new Error(`unsupported app ${appId} for profile ${profile}`);
      }
      return spec;
    });
  }

  return Array.from(specsById.values());
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
    bundleEnv: spec.bundleEnv,
    bundleFilename: spec.bundleFilename,
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

async function loadRuntimeAppsManifest(
  cwd: string,
): Promise<RuntimeAppsManifest> {
  const manifestPath = Deno.env.get("SHADOW_APP_METADATA_MANIFEST") ||
    path.join(cwd, "runtime", "apps.json");
  const data = JSON.parse(await Deno.readTextFile(manifestPath));
  validateRuntimeAppsManifest(data, manifestPath);
  return data as RuntimeAppsManifest;
}

function validateRuntimeAppsManifest(
  data: unknown,
  manifestPath: string,
): void {
  if (!data || typeof data !== "object") {
    throw new Error(`${manifestPath}: manifest must be an object`);
  }
  const manifest = data as {
    apps?: unknown;
    schemaVersion?: unknown;
    shell?: { id?: unknown; waylandAppId?: unknown };
  };
  if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.apps)) {
    throw new Error(
      `${manifestPath}: manifest must use schemaVersion 1 with an apps array`,
    );
  }
  const shellId = typeof manifest.shell?.id === "string" && manifest.shell.id
    ? manifest.shell.id
    : "shell";
  const seenAppIds = new Set<string>([shellId]);
  const seenBundleEnvs = new Set<string>();
  const seenBundleFilenames = new Set<string>();

  for (const app of manifest.apps) {
    if (!app || typeof app !== "object") {
      throw new Error(`${manifestPath}: apps entries must be objects`);
    }
    const metadata = app as {
      id?: unknown;
      model?: unknown;
      profiles?: unknown;
      runtime?: {
        bundleEnv?: unknown;
        bundleFilename?: unknown;
      };
    };
    if (typeof metadata.id !== "string" || !metadata.id) {
      throw new Error(`${manifestPath}: app id must be a non-empty string`);
    }
    if (seenAppIds.has(metadata.id)) {
      throw new Error(`${manifestPath}: duplicate app id ${metadata.id}`);
    }
    seenAppIds.add(metadata.id);
    if (!Array.isArray(metadata.profiles) || metadata.profiles.length === 0) {
      throw new Error(
        `${manifestPath}: app ${metadata.id} must declare profiles`,
      );
    }
    if (metadata.model !== "typescript" && metadata.model !== "rust") {
      throw new Error(
        `${manifestPath}: app ${metadata.id} must declare model "typescript" or "rust"`,
      );
    }
    if (metadata.model === "rust") {
      if (Object.prototype.hasOwnProperty.call(metadata, "runtime")) {
        throw new Error(
          `${manifestPath}: app ${metadata.id} uses model rust and must not declare runtime`,
        );
      }
      continue;
    }
    if (!metadata.runtime || typeof metadata.runtime !== "object") {
      throw new Error(
        `${manifestPath}: app ${metadata.id} must declare runtime`,
      );
    }
    const bundleEnv = metadata.runtime.bundleEnv;
    if (typeof bundleEnv !== "string" || !bundleEnv) {
      throw new Error(
        `${manifestPath}: app ${metadata.id} must declare runtime.bundleEnv`,
      );
    }
    if (seenBundleEnvs.has(bundleEnv)) {
      throw new Error(
        `${manifestPath}: duplicate runtime.bundleEnv ${bundleEnv}`,
      );
    }
    seenBundleEnvs.add(bundleEnv);
    const bundleFilename = metadata.runtime.bundleFilename;
    if (typeof bundleFilename !== "string" || !bundleFilename) {
      throw new Error(
        `${manifestPath}: app ${metadata.id} must declare runtime.bundleFilename`,
      );
    }
    if (seenBundleFilenames.has(bundleFilename)) {
      throw new Error(
        `${manifestPath}: duplicate runtime.bundleFilename ${bundleFilename}`,
      );
    }
    seenBundleFilenames.add(bundleFilename);
  }
}

async function defaultSingleAppSpec(
  cwd: string,
): Promise<{ cacheDir: string; inputPath: string }> {
  const manifest = await loadRuntimeAppsManifest(cwd);
  const app = manifest.apps.find((candidate) =>
    candidate.model === "typescript" &&
    candidate.runtime &&
    candidate.profiles.includes("vm-shell") &&
    typeof candidate.runtime.cacheDirs["vm-shell"] === "string"
  );
  if (!app) {
    throw new Error(
      "runtime/apps.json must contain at least one typescript vm-shell app",
    );
  }
  return {
    cacheDir: app.runtime!.cacheDirs["vm-shell"]!,
    inputPath: app.runtime!.inputPath,
  };
}

function appEnvPrefix(appId: string): string {
  return appId.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
}

function runtimeAppConfig(runtime: TypeScriptRuntimeAppMetadata): unknown {
  const configEnv = runtime.configEnv
    ? Deno.env.get(runtime.configEnv)
    : undefined;
  if (configEnv !== undefined) {
    return parseConfigJson(configEnv);
  }
  return runtime.config ?? null;
}

async function resolvePodcastAssets(
  cwd: string,
): Promise<{ assetDir: string; config: unknown }> {
  const command = new Deno.Command(
    path.join(
      cwd,
      "scripts",
      "runtime",
      "prepare_podcast_player_demo_assets.sh",
    ),
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

function buildSessionConfig(
  manifest: ArtifactManifest,
  options: { camera: SessionCameraConfig | null; startupAppId: string | null },
): SessionConfig {
  const defaultApp = defaultRuntimeAppEntry(manifest.apps);
  return {
    artifacts: {
      guestRoot: manifest.artifactGuestRoot,
      root: manifest.artifactRoot,
    },
    generatedAt: manifest.generatedAt,
    profile: manifest.profile,
    runtime: {
      apps: Object.fromEntries(
        Object.entries(manifest.apps).map(([appId, app]) => [
          appId,
          {
            bundleEnv: app.bundleEnv,
            bundlePath: app.guestBundlePath,
            config: app.runtimeAppConfig ?? null,
          },
        ]),
      ),
      defaultAppId: defaultApp?.[0] ?? null,
      defaultBundlePath: defaultApp?.[1].guestBundlePath ?? null,
    },
    schemaVersion: 1,
    services: {
      audioBackend: manifest.audioBackend,
      camera: options.camera,
      cashuDataDir: path.join(manifest.stateDir, "runtime-cashu"),
      nostrDbPath: path.join(manifest.stateDir, "runtime-nostr.sqlite3"),
      nostrServiceSocket: path.join(manifest.stateDir, "runtime-nostr.sock"),
    },
    startup: {
      appId: options.startupAppId,
    },
    stateDir: manifest.stateDir,
    system: {
      binaryPath: manifest.systemBinaryPath,
      packageAttr: manifest.systemPackageAttr,
    },
  };
}

function defaultRuntimeAppEntry(
  apps: Record<string, BuiltApp>,
): [string, BuiltApp] | null {
  const entries = Object.entries(apps);
  if (entries.length === 0) {
    return null;
  }
  return entries.find(([appId]) => appId === "counter") ?? entries[0];
}

function buildEnvScript(runtimeSessionConfigPath: string): string {
  // Typed runtime services live in the session config; the env shim only needs
  // to point the guest at that file.
  return Object.entries({
    SHADOW_RUNTIME_SESSION_CONFIG: runtimeSessionConfigPath,
  })
    .map(([key, value]) => `export ${key}=${shellQuote(value)}`)
    .join("\n") + "\n";
}

function buildCameraServiceConfig(
  options: CliOptions,
): SessionCameraConfig | null {
  const endpoint = normalizedOptionValue(options.cameraEndpoint);
  const allowMock = parseOptionalBoolean(
    "--camera-allow-mock",
    options.cameraAllowMock,
  );
  const timeoutMs = parseOptionalPositiveInteger(
    "--camera-timeout-ms",
    options.cameraTimeoutMs,
  );
  if (!endpoint && allowMock === null && timeoutMs === null) {
    return null;
  }
  return {
    allowMock,
    endpoint,
    timeoutMs,
  };
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

function resolveRuntimeSessionConfigEnvPath(
  options: CliOptions,
  cwd: string,
): string {
  if (!options.writeSessionConfig) {
    throw new Error("--write-env requires --write-session-config");
  }
  if (options.artifactGuestRoot) {
    return path.posix.join(options.artifactGuestRoot, "session-config.json");
  }
  return path.resolve(cwd, options.writeSessionConfig);
}

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {
    appId: "app",
    artifactGuestRoot: "",
    artifactRoot: "",
    audioBackend: "",
    cameraAllowMock: Deno.env.get("SHADOW_RUNTIME_CAMERA_ALLOW_MOCK") ?? "",
    cameraEndpoint: Deno.env.get("SHADOW_RUNTIME_CAMERA_ENDPOINT") ?? "",
    cameraTimeoutMs: Deno.env.get("SHADOW_RUNTIME_CAMERA_TIMEOUT_MS") ?? "",
    bundleRewriteFrom: "",
    bundleRewriteTo: "",
    cacheDir: Deno.env.get("SHADOW_RUNTIME_APP_CACHE_DIR") ?? "",
    configJson: Deno.env.get("SHADOW_RUNTIME_APP_CONFIG_JSON") ?? "",
    expectCacheHit: false,
    extraAssetDir: Deno.env.get("SHADOW_RUNTIME_APP_EXTRA_ASSET_DIR") ?? "",
    includeAppIds: [],
    includePodcast: false,
    inputPath: Deno.env.get("SHADOW_RUNTIME_APP_INPUT_PATH") ?? "",
    manifestOut: "",
    profile: "single",
    startupAppId: "",
    systemBinaryPath: "",
    systemPackageAttr: "",
    stateDir: "",
    writeEnv: "",
    writeSessionConfig: "",
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
      case "--include-app":
        options.includeAppIds.push(requireValue(arg, args[index + 1]));
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
      case "--write-session-config":
        options.writeSessionConfig = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--system-binary-path":
        options.systemBinaryPath = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--system-package":
        options.systemPackageAttr = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--audio-backend":
        options.audioBackend = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--camera-allow-mock":
        options.cameraAllowMock = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--camera-endpoint":
        options.cameraEndpoint = requireValue(arg, args[index + 1]);
        index += 1;
        break;
      case "--camera-timeout-ms":
        options.cameraTimeoutMs = requireValue(arg, args[index + 1]);
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
      case "--startup-app-id":
        options.startupAppId = requireValue(arg, args[index + 1]);
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
  if (options.writeEnv && !options.writeSessionConfig) {
    throw new Error("--write-env requires --write-session-config");
  }
  if (options.startupAppId && !options.writeSessionConfig) {
    throw new Error("--startup-app-id requires --write-session-config");
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

function normalizedOptionValue(value: string): string | null {
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function parseOptionalBoolean(flag: string, value: string): boolean | null {
  const normalized = normalizedOptionValue(value);
  if (normalized === null) {
    return null;
  }
  switch (normalized.toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
      return true;
    case "0":
    case "false":
    case "no":
    case "off":
      return false;
    default:
      throw new Error(`${flag} must be a boolean-ish value, got ${value}`);
  }
}

function parseOptionalPositiveInteger(
  flag: string,
  value: string,
): number | null {
  const normalized = normalizedOptionValue(value);
  if (normalized === null) {
    return null;
  }
  const parsed = Number.parseInt(normalized, 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${flag} must be a positive integer, got ${value}`);
  }
  return parsed;
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
