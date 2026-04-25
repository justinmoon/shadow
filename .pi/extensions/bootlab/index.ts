import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { matchesKey, truncateToWidth } from "@mariozechner/pi-tui";
import { Type } from "@sinclair/typebox";
import { getBootlabExtensionEntryPath, launchWorker, loadProjectAgent, type WorkerLaunchHandle } from "./runner.ts";
import {
	type BootlabPaths,
	type BootlabWorkerSpec,
	type BootlabWorkerState,
	appendBootlabEvent,
	formatStatusLines,
	loadBootlabState,
	nowIso,
	readTranscriptEntries,
	resetBootlabState,
	resolveBootlabPaths,
	resolveWorkerRef,
	workerClaimsSerial,
	workerHasOpenProcess,
} from "./state.ts";

const DEFAULT_BOOTLAB_MODEL = "openai-codex/gpt-5.5";
const DEFAULT_BOOTLAB_THINKING = "xhigh";
const ResultSchema = Type.Union(
	[
		Type.Literal("pass"),
		Type.Literal("fail"),
		Type.Literal("ambiguous"),
		Type.Literal("blocked"),
	],
	{ description: "Evidence-level conclusion, separate from lifecycle status." },
);
const RestingStateSchema = Type.Union(
	[
		Type.Literal("rooted-android"),
		Type.Literal("fastboot"),
		Type.Literal("manual-recovery-needed"),
	],
	{ description: "Expected resting state for the device after the assignment." },
);

const WorkerSpecSchema = Type.Object({
	workerId: Type.String({ description: "Stable worker ID, for example worker-1 or review-1" }),
	role: Type.Union([Type.Literal("worker"), Type.Literal("reviewer")], {
		description: "worker for device execution, reviewer for validation",
	}),
	task: Type.String({ description: "Concrete task to assign" }),
	runner: Type.Optional(
		Type.Union([Type.Literal("pi"), Type.Literal("demo")], {
			description: "pi for a real subagent, demo for a no-model local mock worker",
		}),
	),
	thinking: Type.Optional(
		Type.Union(
			[
				Type.Literal("minimal"),
				Type.Literal("low"),
				Type.Literal("medium"),
				Type.Literal("high"),
				Type.Literal("xhigh"),
			],
			{ description: "Reasoning level for pi-runner workers; defaults to xhigh." },
		),
	),
	serial: Type.Optional(Type.String({ description: "Assigned phone serial" })),
	worktree: Type.Optional(Type.String({ description: "Assigned worktree path" })),
	restingState: Type.Optional(RestingStateSchema),
	recoveryCommand: Type.Optional(Type.String({ description: "Best-known recovery command for this assignment." })),
	experiment: Type.Optional(Type.String({ description: "Experiment or hypothesis label" })),
	reviewOf: Type.Optional(Type.String({ description: "Target worker ID for reviewers" })),
	agent: Type.Optional(Type.String({ description: "Project-local agent prompt name; defaults by role" })),
	model: Type.Optional(Type.String({ description: "Optional model override for pi-runner workers" })),
	cwd: Type.Optional(Type.String({ description: "Working directory override" })),
});

const SpawnToolParams = Type.Object({
	workers: Type.Array(WorkerSpecSchema, { minItems: 1, description: "Workers or reviewers to launch" }),
});

const ReportToolParams = Type.Object({
	workerId: Type.String({ description: "The reporting worker ID" }),
	phase: Type.String({ description: "Short phase label such as start, run, validate, finish" }),
	status: Type.Optional(
		Type.Union(
			[
				Type.Literal("running"),
				Type.Literal("reported"),
				Type.Literal("review_requested"),
				Type.Literal("completed"),
				Type.Literal("failed"),
			],
			{ description: "Worker status after this report" },
		),
	),
	result: Type.Optional(ResultSchema),
	summary: Type.String({ description: "Plain-language checkpoint summary" }),
	artifacts: Type.Optional(Type.Array(Type.String(), { description: "Paths or artifact refs produced so far" })),
	serial: Type.Optional(Type.String()),
	worktree: Type.Optional(Type.String()),
	restingState: Type.Optional(RestingStateSchema),
	recoveryCommand: Type.Optional(Type.String()),
	experiment: Type.Optional(Type.String()),
	reviewOf: Type.Optional(Type.String()),
});

