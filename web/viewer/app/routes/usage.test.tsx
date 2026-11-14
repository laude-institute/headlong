// The usage page's spend pieces: the limit card in each state llm --spend
// can report, and the cost tiles, chart and column, which show only once the
// ledger has a cost.

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";

import UsagePage from "~/routes/usage";
import type { SpendStatus, Usage, UsageDay } from "~/lib/types";

let spend: SpendStatus = { ok: true, spent: 0, limit: null, remaining: null, window: "total", since: null };
let priced = 3;

function day(cost_llm: number, cost_opencode: number): UsageDay {
  return {
    rows: 1, in_msg: 0, out_msg: 0, runs: 1, reasoning: 1, calls: 3, in: 100, out: 10, think: 0,
    cost_llm, cost_opencode, source: "ledger",
  };
}

vi.mock("~/lib/api", async (importOriginal) => {
  const mod = await importOriginal<typeof import("~/lib/api")>();
  return {
    ...mod,
    fetchConfig: vi.fn(async () => ({ controls_enabled: false })),
    fetchIdentityStatus: vi.fn(async () => ({ live: false })),
    fetchActivity: vi.fn(async () => ({ state: "idle", queued_messages: [], busy_thinkers: [] })),
    fetchSpend: vi.fn(async () => spend),
    fetchUsage: vi.fn(
      async (): Promise<Usage> => ({
        identity: { id: "ada", name: "ada" },
        available: true,
        refreshing: false,
        pending_bytes: 0,
        generated: new Date().toISOString(),
        rows: 2,
        skipped: 0,
        ledger: { rows: 3, skipped: 0, since: "2026-10-01", calls: 3, priced },
        daily: [
          ["2026-10-01", day(0.25, 0)],
          ["2026-10-02", day(0.25, 0.25)],
        ],
        by_model: { "openai/gpt-x": { calls: 3, in: 200, out: 20, think: 0, cost: 0.75 } },
        totals: {
          in: 200, out: 20, think: 0, calls: 6, in_msg: 0, out_msg: 0, runs: 2,
          cost_llm: 0.5, cost_opencode: 0.25,
        },
      })
    ),
  };
});

function renderUsage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <MemoryRouter initialEntries={["/i/ada/usage"]}>
      <QueryClientProvider client={client}>
        <Routes>
          <Route path="/i/:identityId/usage" element={<UsagePage />} />
        </Routes>
      </QueryClientProvider>
    </MemoryRouter>
  );
}

afterEach(() => {
  cleanup();
  spend = { ok: true, spent: 0, limit: null, remaining: null, window: "total", since: null };
  priced = 3;
});

describe("spend limit card", () => {
  it("says the limit is reached, with the numbers and how to continue", async () => {
    spend = { ok: true, spent: 25.013, limit: 25, remaining: 0, window: "total", since: null };
    renderUsage();
    expect(await screen.findByText("Spend limit reached")).toBeTruthy();
    expect(screen.getByText("$25.01 of $25.00 in total")).toBeTruthy();
    expect(screen.getByText(/No model calls are sent for this identity until LLM_SPEND_LIMIT_USD is raised/)).toBeTruthy();
    expect(screen.getByText(/It can overshoot slightly/)).toBeTruthy();
    expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("25");
  });

  it("shows what is left in a monthly window", async () => {
    spend = { ok: true, spent: 5, limit: 25, remaining: 20, window: "month", since: "2026-10-01T00:00:00Z" };
    renderUsage();
    expect(await screen.findByText("Spend limit")).toBeTruthy();
    expect(screen.getByText("$5.00 of $25.00 this month (UTC)")).toBeTruthy();
    expect(screen.getByText("$20.00 left")).toBeTruthy();
  });

  it("says when llm rejects the settings", async () => {
    spend = { ok: false, error: "llm: error: LLM_SPEND_WINDOW must be total, day or month (got 'week')" };
    renderUsage();
    expect(await screen.findByText("Spend limit settings rejected")).toBeTruthy();
    expect(screen.getByText(/got 'week'/)).toBeTruthy();
  });

  it("is absent when no limit is set", async () => {
    renderUsage();
    await screen.findByText("Cost per day");
    expect(screen.queryByText(/^Spend limit/)).toBeNull();
  });
});

describe("cost", () => {
  it("shows tiles and a per-model column once calls carry a cost", async () => {
    renderUsage();
    expect(await screen.findByText("cost, all time")).toBeTruthy();
    expect(screen.getAllByText("$0.75").length).toBeGreaterThanOrEqual(2); // tile + model row
    expect(screen.getByText("OpenCode delegations")).toBeTruthy();
    expect(screen.queryByText(/carry no cost/)).toBeNull();
  });

  it("says how many calls it misses", async () => {
    priced = 1;
    renderUsage();
    expect(await screen.findByText(/2 of 3 ledger calls carry no cost/)).toBeTruthy();
  });

  it("explains an empty chart and hides the tiles when nothing has a cost", async () => {
    priced = 0;
    renderUsage();
    expect(await screen.findByText(/No call has a cost yet/)).toBeTruthy();
    expect(screen.queryByText("cost, all time")).toBeNull();
  });
});
