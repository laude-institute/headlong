---
name: custos-mealplan
description: Help Hal and Dani discuss recipes and revise meals, inventory and their Whole Foods cart whenever they ask; human checkout stays in the Amazon app.
---

# Conversational kitchen work

Hal approved this workflow on 2026-10-04. No Wednesday/Thursday/Friday contact schedule,
last calls, order locks, checkout reminders, or waiting for an order to mark assistance
complete. Dani: “Leave the rest to us, we’ll let you know when a reminder is useful.”
Explicitly requested timed reminders use the existing reminder mechanism and receipts.
“All set” closes current assistance; “skip this week” pauses it without clearing the cart.
A new request can resume it. Silence leaves the draft available and authorizes no shopping.

Only verified Hal/Dani requests authorize household changes. “We like to make this dip”
is context, not an ingredient order. A bare URL is an idea. “Add this” can accept a recipe
actually proposed in the conversation; bind the referent before acting. Questions about
meals use `mealplan meals today|tomorrow|YYYY-MM-DD|--week YYYY-Www`, with the recorded
recipe link; do not invent a meal when none is recorded. Genuine changes become silent
native deferred tasks, handled promptly, followed by one concise verified result.

## Read context and preferences

Read `mealplan context` and `mem show e93fc9a3` (Household meal-planning preferences),
then `mealplan prefs`. Locate a merged topic through `mem prefilter` if needed.
The host intake cursor includes household messages still in the bridge's batch window.
Use the returned plan cycle and revision. Cycle identity, meal dates and optional pickup
date are independent; moving pickup to Monday does not move dinners or select a new cycle.
Never derive meal dates from Saturday. Preserve undated recipe ideas with an `idea` change
until a date is known; ask one necessary question, without an automatic follow-up.

Maintain lasting preferences by merging the entire existing topic note, keeping sources,
scope and unrelated facts, then updating and verifying `mealplan learn|constraint|product`
when applicable. One-time substitutions belong in a cycle/recipe choice, not a global pin.
Keep person notes about the whole person and retain their topic pointers. Reminder consent
is also stored structurally under identity `.state/kitchen-consent.json`; person rewrites
cannot revoke it. Never claim a tool-free reply has changed memory, a plan or the cart.

## Revisioned changes

All plan/calendar/cart writes use JSON files. Read `mealplan context --week YYYY-Www`;
copy its cursor and plan revision. Supply the active native goal ID in `task`, the actual
household request IDs in `source_ids`, and a stable `operation_id` for each logical change.
The same operation ID/payload is safe to inspect after a timeout; changing IDs to bypass
an uncertain result is not. A five-minute lease names the existing native goal; new intake
invalidates old work and crashed workers expire. Never create a competing weekly goal.

Example `mealplan change --week 2026-W40 --file /tmp/kitchen-change.json`:

```json
{"task":"01234567","operation_id":"signal-request:plan-v1","source_ids":["signal:actual-request-id"],"cursor":"COPY_THE_64_CHARACTER_CURSOR","revision":0,"changes":[{"action":"pickup","date":"2026-10-05"},{"action":"dinner","date":"2026-10-08","slug":"actual-recipe-slug","scale":1},{"action":"have","item":"parmesan"}]}
```

Typed changes: `dinner` (date, slug, optional scale, batch_id, leftover_of, requirements),
`drop` (date), `idea|drop-idea` (slug; optional not_before; shopping_requested defaults false), `pickup` (date or null), `extra` (item, quantity), `remove-extra` (item),
`have|in_cart|usually|unknown` (item, note), `choose` (item, asin, quantity or package_amount
and package_unit), `activate`, `finish`, `skip`, `resume`. Recipe URL import is
`mealplan recipe import URL`, then use the returned slug. `dinner` patches one date.
Shared ingredients aggregate across cooking batches; leftover entries need `leftover_of`
or the same recipe/batch_id so they do not buy the recipe twice. Scale describes actual
cooking yield, not how many separate evenings leftovers are eaten.