const StatusToolParams = Type.Object({
	ref: Type.Optional(Type.String({ description: "Optional worker ID or serial to narrow the result" })),
});

const StopToolParams = Type.Object({
	ref: Type.String({ description: "Worker ID or serial, or 'all'" }),
});

class BootlabWatchComponent {
	private readonly workerRef: string;
	private readonly getPaths: () => BootlabPaths;
	private readonly close: () => void;
	private readonly ticker: ReturnType<typeof setInterval>;
	private width?: number;
	private cached?: string[];

	constructor(workerRef: string, getPaths: () => BootlabPaths, close: () => void, requestRender: () => void) {
		this.workerRef = workerRef;
		this.getPaths = getPaths;
		this.close = close;
		this.ticker = setInterval(() => {
			this.invalidate();
			requestRender();
		}, 500);
	}

	dispose(): void {
		clearInterval(this.ticker);
	}

	render(width: number): string[] {
		if (this.cached && this.width === width) {
			return this.cached;
		}

		const state = loadBootlabState(this.getPaths());
		const worker = resolveWorkerRef(state, this.workerRef);
		const lines: string[] = [];

		lines.push(truncateToWidth(`Bootlab watch: ${this.workerRef}`, width));
		lines.push(truncateToWidth("Press Esc to close", width));
		lines.push("");

		if (!worker) {
			lines.push(truncateToWidth(`No worker found for ${this.workerRef}`, width));
		} else {
			lines.push(
				truncateToWidth(
					`${worker.workerId} | ${worker.role} | ${worker.status}${worker.result ? ` | ${worker.result}` : ""}`,
					width,
				),
			);
			if (worker.serial) lines.push(truncateToWidth(`serial: ${worker.serial}`, width));
			if (worker.worktree) lines.push(truncateToWidth(`worktree: ${worker.worktree}`, width));
			if (worker.restingState) lines.push(truncateToWidth(`resting: ${worker.restingState}`, width));
			if (worker.recoveryCommand) lines.push(truncateToWidth(`recover: ${worker.recoveryCommand}`, width));
			if (worker.experiment) lines.push(truncateToWidth(`experiment: ${worker.experiment}`, width));
			if (worker.sessionPath) lines.push(truncateToWidth(`session: ${worker.sessionPath}`, width));
			lines.push("");
			for (const entry of readTranscriptEntries(this.getPaths(), worker.workerId, 24)) {
				const prefix = entry.kind === "tool" ? "$ " : entry.kind === "note" ? "! " : "  ";
				lines.push(truncateToWidth(`${prefix}${entry.text}`, width));
			}
		}

		this.width = width;
		this.cached = lines;
		return lines;
	}

	invalidate(): void {
		this.width = undefined;
		this.cached = undefined;
	}

	handleInput(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.dispose();
			this.close();
		}
	}
}

function formatSpawnSummary(handles: WorkerLaunchHandle[], warnings: string[] = []): string {
	const lines: string[] = [];
	if (warnings.length > 0) {
		lines.push("Warnings:");
		for (const warning of warnings) {
			lines.push(`- ${warning}`);
		}
		lines.push("");
	}
	return handles
		.map((handle) => `${handle.workerId}${handle.sessionPath ? ` -> ${handle.sessionPath}` : ""}`)
		.reduce((all, line) => {
			all.push(line);
			return all;
		}, lines)
		.join("\n");
}

function formatSerialConflictLabel(worker: Pick<BootlabWorkerState, "workerId" | "status">): string {
	return `${worker.workerId} (${worker.status})`;
}

