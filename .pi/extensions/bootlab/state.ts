import * as fs from "node:fs";
import * as path from "node:path";
import { execFileSync } from "node:child_process";

export type BootlabWorkerRole = "worker" | "reviewer";
export type BootlabWorkerRunner = "pi" | "demo";
export type BootlabWorkerResult = "pass" | "fail" | "ambiguous" | "blocked";
export type BootlabRestingState = "rooted-android" | "fastboot" | "manual-recovery-needed";
export type BootlabWorkerStatus =
	| "queued"
	| "running"
	| "reported"
	| "review_requested"
	| "completed"
	| "failed"
	| "stopped";

export interface BootlabPaths {
	rootDir: string;
	commonGitDir: string;
	labDir: string;
	ledgerPath: string;
	sessionsDir: string;
	transcriptsDir: string;
}

export interface BootlabWorkerSpec {
	workerId: string;
	role: BootlabWorkerRole;
	task: string;
	runner?: BootlabWorkerRunner;
	thinking?: "minimal" | "low" | "medium" | "high" | "xhigh";
	serial?: string;
	worktree?: string;
	restingState?: BootlabRestingState;
	recoveryCommand?: string;
	experiment?: string;
	reviewOf?: string;
	agent?: string;
	model?: string;
	cwd?: string;
}

export interface BootlabWorkerState extends BootlabWorkerSpec {
	status: BootlabWorkerStatus;
	result?: BootlabWorkerResult;
	pid?: number;
	exitCode?: number;
	sessionPath?: string;
	startedAt?: string;
	lastPhase?: string;
	lastSummary?: string;
	lastUpdateAt: string;
	artifacts: string[];
}

export interface BootlabState {
	paths: BootlabPaths;
	workers: Record<string, BootlabWorkerState>;
	eventCount: number;
	lastEventAt?: string;
}

export interface TranscriptEntry {
	at: string;
	kind: "text" | "tool" | "note";
	text: string;
}

export interface BootlabEvent {
	type:
		| "worker_spawned"
		| "worker_process_started"
		| "worker_report"
		| "review_requested"
		| "worker_exit"
		| "worker_stopped"
		| "worker_note";
	at: string;
	workerId: string;
	role?: BootlabWorkerRole;
	runner?: BootlabWorkerRunner;
	task?: string;
	serial?: string;
	worktree?: string;
	restingState?: BootlabRestingState;
	recoveryCommand?: string;
	experiment?: string;
	reviewOf?: string;
	agent?: string;
	model?: string;
	cwd?: string;
	pid?: number;
	sessionPath?: string;
	phase?: string;
	status?: BootlabWorkerStatus;
	result?: BootlabWorkerResult;
	summary?: string;
	artifacts?: string[];
	exitCode?: number;
	note?: string;
}

function gitRevParse(cwd: string, args: string[]): string {
	return execFileSync("git", ["rev-parse", ...args], {
		cwd,
		encoding: "utf-8",
	}).trim();
}

export function resolveBootlabPaths(cwd: string): BootlabPaths {
	const rootDir = gitRevParse(cwd, ["--show-toplevel"]);
	const commonGitDirRaw = gitRevParse(cwd, ["--git-common-dir"]);
	const commonGitDir = path.resolve(rootDir, commonGitDirRaw);
	return buildBootlabPaths(rootDir, commonGitDir);
}

export function buildBootlabPaths(rootDir: string, commonGitDir?: string): BootlabPaths {
	const resolvedRoot = path.resolve(rootDir);
	const resolvedCommonGitDir = path.resolve(commonGitDir ?? path.join(resolvedRoot, ".git"));
	const labDir = path.join(resolvedCommonGitDir, "bootlab");
	return {
		rootDir: resolvedRoot,
		commonGitDir: resolvedCommonGitDir,
		labDir,
		ledgerPath: path.join(labDir, "ledger.jsonl"),
		sessionsDir: path.join(labDir, "sessions"),
		transcriptsDir: path.join(labDir, "transcripts"),
	};
}

export function ensureBootlabPaths(paths: BootlabPaths): void {
	fs.mkdirSync(paths.labDir, { recursive: true });
	fs.mkdirSync(paths.sessionsDir, { recursive: true });
	fs.mkdirSync(paths.transcriptsDir, { recursive: true });
}