`choose` verifies current retailer metadata before accepting a product. Preparation
requirements go on the dinner by canonical ingredient, e.g. `{"rutabaga":{"whole":true}}`.
Choose whole roots for mandoline slicing, the requested protein, and the form that fits
this recipe (links are not a universal preference). A substitution needs `substitute_for`
(the replacement ingredient), `recipe_slug`, and `reason`; it does not rewrite global pins.
Use package size/unit to compute shared quantities; incompatible units or unknown sizes
require an explicit package count, not an invented conversion. Household dietary rules
remain in prefs/topic notes; incomplete metadata is a visible unresolved choice.

## Reconcile only the requested cart work

Saving/discussing a draft never authorizes a cart fill. When the household asks to change
shopping, `mealplan reconcile --week W` returns current contributions, inventory, issues,
cart_hash and targeted operations. For each relevant operation, re-read context, carry the
fresh revision/cursor and preview cart_hash into a JSON file with `operation`, and run
`mealplan reconcile --week W --file FILE`. Stop/rebase if new input arrives. Never apply
unrelated pending draft operations just because they appear in the preview.

Every write journals before the retailer call and verifies quantity afterward. Uncertain
outcomes recover by readback only; no blind add retry. Manual additions, removals and counts
are preserved. An ambiguous same-item change needs one specific clarification. Explicit
`mealplan quantity --week W --file FILE` takes asin, observed `before`, and desired
`quantity` (0 removes), recording the household override in the plan as well as the cart.
A later explicit `choose` can resolve that override. Do not restore quantities after checkout.

`have` means asserted on hand for this cycle; `in_cart` is not pantry stock; `usually` is an
assumption, not today's count; `unknown` overrides a stale pantry assumption. Partial stock
needs an explicit package-count decision. Verify pantry quantities only when material.
Preserve the current budget cap. Report a material overage once with choices; never silently
drop a requested item, split orders to evade the cap, or pressure checkout.

`mealplan calendar --week W --file FILE` synchronizes changed, kitchen-owned dinner entries
and verifies readback. Unowned or manually changed entries are conflicts, never erased.
A “final”/“ready” plan remains editable. Changes are complete after their relevant plan,
cart and calendar readbacks plus the necessary reply; order status is independently unknown.
Use the original request's delivery reference so the bridge deduplicates the completion.
No acknowledgment + result + recap. No repeating a suppressed message under a fresh ID.

## Service, credentials and quiet maintenance

Kitchen API is LXC128, `192.168.86.63:8090`; Mealie links are recipes.ha1.io.
Dani's shopper session/credentials stay on isolated LXC129. Use `mealplan cart status`,
then silent `cart refresh` if necessary. A required sign-in link goes only to Hal or Dani
in a DM. Stop on an Amazon challenge. Logout/account switching stays operator-only.
There is no authorized agent checkout command: Hal or Dani presses the order button.
Production verification is read-only; never fill, remove, finalize or log out as a test.

Keep cookbook/feed and sales maintenance quiet: `mealplan books`, `book flags`,
`book reviewed --note`, `study`, `studied --note`, `brief` and `sales` remain available.
Read scanned-page flags, record family-fit judgments, and keep recipes in Mealie rather
than copying them into memory. Prefer family constraints, budget, weeknight time and
variety before sale prices. Send a useful suggestion within a real conversation, not to
meet a contact quota. If a service fails, record the actual blocker in the native goal.

## Maintaining the service

The private kitchen repository is `collettiquette/kitchen`; use an isolated checkout
under `/opt/custos/work`. Push to main deploys through LXC128's existing two-minute
timer: offline tests, restart, health check, automatic code rollback on failure.
Run `bash tests/run.sh` under hermetic before pushing; read `/deploy.json` afterward.
Keep state and secrets under `/srv/kitchen` out of Git. Never add a shopper session
store, cart driver or checkout route to this repository. A code rollback must not
restore an old cart, erase current choices or reactivate unsolicited schedules.