function collectSerialWarnings(state: ReturnType<typeof loadBootlabState>, specs: BootlabWorkerSpec[]): string[] {
	const claims = new Map<string, string[]>();
	for (const worker of Object.values(state.workers)) {
		if (!worker.serial || !workerClaimsSerial(worker)) continue;
		const current = claims.get(worker.serial) ?? [];
		current.push(formatSerialConflictLabel(worker));
		claims.set(worker.serial, current);
	}

	const warnings: string[] = [];
	for (const spec of specs) {
		if (!spec.serial) continue;
		const existingClaims = claims.get(spec.serial) ?? [];
		if (existingClaims.length > 0) {
			warnings.push(`Serial ${spec.serial} is already assigned to ${existingClaims.join(", ")}.`);
		}
		claims.set(spec.serial, [...existingClaims, spec.workerId]);
	}
	return warnings;
}

function requestPidStop(paths: BootlabPaths, worker: BootlabWorkerState): { stopped: boolean; message: string } {
	if (!workerHasOpenProcess(worker) || worker.pid === undefined) {
		return { stopped: false, message: `${worker.workerId} has no recorded live pid.` };
	}

	try {
		process.kill(worker.pid, "SIGTERM");
		appendBootlabEvent(paths, {
			type: "worker_stopped",
			at: nowIso(),
			workerId: worker.workerId,
			pid: worker.pid,
		});
		appendBootlabEvent(paths, {
			type: "worker_note",
			at: nowIso(),
			workerId: worker.workerId,
			note: `stop requested via recorded pid ${worker.pid}`,
		});
		return { stopped: true, message: `${worker.workerId} via pid ${worker.pid}` };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		appendBootlabEvent(paths, {
			type: "worker_note",
			at: nowIso(),
			workerId: worker.workerId,
			note: `pid stop failed for ${worker.pid}: ${message}`,
		});
		return { stopped: false, message: `${worker.workerId}: ${message}` };
	}
}