export function nowIso(): string {
	return new Date().toISOString();
}

function appendJsonLine(filePath: string, value: unknown): void {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	fs.appendFileSync(filePath, `${JSON.stringify(value)}\n`, "utf-8");
}

export function appendBootlabEvent(paths: BootlabPaths, event: BootlabEvent): void {
	ensureBootlabPaths(paths);
	appendJsonLine(paths.ledgerPath, event);
}

export function appendTranscriptEntry(paths: BootlabPaths, workerId: string, entry: TranscriptEntry): void {
	ensureBootlabPaths(paths);
	appendJsonLine(path.join(paths.transcriptsDir, `${workerId}.jsonl`), entry);
}

export function readTranscriptEntries(paths: BootlabPaths, workerId: string, limit = 80): TranscriptEntry[] {
	const transcriptPath = path.join(paths.transcriptsDir, `${workerId}.jsonl`);
	if (!fs.existsSync(transcriptPath)) {
		return [];
	}
	const lines = fs
		.readFileSync(transcriptPath, "utf-8")
		.split("\n")
		.map((line) => line.trim())
		.filter(Boolean);
	const parsed = lines
		.map((line) => {
			try {
				return JSON.parse(line) as TranscriptEntry;
			} catch {
				return undefined;
			}
		})
		.filter((entry): entry is TranscriptEntry => Boolean(entry));
	return parsed.slice(Math.max(0, parsed.length - limit));
}

export function readBootlabEvents(paths: BootlabPaths): BootlabEvent[] {
	if (!fs.existsSync(paths.ledgerPath)) {
		return [];
	}
	return fs
		.readFileSync(paths.ledgerPath, "utf-8")
		.split("\n")
		.map((line) => line.trim())
		.filter(Boolean)
		.map((line) => {
			try {
				return JSON.parse(line) as BootlabEvent;
			} catch {
				return undefined;
			}
		})
		.filter((entry): entry is BootlabEvent => Boolean(entry));
}

function ensureWorker(state: BootlabState, workerId: string, at: string): BootlabWorkerState {
	let worker = state.workers[workerId];
	if (!worker) {
		worker = {
			workerId,
			role: "worker",
			task: "",
			runner: "pi",
			status: "queued",
			lastUpdateAt: at,
			artifacts: [],
		};
		state.workers[workerId] = worker;
	}
	return worker;
}

function mergeWorkerMetadata(worker: BootlabWorkerState, event: BootlabEvent): void {
	if (event.role) worker.role = event.role;
	if (event.task !== undefined) worker.task = event.task;
	if (event.runner) worker.runner = event.runner;
	if (event.serial !== undefined) worker.serial = event.serial;
	if (event.worktree !== undefined) worker.worktree = event.worktree;
	if (event.restingState !== undefined) worker.restingState = event.restingState;
	if (event.recoveryCommand !== undefined) worker.recoveryCommand = event.recoveryCommand;
	if (event.experiment !== undefined) worker.experiment = event.experiment;
	if (event.reviewOf !== undefined) worker.reviewOf = event.reviewOf;
	if (event.agent !== undefined) worker.agent = event.agent;
	if (event.model !== undefined) worker.model = event.model;
	if (event.cwd !== undefined) worker.cwd = event.cwd;
	if (event.sessionPath !== undefined) worker.sessionPath = event.sessionPath;
}

function mergeArtifacts(worker: BootlabWorkerState, artifacts?: string[]): void {
	if (!artifacts || artifacts.length === 0) return;
	const merged = new Set(worker.artifacts);
	for (const artifact of artifacts) merged.add(artifact);
	worker.artifacts = Array.from(merged);
}

