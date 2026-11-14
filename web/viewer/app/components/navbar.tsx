import { useQuery } from "@tanstack/react-query";
import { Activity, Moon, RefreshCw, Sun } from "lucide-react";
import { useTheme } from "next-themes";
import { useEffect, useState } from "react";
import { Link } from "react-router";
import { toast } from "sonner";

import { useControlsEnabled } from "~/components/thinker-controls";
import { Button } from "~/components/ui/button";
import {
  API_BASE,
  fetchConfig,
  fetchLlmHealth,
  probeLlm,
  selfUpdate,
} from "~/lib/api";
import type { Config, LlmProbeResult } from "~/lib/types";

function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  if (!mounted) return <div className="h-8 w-8" />;
  return (
    <Button
      variant="ghost"
      size="icon"
      className="h-8 w-8"
      onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}
      aria-label="Toggle theme"
    >
      {resolvedTheme === "dark" ? (
        <Sun className="h-4 w-4" />
      ) : (
        <Moon className="h-4 w-4" />
      )}
    </Button>
  );
}

/** Wait through the restart: poll /api/config until the commit changes,
 * then reload the page (which also picks up the rebuilt frontend). */
function pollForNewBuild(oldCommit: string, timeoutMs = 5 * 60 * 1000) {
  const started = Date.now();
  const tick = async () => {
    if (Date.now() - started > timeoutMs) {
      toast.error("Update timed out — check `journalctl -u headlong-web` on the box");
      return;
    }
    try {
      const response = await fetch(`${API_BASE}/api/config`);
      if (response.ok) {
        const config = (await response.json()) as Config;
        if (config.git_commit && config.git_commit !== oldCommit) {
          window.location.reload();
          return;
        }
      }
    } catch {
      // server is restarting/rebuilding — keep waiting
    }
    setTimeout(tick, 3000);
  };
  setTimeout(tick, 3000);
}

/** Headline for a hard failure on the last real LLM call (from bin/llm's
 * marker). Shown in the chip itself so it is visible on every page. */
const LAST_CALL_LABEL: Record<string, string> = {
  credit: "out of credit",
  auth: "key rejected",
  rate: "rate limited",
  budget: "spend limit reached",
  other: "last call failed",
};
const LAST_CALL_HINT: Record<string, string> = {
  openrouter: "https://openrouter.ai/settings/credits",
  anthropic: "https://console.anthropic.com/settings/billing",
  openai: "https://platform.openai.com/settings/organization/billing",
};

const HEALTH_DOT: Record<string, string> = {
  ok: "bg-green-500",
  degraded: "bg-amber-500",
  erroring: "bg-red-500",
  unknown: "bg-muted-foreground/40",
};

/** LLM provider health: passive signals from the mind logs (failure-marker
 * steps, thought cadence), plus an on-demand real probe call. */
