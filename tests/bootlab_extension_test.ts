import { launchWorker } from "../.pi/extensions/bootlab/runner.ts";
import {
	appendBootlabEvent,
	buildBootlabPaths,
	loadBootlabState,
	readTranscriptEntries,
	resetBootlabState,
	type BootlabPaths,
} from "../.pi/extensions/bootlab/state.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) {
		throw new Error(message);
	}
}

function makePaths(): BootlabPaths {
	const rootDir = Deno.makeTempDirSync({ prefix: "bootlab-ext-" });
	return buildBootlabPaths(rootDir, `${rootDir}/.git-common`);
}

Deno.test("bootlab reducer keeps latest worker status and artifacts", () => {
	const paths = makePaths();

	appendBootlabEvent(paths, {
		type: "worker_spawned",
		at: new Date().toISOString(),
		workerId: "worker-1",
		role: "worker",
		task: "Smoke task",
		serial: "SERIAL-1",
		restingState: "rooted-android",
		recoveryCommand: "sc -t SERIAL-1 restore-android",
	});
	appendBootlabEvent(paths, {
		type: "worker_process_started",
		at: new Date().toISOString(),
		workerId: "worker-1",
		pid: 123,
	});
	appendBootlabEvent(paths, {
		type: "worker_report",
		at: new Date().toISOString(),
		workerId: "worker-1",
		phase: "checkpoint",
		status: "reported",
		result: "pass",
		summary: "Captured screenshot",
		artifacts: ["/tmp/fake.png"],
	});

	const state = loadBootlabState(paths);
	const worker = state.workers["worker-1"];
	assert(worker !== undefined, "worker should exist");
	assert(worker.status === "reported", `expected reported status, got ${worker.status}`);
	assert(worker.result === "pass", `expected pass result, got ${worker.result}`);
	assert(worker.serial === "SERIAL-1", `expected SERIAL-1, got ${worker.serial}`);
	assert(worker.restingState === "rooted-android", `unexpected resting state ${worker.restingState}`);
	assert(
		worker.recoveryCommand === "sc -t SERIAL-1 restore-android",
		`unexpected recovery command ${worker.recoveryCommand}`,
	);
	assert(worker.lastSummary === "Captured screenshot", `unexpected summary ${worker.lastSummary}`);
	assert(worker.artifacts.includes("/tmp/fake.png"), "artifact should be retained");

	resetBootlabState(paths);
});

Deno.test({
	name: "demo worker spawn writes transcript and completes",
	sanitizeOps: false,
	sanitizeResources: false,
	fn: async () => {
		const paths = makePaths();
		const handle = launchWorker(
			{
				workerId: "demo-1",
				role: "worker",
				runner: "demo",
				task: "Demo task",
				experiment: "local-smoke",
				cwd: Deno.cwd(),
			},
			{
				paths,
				cwd: Deno.cwd(),
			},
		);

		const exitCode = await handle.completed;
		assert(exitCode === 0, `expected demo worker exit 0, got ${exitCode}`);

		const state = loadBootlabState(paths);
		const worker = state.workers["demo-1"];
		assert(worker !== undefined, "demo worker should exist");
		assert(worker.status === "completed", `expected completed status, got ${worker.status}`);

		const transcript = readTranscriptEntries(paths, "demo-1", 32);
		assert(transcript.length >= 3, `expected transcript lines, got ${transcript.length}`);
		assert(
			transcript.some((entry) => entry.text.includes("[demo] demo-1 start")),
			"expected transcript to include demo start line",
		);

		resetBootlabState(paths);
	},
});