export function reduceBootlabState(paths: BootlabPaths, events: BootlabEvent[] = readBootlabEvents(paths)): BootlabState {
	const state: BootlabState = {
		paths,
		workers: {},
		eventCount: events.length,
	};

	for (const event of events) {
		state.lastEventAt = event.at;
		const worker = ensureWorker(state, event.workerId, event.at);
		worker.lastUpdateAt = event.at;
		mergeWorkerMetadata(worker, event);

		switch (event.type) {
			case "worker_spawned":
				worker.status = "queued";
				break;
			case "worker_process_started":
				if (event.pid !== undefined) worker.pid = event.pid;
				worker.startedAt = event.at;
				worker.status = "running";
				break;
			case "worker_report":
				if (event.phase !== undefined) worker.lastPhase = event.phase;
				if (event.summary !== undefined) worker.lastSummary = event.summary;
				if (event.result !== undefined) worker.result = event.result;
				mergeArtifacts(worker, event.artifacts);
				worker.status = event.status ?? "reported";
				break;
			case "review_requested":
				if (event.summary !== undefined) worker.lastSummary = event.summary;
				if (event.result !== undefined) worker.result = event.result;
				mergeArtifacts(worker, event.artifacts);
				worker.status = "review_requested";
				break;
			case "worker_exit":
				if (event.exitCode !== undefined) worker.exitCode = event.exitCode;
				if (event.exitCode === 0) {
					if (worker.status !== "reported" && worker.status !== "review_requested") {
						worker.status = "completed";
					}
				} else {
					worker.status = "failed";
				}
				break;
			case "worker_stopped":
				worker.status = "stopped";
				break;
			case "worker_note":
				if (event.note) worker.lastSummary = event.note;
				break;
		}
	}

	return state;
}

export function loadBootlabState(paths: BootlabPaths): BootlabState {
	return reduceBootlabState(paths);
}

export function resetBootlabState(paths: BootlabPaths): void {
	fs.rmSync(paths.labDir, { recursive: true, force: true });
}

export function resolveWorkerRef(state: BootlabState, ref: string): BootlabWorkerState | undefined {
	const trimmed = ref.trim();
	if (!trimmed) return undefined;
	if (state.workers[trimmed]) return state.workers[trimmed];
	return Object.values(state.workers).find((worker) => worker.serial === trimmed);
}

export function workerHasOpenProcess(worker: BootlabWorkerState): boolean {
	return worker.pid !== undefined && worker.exitCode === undefined && worker.status !== "stopped";
}

export function workerClaimsSerial(worker: BootlabWorkerState): boolean {
	return Boolean(worker.serial) && (worker.status === "queued" || worker.status === "running");
}

function short(value: string | undefined, max = 60): string {
	if (!value) return "-";
	if (value.length <= max) return value;
	return `${value.slice(0, max - 1)}…`;
}

export function formatWorkerSummary(worker: BootlabWorkerState): string {
	const parts = [
		worker.workerId,
		worker.role,
		worker.status,
		worker.result ? `result=${worker.result}` : "",
		worker.serial ? `serial=${worker.serial}` : "",
		worker.experiment ? `exp=${worker.experiment}` : "",
	];
	const head = parts.filter(Boolean).join(" | ");
	const detail = short(worker.lastSummary ?? worker.task, 90);
	return `${head}\n  ${detail}`;
}

export function formatStatusLines(state: BootlabState): string[] {
	const workers = Object.values(state.workers).sort((a, b) => a.workerId.localeCompare(b.workerId));
	if (workers.length === 0) {
		return ["No bootlab workers yet."];
	}

	const lines = [
		`Bootlab: ${workers.length} worker${workers.length === 1 ? "" : "s"} | events=${state.eventCount} | root=${state.paths.rootDir}`,
	];
	for (const worker of workers) {
		lines.push(
			`${worker.workerId}  ${worker.role}  ${worker.status}${worker.result ? `/${worker.result}` : ""}  ${worker.serial ?? "-"}  ${short(worker.experiment ?? "-", 20)}`,
		);
		lines.push(`  task: ${short(worker.task, 100)}`);
		if (worker.lastPhase || worker.lastSummary) {
			lines.push(`  last: ${short(worker.lastPhase ? `${worker.lastPhase}: ${worker.lastSummary ?? ""}` : worker.lastSummary, 100)}`);
		}
		if (worker.restingState) {
			lines.push(`  resting: ${worker.restingState}`);
		}
		if (worker.recoveryCommand) {
			lines.push(`  recover: ${short(worker.recoveryCommand, 100)}`);
		}
		if (worker.sessionPath) {
			lines.push(`  session: ${worker.sessionPath}`);
		}
		if (worker.artifacts.length > 0) {
			lines.push(`  artifacts: ${worker.artifacts.slice(-3).join(", ")}`);
		}
	}
	return lines;
}