function LlmHealthChip() {
  const controlsEnabled = useControlsEnabled();
  const [open, setOpen] = useState(false);
  const [probing, setProbing] = useState(false);
  const [probe, setProbe] = useState<LlmProbeResult | null>(null);

  const { data: health } = useQuery({
    queryKey: ["llm-health"],
    queryFn: fetchLlmHealth,
    refetchInterval: 30000,
  });
  if (!health || (health.status === "unknown" && !health.last_call)) return null;
  const last = health.last_call ?? null;
  // budget is not the provider failing, but the mind is just as stopped.
  const hardFail =
    !!last && !last.ok && (last.kind === "credit" || last.kind === "auth" || last.kind === "budget");
  const failLabel = last && !last.ok ? LAST_CALL_LABEL[last.kind ?? "other"] : null;
  const budgetIdentity =
    last?.kind === "budget" ? health.identities.find((i) => i.name === last.identity) : undefined;

  const runProbe = async () => {
    setProbing(true);
    setProbe(null);
    try {
      setProbe(await probeLlm());
    } catch (error) {
      toast.error((error as Error).message);
    } finally {
      setProbing(false);
    }
  };

  return (
    <div className="relative">
      <button
        className={`inline-flex h-8 items-center gap-1.5 font-mono text-[11px] leading-none hover:text-foreground ${
          hardFail ? "rounded bg-red-600/15 px-2 font-semibold text-red-600" : "text-muted-foreground"
        }`}
        title={`LLM provider: ${health.status}${failLabel ? ` — ${failLabel}` : ""}`}
        onClick={() => setOpen(!open)}
      >
        <span className={`inline-block h-2 w-2 rounded-full ${HEALTH_DOT[health.status]}`} />
        {hardFail ? `llm: ${failLabel}` : "llm"}
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} />
          <div className="absolute right-0 top-8 z-50 w-80 space-y-2 rounded-md border bg-background p-3 text-xs shadow-md">
            <div className="flex items-baseline justify-between">
              <span className="font-medium">
                LLM provider: <span className="font-mono">{health.status}</span>
              </span>
              <span className="text-[10px] text-muted-foreground">
                {health.failures_1h} failure(s) in the last hour
              </span>
            </div>
            {last && !last.ok && (
              <div
                className={`rounded border p-2 ${
                  hardFail ? "border-red-600/40 bg-red-600/10" : "border-amber-500/40 bg-amber-500/10"
                }`}
              >
                <div className="font-semibold">
                  Last call failed: {failLabel}
                  {last.http_code ? ` (HTTP ${last.http_code})` : ""}
                </div>
                {last.message && (
                  <div className="mt-1 break-words text-[11px] text-muted-foreground">{last.message}</div>
                )}
                {last.kind === "credit" && (
                  <div className="mt-1 text-[11px]">
                    The mind keeps trying but every thought fails until the key has credit.
                    {last.provider && LAST_CALL_HINT[last.provider] && (
                      <>
                        {" "}
                        Top up at{" "}
                        <a className="underline" href={LAST_CALL_HINT[last.provider]} target="_blank" rel="noreferrer">
                          {LAST_CALL_HINT[last.provider]}
                        </a>
                        , or put a new key in ~/.headlong/.env, then restart the mind.
                      </>
                    )}
                  </div>
                )}
                {last.kind === "auth" && (
                  <div className="mt-1 text-[11px]">Put a working key in ~/.headlong/.env, then restart the mind.</div>
                )}
                {last.kind === "budget" && (
                  <div className="mt-1 text-[11px]">
                    {last.identity ? <span className="font-mono">{last.identity}</span> : "An identity"} reached
                    its own spend limit (LLM_SPEND_LIMIT_USD), so llm refuses its model calls before
                    sending anything; the provider is fine. Raise the limit in its .env to continue.
                    {budgetIdentity && (
                      <>
                        {" "}
                        <Link
                          className="underline"
                          to={`/i/${encodeURIComponent(budgetIdentity.id)}/usage`}
                          onClick={() => setOpen(false)}
                        >
                          See what it spent
                        </Link>
                        .
                      </>
                    )}
                  </div>
                )}
                {last.ts && <div className="mt-1 text-[10px] text-muted-foreground">last tried {last.ts}</div>}
              </div>
            )}
            {health.identities.map((identity) => (
              <div key={identity.id} className="rounded border p-2">
                <div className="flex items-baseline gap-2 font-mono">
                  <span>{identity.name}</span>
                  {identity.live && <span className="text-green-600">live</span>}
                  <span className="ml-auto text-muted-foreground">
                    {identity.failures_1h > 0
                      ? `${identity.failures_1h} fail/h`
                      : "no failures"}
                  </span>
                </div>
                {identity.cadence && (
                  <div className="text-muted-foreground">
                    thought cadence: {identity.cadence.recent_median_s}s median
                    {identity.cadence.baseline_median_s
                      ? ` (baseline ${identity.cadence.baseline_median_s}s)`
                      : ""}
                  </div>
                )}
                {identity.last_failure && (
                  <div className="mt-1 text-[10px] text-muted-foreground">
                    last: {identity.last_failure.content}
                  </div>
                )}
              </div>
            ))}
            {controlsEnabled && (
              <div className="space-y-1">
                <Button
                  variant="outline"
                  size="sm"
                  className="w-full"
                  disabled={probing}
                  title="Fires one tiny real LLM call (fractions of a cent)"
                  onClick={runProbe}
                >
                  <Activity className={`size-3 ${probing ? "animate-pulse" : ""}`} />
                  {probing ? "Probing…" : "Probe provider now"}
                </Button>
                {probe && (
                  <div className="font-mono text-[11px]">
                    {probe.ok
                      ? `ok · ${probe.latency_ms}ms${probe.provider ? ` · via ${probe.provider}` : ""}`
                      : `failed · ${probe.error}`}
                  </div>
                )}
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}

/** The build stamp doubles as a meta menu: click for server details and —
 * when the server allows it — a "pull latest & restart" control. */
function BuildMenu({ config }: { config: Config }) {
  const controlsEnabled = useControlsEnabled();
  const [open, setOpen] = useState(false);
  const [updating, setUpdating] = useState(false);

  const runUpdate = async () => {
    setUpdating(true);
    try {
      const result = await selfUpdate();
      if (!result.updated) {
        toast.info(`Already up to date (${result.commit})`);
        setUpdating(false);
        return;
      }
      toast.success(
        `Updating ${result.from_commit} → ${result.to_commit} — restarting, page reloads when it's back (~1-2 min)`
      );
      pollForNewBuild(config.git_commit ?? "");
    } catch (error) {
      toast.error((error as Error).message);
      setUpdating(false);
    }
  };

  return (
    <div className="relative">
      <button
        className="inline-flex h-8 items-center font-mono text-[11px] leading-none text-muted-foreground hover:text-foreground"
        title="Build info"
        onClick={() => setOpen(!open)}
      >
        {config.git_commit}
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} />
          <div className="absolute right-0 top-8 z-50 w-72 space-y-2 rounded-md border bg-background p-3 text-xs shadow-md">
            <div className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 font-mono">
              <span className="text-muted-foreground">commit</span>
              <span>
                {config.git_commit}
                {config.git_branch ? ` (${config.git_branch})` : ""}
              </span>
              <span className="text-muted-foreground">version</span>
              <span>{config.version}</span>
              <span className="text-muted-foreground">root</span>
              <span className="break-all">{config.root}</span>
            </div>
            {config.self_update_enabled && controlsEnabled && (
              <Button
                variant="outline"
                size="sm"
                className="w-full"
                disabled={updating}
                onClick={runUpdate}
              >
                <RefreshCw className={`size-3 ${updating ? "animate-spin" : ""}`} />
                {updating ? "Updating…" : "Pull latest & restart"}
              </Button>
            )}
          </div>
        </>
      )}
    </div>
  );
}

export function Navbar() {
  const { data: config } = useQuery({
    queryKey: ["config"],
    queryFn: fetchConfig,
    staleTime: Infinity,
  });
  return (
    <header className="sticky top-0 z-50 border-b border-border bg-background">
      <div className="flex h-12 items-center justify-between px-4">
        <Link to="/" className="font-mono text-sm font-semibold tracking-tight">
          headlong
        </Link>
        <div className="flex items-center gap-3">
          <LlmHealthChip />
          {config?.git_commit && <BuildMenu config={config} />}
          <ThemeToggle />
        </div>
      </div>
    </header>
  );
}
