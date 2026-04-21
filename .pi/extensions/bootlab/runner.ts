import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import {
	type BootlabEvent,
	type BootlabPaths,
	type BootlabWorkerRunner,
	type BootlabWorkerSpec,
	appendBootlabEvent,
	appendTranscriptEntry,
	nowIso,
} from "./state.ts";

export interface BootlabAgentConfig {
	name: string;
	description: string;
	model?: string;
	tools?: string[];
	systemPrompt: string;
	filePath: string;
}

export interface LaunchWorkerOptions {
	paths: BootlabPaths;
	cwd: string;
	defaultModel?: string;
	defaultThinking?: "minimal" | "low" | "medium" | "high" | "xhigh";
	extensionEntryPath?: string;
	agent?: BootlabAgentConfig;
	onStateChange?: () => void;
}

export interface WorkerLaunchHandle {
	workerId: string;
	pid?: number;
	sessionPath?: string;
	process?: ChildProcess;
	completed: Promise<number>;
	stop: () => void;
}

export function getBootlabExtensionEntryPath(): string {
	return fileURLToPath(import.meta.url).replace(/runner\.ts$/, "index.ts");
}

function writeTempPrompt(workerId: string, prompt: string): { filePath: string; cleanup: () => void } {
	const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "bootlab-prompt-"));
	const filePath = path.join(tmpDir, `${workerId}.md`);
	fs.writeFileSync(filePath, prompt, { encoding: "utf-8", mode: 0o600 });
	return {
		filePath,
		cleanup: () => fs.rmSync(tmpDir, { recursive: true, force: true }),
	};
}

function parseFrontmatter(content: string): { frontmatter: Record<string, string>; body: string } {
	if (!content.startsWith("---\n")) {
		return { frontmatter: {}, body: content };
	}

	const end = content.indexOf("\n---\n", 4);
	if (end === -1) {
		return { frontmatter: {}, body: content };
	}

	const header = content.slice(4, end);
	const body = content.slice(end + 5);
	const frontmatter: Record<string, string> = {};
	for (const line of header.split("\n")) {
		const separator = line.indexOf(":");
		if (separator === -1) continue;
		const key = line.slice(0, separator).trim();
		const value = line.slice(separator + 1).trim();
		if (key) frontmatter[key] = value;
	}
	return { frontmatter, body };
}

function findNearestProjectAgentsDir(cwd: string): string | null {
	let currentDir = path.resolve(cwd);
	while (true) {
		const candidate = path.join(currentDir, ".pi", "agents");
		if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory()) {
			return candidate;
		}
		const parent = path.dirname(currentDir);
		if (parent === currentDir) {
			return null;
		}
		currentDir = parent;
	}
}

export function loadProjectAgent(cwd: string, agentName: string): BootlabAgentConfig | undefined {
	const agentsDir = findNearestProjectAgentsDir(cwd);
	if (!agentsDir) return undefined;
	const filePath = path.join(agentsDir, `${agentName}.md`);
	if (!fs.existsSync(filePath)) return undefined;
	const content = fs.readFileSync(filePath, "utf-8");
	const { frontmatter, body } = parseFrontmatter(content);
	if (!frontmatter.name || !frontmatter.description) return undefined;
	const tools = frontmatter.tools
		?.split(",")
		.map((tool) => tool.trim())
		.filter(Boolean);
	return {
		name: frontmatter.name,
		description: frontmatter.description,
		model: frontmatter.model,
		tools: tools && tools.length > 0 ? tools : undefined,
		systemPrompt: body.trim(),
		filePath,
	};
}

function buildInitialPrompt(spec: BootlabWorkerSpec): string {
	const lines = [
		`Role: ${spec.role}`,
		`Worker ID: ${spec.workerId}`,
		spec.serial ? `Assigned serial: ${spec.serial}` : "Assigned serial: none",
		spec.worktree ? `Assigned worktree: ${spec.worktree}` : "Assigned worktree: current cwd",
		spec.restingState ? `Expected resting state: ${spec.restingState}` : "",
		spec.recoveryCommand ? `Recovery command: ${spec.recoveryCommand}` : "",
		spec.experiment ? `Experiment: ${spec.experiment}` : "Experiment: ad hoc",
		spec.reviewOf ? `Review target: ${spec.reviewOf}` : "",
		"",
		"Task:",
		spec.task,
	];
	return lines.filter(Boolean).join("\n");
}