export default function bootlabExtension(pi: ExtensionAPI) {
	let dashboardTicker: ReturnType<typeof setInterval> | undefined;
	const activeWorkers = new Map<string, WorkerLaunchHandle>();

	const getPaths = (cwd: string): BootlabPaths => {
		return resolveBootlabPaths(cwd);
	};

	const refreshDashboard = (ctx: { cwd: string; hasUI: boolean; ui: { setWidget: (id: string, lines?: string[]) => void; setStatus: (id: string, text: string) => void; theme: any } }) => {
		if (!ctx.hasUI) return;
		const state = loadBootlabState(getPaths(ctx.cwd));
		ctx.ui.setWidget("bootlab-dashboard", formatStatusLines(state));
		const running = Object.values(state.workers).filter((worker) => worker.status === "running").length;
		const theme = ctx.ui.theme;
		ctx.ui.setStatus(
			"bootlab-status",
			running > 0 ? theme.fg("accent", `bootlab ${running} running`) : theme.fg("dim", "bootlab idle"),
		);
	};

	const spawnSpecs = (specs: BootlabWorkerSpec[], ctx: { cwd: string; hasUI: boolean; ui: { notify: (message: string, level: string) => void }; model?: { provider?: string; id?: string } | null; }) => {
		const paths = getPaths(ctx.cwd);
		const state = loadBootlabState(paths);
		const warnings = collectSerialWarnings(state, specs);
		const extensionEntryPath = getBootlabExtensionEntryPath();
		const handles = specs.map((spec) => {
			const roleDefault = spec.role === "reviewer" ? "bootlab-reviewer" : "bootlab-worker";
			const agent = spec.runner === "demo" ? undefined : loadProjectAgent(ctx.cwd, spec.agent ?? roleDefault);
			const handle = launchWorker(spec, {
				paths,
				cwd: ctx.cwd,
				defaultModel: DEFAULT_BOOTLAB_MODEL,
				defaultThinking: DEFAULT_BOOTLAB_THINKING,
				extensionEntryPath,
				agent,
				onStateChange: () => refreshDashboard(ctx as never),
			});
			activeWorkers.set(spec.workerId, handle);
			handle.completed.finally(() => {
				activeWorkers.delete(spec.workerId);
				refreshDashboard(ctx as never);
			});
			return handle;
		});
		if (ctx.hasUI) {
			ctx.ui.notify(`Spawned ${handles.length} bootlab worker${handles.length === 1 ? "" : "s"}`, "info");
			for (const warning of warnings) {
				ctx.ui.notify(warning, "warning");
			}
		}
		refreshDashboard(ctx as never);
		return { handles, warnings };
	};

	pi.on("session_start", async (_event, ctx) => {
		refreshDashboard(ctx as never);
		if (dashboardTicker) clearInterval(dashboardTicker);
		dashboardTicker = setInterval(() => refreshDashboard(ctx as never), 1000);
	});

	pi.registerTool({
		name: "bootlab_status",
		label: "Bootlab Status",
		description: "Read the current bootlab worker/reviewer ledger, optionally narrowed to one worker or serial.",
		parameters: StatusToolParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const state = loadBootlabState(getPaths(ctx.cwd));
			if (params.ref) {
				const worker = resolveWorkerRef(state, params.ref);
				if (!worker) {
					return { content: [{ type: "text", text: `No bootlab worker found for ${params.ref}.` }] };
				}
				const transcript = readTranscriptEntries(state.paths, worker.workerId, 12)
					.map((entry) => `[${entry.kind}] ${entry.text}`)
					.join("\n");
				return {
					content: [
						{
							type: "text",
							text: [
								`${worker.workerId} | ${worker.role} | ${worker.status}${worker.result ? ` | ${worker.result}` : ""}`,
								worker.serial ? `serial: ${worker.serial}` : "",
								worker.worktree ? `worktree: ${worker.worktree}` : "",
								worker.restingState ? `resting: ${worker.restingState}` : "",
								worker.recoveryCommand ? `recover: ${worker.recoveryCommand}` : "",
								worker.experiment ? `experiment: ${worker.experiment}` : "",
								worker.sessionPath ? `session: ${worker.sessionPath}` : "",
								worker.lastSummary ? `summary: ${worker.lastSummary}` : "",
								transcript ? `recent transcript:\n${transcript}` : "",
							]
								.filter(Boolean)
								.join("\n"),
						},
					],
				};
			}
			return { content: [{ type: "text", text: formatStatusLines(state).join("\n") }] };
		},
	});

	pi.registerTool({
		name: "bootlab_spawn",
		label: "Bootlab Spawn",
		description:
			"Spawn bootlab workers or reviewers as pi subprocesses with stable session files. Use runner=demo for local orchestration smoke tests.",
		parameters: SpawnToolParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const { handles, warnings } = spawnSpecs(
				params.workers.map((spec) => ({ ...spec, runner: spec.runner ?? "pi" })),
				ctx as never,
			);
			return {
				content: [
					{
						type: "text",
						text: `Spawned ${handles.length} bootlab worker${handles.length === 1 ? "" : "s"}.\n${formatSpawnSummary(handles, warnings)}`,
					},
				],
			};
		},
	});

	pi.registerTool({
		name: "bootlab_report",
		label: "Bootlab Report",
		description:
			"Record a structured checkpoint from a bootlab worker or reviewer. Workers should call this at start, after key evidence checkpoints, and before finishing.",
		parameters: ReportToolParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const paths = getPaths(ctx.cwd);
			appendBootlabEvent(paths, {
				type: params.status === "review_requested" ? "review_requested" : "worker_report",
				at: nowIso(),
				workerId: params.workerId,
				phase: params.phase,
				status: params.status,
				result: params.result,
				summary: params.summary,
				artifacts: params.artifacts,
				serial: params.serial,
				worktree: params.worktree,
				restingState: params.restingState,
				recoveryCommand: params.recoveryCommand,
				experiment: params.experiment,
				reviewOf: params.reviewOf,
			});
			refreshDashboard(ctx as never);
			return {
				content: [
					{
						type: "text",
						text: `Recorded ${params.phase} for ${params.workerId}: ${params.summary}${params.result ? ` (${params.result})` : ""}`,
					},
				],
			};
		},
	});

	pi.registerTool({
		name: "bootlab_stop",
		label: "Bootlab Stop",
		description: "Stop one running worker by worker ID/serial, or stop all workers launched from this orchestrator session. Falls back to recorded pid after restart.",
		parameters: StopToolParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const paths = getPaths(ctx.cwd);
			const state = loadBootlabState(paths);
			const targetIds =
				params.ref === "all"
					? Array.from(
							new Set([
								...Array.from(activeWorkers.keys()),
								...Object.values(state.workers)
									.filter((worker) => workerHasOpenProcess(worker))
									.map((worker) => worker.workerId),
							]),
						)
					: (() => {
							const worker = resolveWorkerRef(state, params.ref);
							return worker ? [worker.workerId] : [];
						})();
			if (targetIds.length === 0) {
				return { content: [{ type: "text", text: `No active worker found for ${params.ref}.` }] };
			}

			const stopped: string[] = [];
			const failed: string[] = [];
			for (const targetId of targetIds) {
				const liveHandle = activeWorkers.get(targetId);
				if (liveHandle) {
					liveHandle.stop();
					stopped.push(`${targetId} via handle`);
					continue;
				}
				const worker = state.workers[targetId];
				if (!worker) {
					failed.push(`${targetId}: no ledger entry`);
					continue;
				}
				const result = requestPidStop(paths, worker);
				if (result.stopped) stopped.push(result.message);
				else failed.push(result.message);
			}
			refreshDashboard(ctx as never);
			return {
				content: [
					{
						type: "text",
						text: [
							stopped.length > 0 ? `Stop requested for ${stopped.join(", ")}` : "",
							failed.length > 0 ? `No stop sent for ${failed.join(", ")}` : "",
						]
							.filter(Boolean)
							.join("\n"),
					},
				],
			};
		},
	});

	pi.registerCommand("bootlab-reset", {
		description: "Clear the bootlab runtime ledger, transcripts, and session files",
		handler: async (_args, ctx) => {
			for (const handle of activeWorkers.values()) {
				handle.stop();
			}
			activeWorkers.clear();
			resetBootlabState(getPaths(ctx.cwd));
			refreshDashboard(ctx as never);
			ctx.ui.notify("Bootlab state reset", "info");
		},
	});

	pi.registerCommand("bootlab-status", {
		description: "Show the current bootlab status ledger",
		handler: async (_args, ctx) => {
			const lines = formatStatusLines(loadBootlabState(getPaths(ctx.cwd)));
			if (!ctx.hasUI) {
				console.log(lines.join("\n"));
				return;
			}
			await ctx.ui.custom<void>((_tui, _theme, _kb, done) => ({
				render: (width: number) => lines.map((line) => truncateToWidth(line, width)),
				invalidate: () => {},
				handleInput: (data: string) => {
					if (matchesKey(data, "enter") || matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
						done(undefined);
					}
				},
			}));
		},
	});

	pi.registerCommand("bootlab-watch", {
		description: "Follow one worker by worker ID or serial",
		handler: async (args, ctx) => {
			const ref = args.trim();
			if (!ref) {
				ctx.ui.notify("Usage: /bootlab-watch <worker-id|serial>", "warning");
				return;
			}
			if (!ctx.hasUI) {
				console.log(readTranscriptEntries(getPaths(ctx.cwd), ref).map((entry) => entry.text).join("\n"));
				return;
			}
			let component: BootlabWatchComponent | undefined;
			await ctx.ui.custom<void>(
				(tui, _theme, _kb, done) => {
					component = new BootlabWatchComponent(ref, () => getPaths(ctx.cwd), () => done(undefined), () => tui.requestRender());
					return component;
				},
				{
					overlay: true,
					overlayOptions: {
						anchor: "right-center",
						width: "48%",
						minWidth: 60,
						maxHeight: "85%",
						margin: 1,
					},
				},
			);
			component?.dispose();
		},
	});

	pi.registerCommand("bootlab-open", {
		description: "Switch to a worker's stable session file",
		handler: async (args, ctx) => {
			const ref = args.trim();
			if (!ref) {
				ctx.ui.notify("Usage: /bootlab-open <worker-id|serial>", "warning");
				return;
			}
			const worker = resolveWorkerRef(loadBootlabState(getPaths(ctx.cwd)), ref);
			if (!worker?.sessionPath) {
				ctx.ui.notify(`No session recorded for ${ref}`, "warning");
				return;
			}
			await ctx.switchSession(worker.sessionPath);
		},
	});

	pi.registerCommand("bootlab-stop", {
		description: "Stop one worker by worker ID/serial, or stop all workers from this orchestrator session",
		handler: async (args, ctx) => {
			const ref = args.trim();
			if (!ref) {
				ctx.ui.notify("Usage: /bootlab-stop <worker-id|serial|all>", "warning");
				return;
			}
			const paths = getPaths(ctx.cwd);
			const state = loadBootlabState(paths);
			const targetIds =
				ref === "all"
					? Array.from(
							new Set([
								...Array.from(activeWorkers.keys()),
								...Object.values(state.workers)
									.filter((worker) => workerHasOpenProcess(worker))
									.map((worker) => worker.workerId),
							]),
						)
					: (() => {
							const worker = resolveWorkerRef(state, ref);
							return worker ? [worker.workerId] : [];
						})();
			if (targetIds.length === 0) {
				ctx.ui.notify(`No active worker found for ${ref}`, "warning");
				return;
			}

			const stopped: string[] = [];
			const failed: string[] = [];
			for (const targetId of targetIds) {
				const liveHandle = activeWorkers.get(targetId);
				if (liveHandle) {
					liveHandle.stop();
					stopped.push(`${targetId} via handle`);
					continue;
				}
				const worker = state.workers[targetId];
				if (!worker) {
					failed.push(`${targetId}: no ledger entry`);
					continue;
				}
				const result = requestPidStop(paths, worker);
				if (result.stopped) stopped.push(result.message);
				else failed.push(result.message);
			}
			refreshDashboard(ctx as never);
			if (stopped.length > 0) {
				ctx.ui.notify(`Stop requested for ${stopped.join(", ")}`, "info");
			}
			if (failed.length > 0) {
				ctx.ui.notify(`No stop sent for ${failed.join(", ")}`, "warning");
			}
		},
	});

	pi.registerCommand("bootlab-demo", {
		description: "Spawn a no-device local smoke set of demo workers",
		handler: async (args, ctx) => {
			const requestedCount = Number.parseInt(args.trim() || "4", 10);
			const count = Number.isFinite(requestedCount) && requestedCount > 0 ? Math.min(4, requestedCount) : 4;
			const demoTasks = [
				"Summarize the current repo state in two sentences and pretend to capture a screenshot artifact.",
				"Inspect runtime app names and pretend to validate the shell lane.",
				"Inspect docs/architecture.md and report one relevant risk.",
				"Inspect todos/boot/plan.md and report the next likely milestone.",
			];
			const specs: BootlabWorkerSpec[] = new Array(count).fill(null).map((_, index) => ({
				workerId: `demo-${index + 1}`,
				role: "worker",
				runner: "demo",
				task: demoTasks[index] ?? `Demo task ${index + 1}`,
				experiment: "local-smoke",
				worktree: ctx.cwd,
				cwd: ctx.cwd,
			}));
			spawnSpecs(specs, ctx as never);
		},
	});
}
