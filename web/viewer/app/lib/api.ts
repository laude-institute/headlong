import type {
  ChatLog,
  Config,
  ControlResult,
  DispatchEvent,
  EnvEntry,
  Identity,
  IdentityActivity,
  IdentityEnv,
  IdentityHealth,
  ImportResult,
  LlmHealth,
  LlmProbeResult,
  IdentityStatus,
  KillallResult,
  LogInfo,
  LogTail,
  MemoryInfo,
  Mindlog,
  MindlogSearchResult,
  OpenRouterModels,
  Recap,
  Usage,
  SelfUpdateResult,
  SpendStatus,
  StepDetail,
  SubTrajectory,
  ThinkerSyncResult,
  ThinkerSyncStatus,
  ThinkersStatus,
  TreeNode,
} from "~/lib/types";

export const API_BASE = import.meta.env.VITE_API_URL ?? "";

async function getJson<T>(path: string): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`);
  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}`);
  }
  return response.json() as Promise<T>;
}

async function sendJson<T>(
  method: string,
  path: string,
  body: unknown
): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    // Control endpoints put the CLI's message in detail.message; plain
    // FastAPI errors put a string in detail.
    let message = `${response.status} ${response.statusText}`;
    try {
      const data = await response.json();
      if (typeof data?.detail === "string") message = data.detail;
      else if (data?.detail?.message) message = data.detail.message;
    } catch {
      // keep default message
    }
    throw new Error(message);
  }
  return response.json() as Promise<T>;
}

function postJson<T>(path: string, body: unknown): Promise<T> {
  return sendJson("POST", path, body ?? {});
}

export function fetchConfig(): Promise<Config> {
  return getJson("/api/config");
}

export function selfUpdate(): Promise<SelfUpdateResult> {
  return postJson("/api/update", {});
}

export function fetchLlmHealth(): Promise<LlmHealth> {
  return getJson("/api/llm-health");
}

export function probeLlm(): Promise<LlmProbeResult> {
  return postJson("/api/llm-health/probe", {});
}

export function fetchIdentities(): Promise<Identity[]> {
  return getJson("/api/identities");
}

export function fetchIdentityStatus(identityId: string): Promise<IdentityStatus> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/status`);
}

export function fetchActivity(identityId: string): Promise<IdentityActivity> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/activity`);
}

export function fetchHealth(identityId: string): Promise<IdentityHealth> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/health`);
}

export function fetchMindlog(
  identityId: string,
  params: { since?: number; until?: number; tail?: number } = {}
): Promise<Mindlog> {
  const search = new URLSearchParams();
  if (params.since !== undefined) search.set("since", String(params.since));
  if (params.until !== undefined) search.set("until", String(params.until));
  if (params.tail !== undefined) search.set("tail", String(params.tail));
  const qs = search.toString();
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/mindlog${qs ? `?${qs}` : ""}`
  );
}

export function fetchRunCommand(
  identityId: string,
  runId: string
): Promise<{ run_id: string; command: string }> {
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/runs/${encodeURIComponent(runId)}/command`
  );
}

export function searchMindlog(
  identityId: string,
  q: string,
  scope: "thoughts" | "all",
  limit = 50
): Promise<MindlogSearchResult> {
  const params = new URLSearchParams({ q, scope, limit: String(limit) });
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/mindlog/search?${params}`
  );
}

export function fetchStep(
  identityId: string,
  stepId: string
): Promise<StepDetail> {
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/step/${encodeURIComponent(stepId)}`
  );
}

export function fetchTree(
  identityId: string,
  node?: string,
  depth = 2
): Promise<TreeNode> {
  const params = new URLSearchParams({ depth: String(depth) });
  if (node) params.set("node", node);
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/tree?${params}`
  );
}

export function fetchSubTraj(
  identityId: string,
  trajId: string
): Promise<SubTrajectory> {
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/traj/${encodeURIComponent(trajId)}`
  );
}

export function fetchLogs(identityId: string): Promise<LogInfo[]> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/logs`);
}

export function fetchLog(
  identityId: string,
  name: string,
  tailBytes = 65536
): Promise<LogTail> {
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/logs/${encodeURIComponent(name)}?tail_bytes=${tailBytes}`
  );
}

export function fetchDispatch(identityId: string): Promise<DispatchEvent[]> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/dispatch`);
}

export function fetchMemories(identityId: string): Promise<MemoryInfo[]> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/memories`);
}

export function fetchMemory(
  identityId: string,
  name: string
): Promise<{ name: string; content: string }> {
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/memories/${encodeURIComponent(name)}`
  );
}

export function fetchRecap(identityId: string): Promise<Recap> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/recap`);
}

export function refreshRecap(
  identityId: string,
  rebuild = false
): Promise<{ ok: boolean }> {
  return postJson(`/api/identities/${encodeURIComponent(identityId)}/recap/refresh`, {
    rebuild,
  });
}

export function fetchUsage(identityId: string): Promise<Usage> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/usage`);
}

export function fetchSpend(identityId: string): Promise<SpendStatus> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/spend`);
}

export function refreshUsage(
  identityId: string,
  rebuild = false
): Promise<{ ok: boolean }> {
  return postJson(`/api/identities/${encodeURIComponent(identityId)}/usage/refresh`, {
    rebuild,
  });
}

export function fetchThinkers(identityId: string): Promise<ThinkersStatus> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/thinkers`);
}