function buildSpawnEvent(spec: BootlabWorkerSpec, sessionPath?: string): BootlabEvent {
	return {
		type: "worker_spawned",
		at: nowIso(),
		workerId: spec.workerId,
		role: spec.role,
		runner: spec.runner ?? "pi",
		task: spec.task,
		serial: spec.serial,
		worktree: spec.worktree,
		restingState: spec.restingState,
		recoveryCommand: spec.recoveryCommand,
		experiment: spec.experiment,
		reviewOf: spec.reviewOf,
		agent: spec.agent,
		model: spec.model,
		cwd: spec.cwd,
		sessionPath,
	};
}

function formatToolCall(name: string, args: unknown): string {
	const serialized = JSON.stringify(args);
	if (!serialized || serialized === "{}") {
		return `$ tool ${name}`;
	}
	return `$ tool ${name} ${serialized}`;
}

function appendNote(paths: BootlabPaths, workerId: string, text: string): void {
	appendTranscriptEntry(paths, workerId, { at: nowIso(), kind: "note", text });
}

function handlePiJsonLine(paths: BootlabPaths, workerId: string, line: string): { terminalAssistantMessage: boolean } {
	let event: any;
	try {
		event = JSON.parse(line);
	} catch {
		appendTranscriptEntry(paths, workerId, { at: nowIso(), kind: "text", text: line });
		return { terminalAssistantMessage: false };
	}

	if (event.type !== "message_end" && event.type !== "tool_result_end") {
		return { terminalAssistantMessage: false };
	}

	const message = event.message;
	if (!message || !Array.isArray(message.content)) {
		return { terminalAssistantMessage: false };
	}

	let terminalAssistantMessage = false;

	for (const part of message.content) {
		if (!part || typeof part !== "object") {
			continue;
		}
		if (part.type === "text" && typeof part.text === "string") {
			appendTranscriptEntry(paths, workerId, { at: nowIso(), kind: "text", text: part.text });
		}
		if (part.type === "toolCall" && typeof part.name === "string") {
			appendTranscriptEntry(paths, workerId, {
				at: nowIso(),
				kind: "tool",
				text: formatToolCall(part.name, part.arguments),
			});
		}
	}

	if (
		event.type === "message_end" &&
		message.role === "assistant" &&
		typeof message.stopReason === "string" &&
		message.stopReason !== "toolUse"
	) {
		terminalAssistantMessage = true;
	}

	return { terminalAssistantMessage };
}

function getPiInvocation(args: string[]): { command: string; args: string[] } {
	const currentScript = process.argv[1];
	const isBunVirtualScript = currentScript?.startsWith("/$bunfs/root/");
	if (currentScript && !isBunVirtualScript && fs.existsSync(currentScript)) {
		return { command: process.execPath, args: [currentScript, ...args] };
	}

	const execName = path.basename(process.execPath).toLowerCase();
	const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName);
	if (!isGenericRuntime) {
		return { command: process.execPath, args };
	}

	return { command: "pi", args };
}

function buildDemoCommand(spec: BootlabWorkerSpec): { command: string; args: string[] } {
	const payload = JSON.stringify({
		workerId: spec.workerId,
		role: spec.role,
		serial: spec.serial ?? "none",
		task: spec.task,
	});
	const script = `
const payload = ${payload};
const lines = [
  "[demo] " + payload.workerId + " start",
  "[demo] role=" + payload.role + " serial=" + payload.serial,
  "[demo] task=" + payload.task,
  "[demo] checkpoint one",
  "[demo] checkpoint two",
  "[demo] done"
];
let index = 0;
const timer = setInterval(() => {
  if (index >= lines.length) {
    clearInterval(timer);
    process.exit(0);
    return;
  }
  console.log(lines[index]);
  index += 1;
}, 120);
`;
	return { command: process.execPath, args: ["-e", script] };
}

