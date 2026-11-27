import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Info, RotateCcw } from "lucide-react";
import { useMemo, useState } from "react";
import { toast } from "sonner";

import { Badge } from "~/components/ui/badge";
import { Button } from "~/components/ui/button";
import { Input } from "~/components/ui/input";
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from "~/components/ui/select";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "~/components/ui/tooltip";
import { useControlsEnabled } from "~/components/thinker-controls";
import { deleteEnvVar, fetchOpenRouterModels, putEnvVar } from "~/lib/api";
import type { IdentityEnv, OpenRouterModels } from "~/lib/types";

/* Knob semantics from design/model-resolution.md — keep the two in sync. */
const MODEL_KNOBS: { key: string; label: string; tip: string }[] = [
  {
    key: "SHELLM_MODEL",
    label: "main model",
    tip: "The system-wide model: shellm agent loops and the default for every other knob here. claude-* names go straight to Anthropic; vendor/model names (e.g. openai/gpt-oss-120b) go via OpenRouter — each provider needs its own API key in .env.",
  },
  {
    key: "THINK_MODEL",
    label: "thinker model",
    tip: "Overrides the model for thinker steps only (inner monologue, actor, monolith, …). Falls back to the main model when unset. Also settable per identity as think_model= in info.txt.",
  },
  {
    key: "SHELLM_FAST_MODEL",
    label: "fast model",
    tip: "Cheap model class for utility calls: run summaries, mem search. Worth setting when the main model is expensive; skip it when the main model is already cheap.",
  },
  {
    key: "SHELLM_SUMMARY_MODEL",
    label: "summary model",
    tip: "Run-summary override; beats the fast model for summaries specifically. Rarely needed — set the fast model first.",
  },
  {
    key: "MONOLITH_REPLY_MODEL",
    label: "monolith reply model",
    tip: "The monolith thinker's fast chat-reply path. Defaults to the thinker model; point it at a fast model to cut reply latency in chat.",
  },
];

/* Curated common choices — edit freely; any model can still be typed via
 * Custom. Provider is inferred from the name (see design/model-resolution.md). */
const MODEL_OPTIONS: { group: string; models: string[] }[] = [
  {
    group: "Anthropic (direct, needs ANTHROPIC_API_KEY)",
    models: ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"],
  },
  {
    group: "OpenRouter (needs OPENROUTER_API_KEY)",
    models: [
      "openai/gpt-oss-120b",
      "openai/gpt-oss-20b",
      "anthropic/claude-sonnet-4.6",
      "anthropic/claude-haiku-4.5",
      "google/gemini-2.5-flash",
      "moonshotai/kimi-k2",
    ],
  },
];

const CUSTOM = "__custom__";
const ALL_OPTION_VALUES = new Set(
  MODEL_OPTIONS.flatMap((g) => g.models)
);
const OPENROUTER_DATALIST_ID = "openrouter-model-ids";

