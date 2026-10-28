// The navbar's llm chip when the last call was refused by an identity's own
// spend limit (bin/llm's marker, kind "budget"): loud like an empty wallet,
// and it names the identity and links to its usage page.

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Navbar } from "~/components/navbar";
import type { LlmHealth } from "~/lib/types";

vi.mock("~/lib/api", async (importOriginal) => {
  const mod = await importOriginal<typeof import("~/lib/api")>();
  return {
    ...mod,
    fetchConfig: vi.fn(async () => ({ controls_enabled: false, git_commit: null })),
    fetchLlmHealth: vi.fn(
      async (): Promise<LlmHealth> => ({
        status: "ok",
        failures_15m: 0,
        failures_1h: 0,
        cadence_slow: false,
        checked_at: "2026-10-27T12:00:00Z",
        identities: [
          {
            id: ".identities~ada",
            name: "ada",
            live: true,
            failures_1h: 0,
            failures_15m: 0,
            last_failure: null,
            cadence: null,
          },
        ],
        last_call: {
          ok: false,
          ts: "2026-10-27T11:59:00Z",
          provider: "openrouter",
          model: "openai/gpt-x",
          identity: "ada",
          kind: "budget",
          http_code: null,
          message: "spend limit reached: $25.01 of $25 in total; no request sent",
        },
      })
    ),
  };
});

afterEach(cleanup);

describe("llm chip, spend limit", () => {
  it("names the limit, the identity, and links to its usage", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(
      <MemoryRouter>
        <QueryClientProvider client={client}>
          <Navbar />
        </QueryClientProvider>
      </MemoryRouter>
    );
    const chip = await screen.findByText("llm: spend limit reached");
    fireEvent.click(chip);
    expect(screen.getByText(/Last call failed: spend limit reached/)).toBeTruthy();
    expect(screen.getByText(/\$25\.01 of \$25 in total/)).toBeTruthy();
    expect(screen.getByText(/the provider is fine/)).toBeTruthy();
    expect(screen.getByRole("link", { name: "See what it spent" }).getAttribute("href")).toBe(
      "/i/.identities~ada/usage"
    );
  });
});