export function launchWorker(spec: BootlabWorkerSpec, options: LaunchWorkerOptions): WorkerLaunchHandle {
	const paths = options.paths;
	const workerCwd = path.resolve(spec.cwd ?? spec.worktree ?? options.cwd);
	const runner: BootlabWorkerRunner = spec.runner ?? "pi";
	const sessionPath =
		runner === "pi" ? path.join(paths.sessionsDir, `${spec.workerId}.jsonl`) : undefined;

	appendBootlabEvent(paths, buildSpawnEvent(spec, sessionPath));
	options.onStateChange?.();

	let promptCleanup: (() => void) | undefined;
	let child: ChildProcess | undefined;

	const completed = new Promise<number>((resolve) => {
		const startEvent: BootlabEvent = {
			type: "worker_process_started",
			at: nowIso(),
			workerId: spec.workerId,
		};

		if (runner === "demo") {
			const demo = buildDemoCommand(spec);
			child = spawn(demo.command, demo.args, {
				cwd: workerCwd,
				shell: false,
				stdio: ["ignore", "pipe", "pipe"],
			});
		} else {
			const agent = options.agent;
			const args = ["--mode", "json", "-p"];
			args.push("--session", sessionPath!);
			args.push("--extension", options.extensionEntryPath ?? getBootlabExtensionEntryPath());

			const model = spec.model ?? agent?.model ?? options.defaultModel;
			if (model) args.push("--model", model);
			args.push("--thinking", spec.thinking ?? options.defaultThinking ?? "xhigh");
			if (agent?.tools && agent.tools.length > 0) {
				args.push("--tools", agent.tools.join(","));
			}
			if (agent?.systemPrompt) {
				const tmp = writeTempPrompt(spec.workerId, agent.systemPrompt);
				promptCleanup = tmp.cleanup;
				args.push("--append-system-prompt", tmp.filePath);
			}
			args.push(buildInitialPrompt(spec));
			const invocation = getPiInvocation(args);
			child = spawn(invocation.command, invocation.args, {
				cwd: workerCwd,
				shell: false,
				stdio: ["ignore", "pipe", "pipe"],
			});
		}

		startEvent.pid = child.pid;
		appendBootlabEvent(paths, startEvent);
		appendNote(paths, spec.workerId, `process started${child.pid ? ` pid=${child.pid}` : ""}`);
		options.onStateChange?.();

		let stdoutBuffer = "";
		let stderrBuffer = "";
		let reapTimer: ReturnType<typeof setTimeout> | undefined;

		const onStdoutLine = (line: string) => {
			if (!line.trim()) return;
			if (runner === "pi") {
				const result = handlePiJsonLine(paths, spec.workerId, line);
				if (result.terminalAssistantMessage && !reapTimer) {
					reapTimer = setTimeout(() => {
						if (child && !child.killed) {
							appendTranscriptEntry(paths, spec.workerId, {
								at: nowIso(),
								kind: "note",
								text: "reaped pi print-mode worker after terminal assistant message",
							});
							child.kill("SIGTERM");
						}
					}, 3000);
				}
			} else {
				appendTranscriptEntry(paths, spec.workerId, { at: nowIso(), kind: "text", text: line });
			}
			options.onStateChange?.();
		};

		child.stdout?.on("data", (data: Uint8Array | string) => {
			stdoutBuffer += data.toString();
			const lines = stdoutBuffer.split("\n");
			stdoutBuffer = lines.pop() ?? "";
			for (const line of lines) onStdoutLine(line);
		});

		child.stderr?.on("data", (data: Uint8Array | string) => {
			stderrBuffer += data.toString();
			const lines = stderrBuffer.split("\n");
			stderrBuffer = lines.pop() ?? "";
			for (const line of lines) {
				if (!line.trim()) continue;
				appendTranscriptEntry(paths, spec.workerId, { at: nowIso(), kind: "note", text: `stderr: ${line}` });
			}
			options.onStateChange?.();
		});

		child.on("close", (code) => {
			if (reapTimer) clearTimeout(reapTimer);
			if (stdoutBuffer.trim()) onStdoutLine(stdoutBuffer);
			if (stderrBuffer.trim()) {
				appendTranscriptEntry(paths, spec.workerId, { at: nowIso(), kind: "note", text: `stderr: ${stderrBuffer}` });
			}
			appendBootlabEvent(paths, {
				type: "worker_exit",
				at: nowIso(),
				workerId: spec.workerId,
				exitCode: code ?? 0,
			});
			appendNote(paths, spec.workerId, `process exited code=${code ?? 0}`);
			options.onStateChange?.();
			promptCleanup?.();
			resolve(code ?? 0);
		});

		child.on("error", (error) => {
			if (reapTimer) clearTimeout(reapTimer);
			appendTranscriptEntry(paths, spec.workerId, {
				at: nowIso(),
				kind: "note",
				text: `spawn error: ${error.message}`,
			});
			appendBootlabEvent(paths, {
				type: "worker_exit",
				at: nowIso(),
				workerId: spec.workerId,
				exitCode: 1,
			});
			options.onStateChange?.();
			promptCleanup?.();
			resolve(1);
		});
	});

	return {
		workerId: spec.workerId,
		pid: child?.pid,
		sessionPath,
		process: child,
		completed,
		stop: () => {
			if (!child || child.killed) return;
			appendBootlabEvent(paths, {
				type: "worker_stopped",
				at: nowIso(),
				workerId: spec.workerId,
			});
			appendNote(paths, spec.workerId, "stop requested");
			options.onStateChange?.();
			child.kill("SIGTERM");
		},
	};
}
