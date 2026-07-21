import type { NativeSdkJson } from "../types/zero";
import { isNative } from "./bridge";

// In-app self-update (same flow as Spork/Quad, modeled on milim): the Zig
// side checks GitHub's latest release, downloads + verifies the platform
// package, and swaps the install on relaunch. Both network steps run as
// poll-based jobs (see src-zig/update.zig's module doc) because the bridge
// dispatches synchronously on the UI thread.

export type UpdateInfo = {
  version: string;
  assetName: string;
  downloadUrl: string;
  checksumUrl: string;
};

export type UpdateProgress = {
  downloadedBytes: number;
  totalBytes: number | null;
};

const DISMISSED_KEY = "maat.dismissed-release";
const JOB_POLL_INTERVAL_MS = 150;
const JOB_POLL_MAX_INTERVAL_MS = 1000;
const PROGRESS_POLL_INTERVAL_MS = 200;

function invoke<T>(command: string, payload?: Record<string, unknown>): Promise<T> {
  return window.zero!.invoke<T>(command, payload as unknown as NativeSdkJson | undefined);
}

type JobStatus = { done: boolean; report: unknown; error: string | null };

async function pollJob<T>(jobId: string): Promise<T> {
  let delayMs = JOB_POLL_INTERVAL_MS;
  for (;;) {
    const status = await invoke<JobStatus>("update_job_status", { jobId });
    if (status.done) {
      if (status.error) throw new Error(status.error);
      return status.report as T;
    }
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    delayMs = Math.min(delayMs * 2, JOB_POLL_MAX_INTERVAL_MS);
  }
}

/**
 * The newest release's update package, if it's newer than the running build
 * and the user hasn't dismissed it. Callers treat any rejection as "no
 * update" — an update check must never surface an error.
 */
export async function checkForUpdate(): Promise<UpdateInfo | null> {
  if (!isNative()) return null;
  const { jobId } = await invoke<{ jobId: string }>("update_check_start");
  const report = await pollJob<{ update: UpdateInfo | null }>(jobId);
  if (!report.update) return null;
  if (localStorage.getItem(DISMISSED_KEY) === report.update.version) return null;
  return report.update;
}

/** Stop notifying about this release (until an even newer one ships). */
export function dismissUpdate(version: string) {
  localStorage.setItem(DISMISSED_KEY, version);
}

/**
 * Download + verify the update, then hand it to the swap script. On success
 * the app exits and relaunches as the new version, so the returned promise
 * only settles on failure. `onProgress(null)` marks the install phase.
 */
export async function downloadAndInstall(
  update: UpdateInfo,
  onProgress: (progress: UpdateProgress | null) => void,
): Promise<void> {
  const { jobId } = await invoke<{ jobId: string }>("update_download_start", {
    assetName: update.assetName,
    downloadUrl: update.downloadUrl,
    checksumUrl: update.checksumUrl,
  });

  let downloading = true;
  const progressLoop = (async () => {
    while (downloading) {
      try {
        onProgress(await invoke<UpdateProgress>("update_progress"));
      } catch {
        // Progress is cosmetic; the job poll below carries the real outcome.
      }
      await new Promise((resolve) => setTimeout(resolve, PROGRESS_POLL_INTERVAL_MS));
    }
  })();

  let report: { stagedPath: string };
  try {
    report = await pollJob<{ stagedPath: string }>(jobId);
  } finally {
    downloading = false;
    await progressLoop;
  }

  onProgress(null);
  await invoke("update_apply", { updatePath: report.stagedPath });
}

/** Error left behind by a failed swap after the app closed, if any (once). */
export async function takeUpdateRecoveryError(): Promise<string | null> {
  if (!isNative()) return null;
  try {
    return (await invoke<{ error: string | null }>("update_recovery_error")).error;
  } catch {
    return null;
  }
}