export function fetchThinkerSync(identityId: string): Promise<ThinkerSyncStatus> {
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/thinker-sync`
  );
}

export function pullThinkerSync(
  identityId: string,
  names: string[] = []
): Promise<ThinkerSyncResult> {
  return postJson(
    `/api/identities/${encodeURIComponent(identityId)}/thinker-sync`,
    { names }
  );
}

export function startThinkers(
  identityId: string,
  names: string[] = []
): Promise<ControlResult> {
  return postJson(
    `/api/identities/${encodeURIComponent(identityId)}/thinkers/start`,
    { names }
  );
}

export function stopThinkers(
  identityId: string,
  names: string[] = [],
  force = false
): Promise<ControlResult> {
  return postJson(
    `/api/identities/${encodeURIComponent(identityId)}/thinkers/stop`,
    { names, force }
  );
}

export function stepThinker(
  identityId: string,
  name: string
): Promise<ControlResult> {
  return postJson(
    `/api/identities/${encodeURIComponent(identityId)}/thinkers/${encodeURIComponent(name)}/step`,
    {}
  );
}

export function setThinkerEnabled(
  identityId: string,
  name: string,
  enabled: boolean
): Promise<{ ok: boolean; name: string; disabled: boolean; needs_restart?: boolean }> {
  return postJson(
    `/api/identities/${encodeURIComponent(identityId)}/thinkers/${encodeURIComponent(name)}/${enabled ? "enable" : "disable"}`,
    {}
  );
}

export function fetchChat(
  identityId: string,
  tail = 200,
  withName?: string
): Promise<ChatLog> {
  const withParam = withName ? `&with=${encodeURIComponent(withName)}` : "";
  return getJson(
    `/api/identities/${encodeURIComponent(identityId)}/chat?tail=${tail}${withParam}`
  );
}

export function sendChat(
  identityId: string,
  content: string,
  fromName: string
): Promise<{ ok: boolean; from: string; to: string }> {
  return postJson(`/api/identities/${encodeURIComponent(identityId)}/chat`, {
    content,
    from_name: fromName,
  });
}

export function fetchPushKey(): Promise<{ key: string }> {
  return getJson("/api/push/key");
}

export function subscribePush(
  name: string,
  subscription: PushSubscriptionJSON
): Promise<{ ok: boolean; subscriptions: number }> {
  return postJson("/api/push/subscriptions", { name, subscription });
}

export function unsubscribePush(
  endpoint: string
): Promise<{ ok: boolean; removed: boolean }> {
  return postJson("/api/push/unsubscribe", { endpoint });
}

export function createIdentity(name: string): Promise<{ id: string; name: string }> {
  return postJson("/api/identities", { name });
}

export function killAll(dryRun: boolean): Promise<KillallResult> {
  return postJson("/api/killall", { dry_run: dryRun });
}

// Export endpoints are plain downloads — link to them, don't fetch.
export function exportIdentityUrl(identityId: string, soulOnly = false): string {
  const suffix = soulOnly ? "?soul_only=true" : "";
  return `${API_BASE}/api/identities/${encodeURIComponent(identityId)}/export${suffix}`;
}

export interface ExportJob {
  job_id: string;
  identity_id: string;
  status: "running" | "done" | "failed";
  started_at: string;
  soul_only: boolean;
  slim: boolean;
  seconds: number;
  size: number | null;
  filename: string | null;
  error: string | null;
  download_url?: string;
}

export function startExportJob(
  identityId: string,
  opts: { soulOnly: boolean; slim: boolean }
): Promise<ExportJob> {
  return postJson(
    `/api/identities/${encodeURIComponent(identityId)}/export-jobs`,
    { soul_only: opts.soulOnly, slim: opts.slim }
  );
}

export function fetchExportJobs(identityId: string): Promise<ExportJob[]> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/export-jobs`);
}

export function deleteExportJob(jobId: string): Promise<{ ok: boolean }> {
  return sendJson("DELETE", `/api/export-jobs/${encodeURIComponent(jobId)}`, undefined);
}

export function fetchExportJob(jobId: string): Promise<ExportJob> {
  return getJson(`/api/export-jobs/${encodeURIComponent(jobId)}`);
}

export function exportJobDownloadUrl(job: ExportJob): string {
  return `${API_BASE}${job.download_url ?? `/api/export-jobs/${job.job_id}/download`}`;
}

export function exportAllUrl(): string {
  return `${API_BASE}/api/export`;
}

export async function importIdentities(
  file: File,
  name?: string
): Promise<ImportResult> {
  const suffix = name ? `?name=${encodeURIComponent(name)}` : "";
  const response = await fetch(`${API_BASE}/api/identities/import${suffix}`, {
    method: "POST",
    headers: { "Content-Type": "application/gzip" },
    body: file,
  });
  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`;
    try {
      const data = await response.json();
      if (typeof data?.detail === "string") message = data.detail;
      else if (data?.detail?.message) message = data.detail.message;
    } catch {
      // keep default message
    }
    throw new Error(message);
  }
  return response.json() as Promise<ImportResult>;
}

export function fetchOpenRouterModels(): Promise<OpenRouterModels> {
  return getJson("/api/openrouter/models");
}

export function fetchIdentityEnv(identityId: string): Promise<IdentityEnv> {
  return getJson(`/api/identities/${encodeURIComponent(identityId)}/env`);
}

export function putEnvVar(
  identityId: string,
  key: string,
  value: string
): Promise<EnvEntry> {
  return sendJson(
    "PUT",
    `/api/identities/${encodeURIComponent(identityId)}/env`,
    { key, value }
  );
}

export function deleteEnvVar(
  identityId: string,
  key: string
): Promise<{ ok: boolean; key: string }> {
  return sendJson(
    "DELETE",
    `/api/identities/${encodeURIComponent(identityId)}/env/${encodeURIComponent(key)}`,
    undefined
  );
}

export const IN_PROGRESS_POLL_MS = 2000;

export function pollWhileLive(live: boolean | undefined): number | false {
  return live ? IN_PROGRESS_POLL_MS : false;
}