function ModelRow({
  identityId,
  knob,
  env,
  catalog,
}: {
  identityId: string;
  knob: (typeof MODEL_KNOBS)[number];
  env: IdentityEnv;
  catalog?: OpenRouterModels;
}) {
  const controlsEnabled = useControlsEnabled();
  const queryClient = useQueryClient();
  const invalidate = () =>
    queryClient.invalidateQueries({ queryKey: ["env", identityId] });

  const identityEntry = env.env.find((e) => e.key === knob.key);
  const inheritedEntry = env.inherited.find((e) => e.key === knob.key);
  const effective = identityEntry?.value ?? inheritedEntry?.value ?? "";
  const source = identityEntry
    ? "identity"
    : inheritedEntry
      ? "inherited"
      : "default";

  const [customDraft, setCustomDraft] = useState<string | null>(null);

  // Only meaningful when the catalog is the key-filtered list: a configured
  // OpenRouter-style model (vendor/name) missing from it won't work.
  const unavailable =
    catalog?.source === "key" &&
    effective.includes("/") &&
    !catalog.models.some((m) => m.id === effective);

  const save = useMutation({
    mutationFn: (value: string) => putEnvVar(identityId, knob.key, value),
    onSuccess: (entry) => {
      toast.success(`Saved ${entry.key} — restart thinkers to apply`);
      setCustomDraft(null);
      invalidate();
    },
    onError: (error: Error) => toast.error(error.message),
  });
  const remove = useMutation({
    mutationFn: () => deleteEnvVar(identityId, knob.key),
    onSuccess: () => {
      toast.success(`Cleared ${knob.key}`);
      invalidate();
    },
    onError: (error: Error) => toast.error(error.message),
  });

  return (
    <div className="flex flex-wrap items-center gap-2 border-b px-3 py-2 last:border-b-0">
      <div className="flex w-56 items-center gap-1.5">
        <span className="font-mono text-xs font-medium">{knob.key}</span>
        <Tooltip>
          <TooltipTrigger asChild>
            <Info className="size-3 shrink-0 cursor-help text-muted-foreground" />
          </TooltipTrigger>
          <TooltipContent className="max-w-xs text-xs">{knob.tip}</TooltipContent>
        </Tooltip>
      </div>

      <div className="flex min-w-0 flex-1 items-center gap-2">
        {customDraft !== null ? (
          <form
            className="flex flex-1 items-center gap-2"
            onSubmit={(event) => {
              event.preventDefault();
              if (customDraft.trim()) save.mutate(customDraft.trim());
            }}
          >
            <Input
              autoFocus
              value={customDraft}
              onChange={(event) => setCustomDraft(event.target.value)}
              placeholder={
                catalog?.source === "key"
                  ? `type to search ${catalog.count} models on this key…`
                  : "vendor/model or claude-…"
              }
              list={OPENROUTER_DATALIST_ID}
              className="h-8 flex-1 font-mono text-xs"
            />
            <Button type="submit" size="sm" disabled={save.isPending}>
              Save
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => setCustomDraft(null)}
            >
              Cancel
            </Button>
          </form>
        ) : (
          <>
            <Select
              /* key forces a remount when the value changes underneath us —
               * Radix keeps its last selection when `value` returns to
               * undefined, which would show a stale model after Clear. */
              key={effective}
              disabled={!controlsEnabled || save.isPending}
              value={ALL_OPTION_VALUES.has(effective) ? effective : undefined}
              onValueChange={(value) => {
                if (value === CUSTOM) setCustomDraft(effective);
                else if (value !== effective) save.mutate(value);
              }}
            >
              <SelectTrigger size="sm" className="min-w-56 font-mono text-xs">
                <SelectValue
                  placeholder={
                    effective || "(unset — built-in default)"
                  }
                />
              </SelectTrigger>
              <SelectContent>
                {MODEL_OPTIONS.map((group) => (
                  <SelectGroup key={group.group}>
                    <SelectLabel className="text-[11px]">{group.group}</SelectLabel>
                    {group.models
                      // With a key-filtered catalog, drop curated OpenRouter
                      // entries (vendor/name) the key can't use. Direct
                      // (claude-*) entries are not OpenRouter's to veto.
                      .filter(
                        (model) =>
                          catalog?.source !== "key" ||
                          !model.includes("/") ||
                          catalog.models.some((m) => m.id === model)
                      )
                      .map((model) => (
                        <SelectItem
                          key={model}
                          value={model}
                          className="font-mono text-xs"
                        >
                          {model}
                        </SelectItem>
                      ))}
                  </SelectGroup>
                ))}
                <SelectItem value={CUSTOM} className="text-xs">
                  Custom…
                </SelectItem>
              </SelectContent>
            </Select>
            <Badge variant="outline" className="text-[10px]">
              {source}
            </Badge>
            {unavailable && (
              <Tooltip>
                <TooltipTrigger asChild>
                  <Badge variant="destructive" className="text-[10px]">
                    not on this key
                  </Badge>
                </TooltipTrigger>
                <TooltipContent className="max-w-xs text-xs">
                  OpenRouter's model list for this key does not include{" "}
                  {effective} — check the model id, or your org's OpenRouter
                  model/provider settings.
                </TooltipContent>
              </Tooltip>
            )}
            {controlsEnabled && identityEntry && (
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    disabled={remove.isPending}
                    onClick={() => remove.mutate()}
                  >
                    <RotateCcw className="size-3" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent className="text-xs">
                  Clear the identity override — fall back to{" "}
                  {inheritedEntry
                    ? `inherited (${inheritedEntry.value})`
                    : "the built-in default"}
                </TooltipContent>
              </Tooltip>
            )}
          </>
        )}
      </div>
    </div>
  );
}

/** Quick model setup: the commonly-overridden model knobs with curated
 * choices, so a fresh identity gets a sane config without hand-typing env
 * vars. Writes the same identity .env as the table below. */
/* The label must LEAD with the id: Firefox's datalist popup shows only the
 * label (never the value), so a details-only label renders as anonymous
 * price rows there. Chrome shows value + label side by side and repeats the
 * id — cosmetic, and the price it pays for working in both. */
function modelOptionLabel(model: OpenRouterModels["models"][number]): string {
  const parts: string[] = [model.id];
  if (model.prompt_usd_per_m != null && model.completion_usd_per_m != null)
    parts.push(
      `$${model.prompt_usd_per_m}/M in · $${model.completion_usd_per_m}/M out`
    );
  if (model.context_length)
    parts.push(`${Math.round(model.context_length / 1000)}k ctx`);
  return parts.join(" — ");
}

export function ModelConfigSection({
  identityId,
  env,
}: {
  identityId: string;
  env: IdentityEnv;
}) {
  const { data: catalog } = useQuery({
    queryKey: ["openrouter-models"],
    queryFn: fetchOpenRouterModels,
    staleTime: 10 * 60 * 1000,
    retry: 1,
  });

  const datalist = useMemo(
    () =>
      (catalog?.models ?? []).map((model) => (
        <option
          key={model.id}
          value={model.id}
          label={modelOptionLabel(model)}
        />
      )),
    [catalog]
  );

  const catalogNote =
    catalog?.source === "key"
      ? `${catalog.count} OpenRouter models available to this key.`
      : catalog?.source === "public"
        ? `${catalog.count} models in the public OpenRouter catalog (no key configured — availability not checked).`
        : catalog?.error
          ? "OpenRouter catalog unavailable — Custom entry still works."
          : null;

  return (
    <section className="mb-8">
      <div className="mb-2 flex items-baseline gap-3">
        <h2 className="font-mono text-xs font-medium uppercase tracking-wider text-muted-foreground">
          models
        </h2>
        <span className="text-[11px] text-muted-foreground">
          Common model knobs (written to identity .env). Running thinkers keep
          the environment they started with — restart thinkers after changing
          these.{catalogNote ? ` ${catalogNote}` : ""}
        </span>
      </div>
      <div className="rounded-lg border">
        {MODEL_KNOBS.map((knob) => (
          <ModelRow
            key={knob.key}
            identityId={identityId}
            knob={knob}
            env={env}
            catalog={catalog}
          />
        ))}
      </div>
      <datalist id={OPENROUTER_DATALIST_ID}>{datalist}</datalist>
    </section>
  );
}
