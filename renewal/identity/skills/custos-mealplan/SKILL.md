---
name: custos-mealplan
description: Help Hal and Dani discuss recipes and revise meals, inventory and their Whole Foods cart whenever they ask; human checkout stays in the Amazon app.
---

# Household meal planning

Hal requested this update on 2026-10-10: Wednesday 15:00 America/Denver check-in;
Friday about noon recap after auditing the cart and pantry. These two requested
contacts supersede the October 4 retirement of weekly contacts. No Thursday nudge,
last calls, order locks, checkout reminders, or purchase polling. A later request to
stop check-ins cancels them; “skip this week” suppresses this week's contacts.
Explicitly requested other timed reminders retain their existing mechanism and receipts.
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
this recipe (sausage links are not a universal preference). A substitution needs `substitute_for`
(the replacement ingredient), `recipe_slug`, and `reason`; it does not rewrite global pins.
Use package size/unit to compute shared quantities; incompatible units or unknown sizes
require an explicit package count, not an invented conversion. Household dietary rules
remain in prefs/topic notes; incomplete metadata is a visible unresolved choice.

## Verify the retailer cart

`mealplan cart show` reads the actual retailer cart. `mealplan list preview` and
`mealplan reconcile` without `--file` are read-only shopping previews: quantities
there are planned requirements, not saved groceries. `mealplan change` only saves
plan data, including product choices. Only a verified `reconcile --file` or
`quantity --file` result proves a cart write. Read the retailer cart afterward;
never say ingredients are in the cart based on a plan, preview or product choice.

For a dated household request, pass its explicit `--week`; the active cycle may
still be an earlier week. Use `activate` when the household moves planning cycles.
An import marked `shopping_ready:false` needs ingredient/instruction repair before
shopping. Do not buy scraper placeholders or add duplicate workaround extras.

## Reconcile only the requested cart work

Saving/discussing a draft never authorizes a cart fill. Explicitly choosing a recipe
or approving a proposal authorizes its ingredients; every subsequent agreed addition,
removal, substitution, quantity or pantry correction must update the relevant cart
contributions promptly. Do not wait until Friday or require the family to ask separately
for the cart edit. `mealplan reconcile --week W` returns contributions, inventory, issues,
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

`have` means dated on hand for this cycle; also record household evidence with `mealplan
pantry --file FILE` so it carries to later cycles with expiry. `in_cart` is not pantry
stock; `usually` is an assumption, not today's count; `unknown` overrides stale evidence.
Partial stock needs a package-count decision. Verify quantities when material.
Preserve the current budget cap. Report a material overage once with choices; never silently
drop a requested item, split orders to evade the cap, or pressure checkout.

`mealplan calendar --week W --file FILE` synchronizes changed, kitchen-owned dinner entries
and verifies readback. Unowned or manually changed entries are conflicts, never erased.
A “final”/“ready” plan remains editable. Changes are complete after their relevant plan,
cart and calendar readbacks plus the necessary reply; order status is independently unknown.
Use the original request's delivery reference so the bridge deduplicates the completion.
No acknowledgment + result + recap. No repeating a suppressed message under a fresh ID.

## Wednesday check-in

Read `mealplan checkin` for the upcoming Monday–Sunday frame (five dinners, two servings
unless current preferences/conversation say otherwise), then `mealplan context --week W`.
The check-in returns its cycle ID: use it explicitly throughout; the old active cycle
can be historical. Pickup date is independent. Preserve household meal dates, nights
out, takeout and leftovers; represent non-recipe nights with `accounted` (date, note).
Read the calendar and relevant conversation before treating a date as open. Do not
move a requested date merely to fit the default frame. Record a changed frame explicitly.
`related_recipes` surfaces meals saved under older pickup-week IDs and outstanding
undated recipes. Read their source cycles and conversation; keep recipes intended for
this frame visible and audit their source cycles on Friday. Do not duplicate their
cart contributions in a new cycle or revive an old week's abandoned idea. If the
intended week is unresolved, show its name/link and ask about the date in this check-in.
After establishing the current frame, use `activate` for the chosen active cycle;
every between-check-in request starts from fresh context and its actual intended dates.

First show every recipe the family has sent for this cycle, with its real name and
canonical recipe link. An undated idea is retained and shown; only “use/add this” or
an actual approval authorizes shopping. Import URLs and retain them as `idea` or
`propose` rather than inventing a recipe. Then suggest enough recipes to cover the
remaining planned dinners. If none were sent, suggest all five. Count existing
requested undated recipes toward the target and propose dates without inventing
agreement. Avoid a recent repeat; use tastes, constraints, variety and prep time first.

Save Custos suggestions only with `propose` (id, slug, date, source="custos"). They
are separate from accepted dinners and never contribute to the cart or calendar.
They carry no purchase authority even if a product has already been selected.
An approval uses `approve` (id, optional date, exact household evidence quote) with
the real approving source_ids. Accept only the named subset; ambiguous “yes” requires
binding the conversation. `reject-proposal` removes an unwanted suggestion. Then
reconcile and verify the approved recipes immediately. Later `dinner`/`drop` changes
are for actual household choices, never a back door for unapproved suggestions.

Send one check-in to Collette Haus with `custos-actions signal-send --goal GOAL < FILE`.
Stable request_id: `kitchen-wednesday:YYYY-MM-DD` using that Wednesday's Denver date.
No reply_to for a scheduled contact. The host verifies the schedule, destination and
current consent. Inspect `custos-actions status ID` / `delivery-status action:ID`;
queued is not delivered. Reuse the exact payload/ID after uncertainty; no alternate ID.
The permitted delivery window is 15:00–21:00; do not send a stale check-in later.

## Pantry evidence and one initial confirmation

`mealplan pantry` returns revisioned evidence, expiry, quantities, confidence and the
one-time bootstrap status. It replaces indefinite prefs.pantry assumptions. Do not
write stock into `learn pantry`; that old list supplies confirmation candidates only.
Use context clues and conversation to maintain this store during actual household
work: an explicit “we have onions” is an observation; mentioning a recipe or seeing
something in the cart is not proof it is at home. “Out of cumin” overrides the spice
baseline immediately. A picked-up/delivered purchase is only evidence of receipt if
the household or a verified receipt actually confirms it, never from cart presence.

Write `mealplan pantry --week W --file FILE`, with task, cursor, source_ids,
operation_id, the PANTRY revision (not plan revision), and changes. `observe` takes
item, state (have/low/out/unknown/usually), basis (explicit/inferred), observed_at,
evidence (quote or inference rationale), optional category, quantity/unit, sufficient
and ttl_days. Preserve the original assertion date when migrating/replaying notes.
Defaults: fresh food 7 days, dried spices 180, condiments 60, dry goods/frozen 30.
These are stock-confidence windows, not food-safety expiration. Never re-date an old
fact just because you read it. Inferences last at most 7 days, remain uncertain, and
cannot overwrite explicit evidence. Food form matters: fresh thyme is not dried thyme.

Before the first confirmation, review recent household conversation and current
pantry evidence; separate likely regular spices/condiments from fresh unknowns. Ask
ONE compact confirmation in Collette Haus, including corrections and anything running
low. Use fixed request_id `kitchen-pantry-bootstrap-20261010`; the host permits it
only once through the existing delivery spool. After a submitted receipt, record
`bootstrap-asked` with delivery_ref. If already asked, do not ask again or follow up
on silence. On the response, update individual facts and `bootstrap-confirmed` with
the confirmation quote. A confirmed general spice cupboard uses `spice-baseline`
(stocked boolean, observed_at, evidence), valid 180 days; it is a usual-supply
assumption with named exceptions, not a guarantee for every obscure spice or bulk use.
The user has said most recipe spices are usually stocked; the initial question should
test likely exceptions, not require enumerating the entire cupboard from scratch.

Report meaningful uncertain stock only for ingredients that affect planned meals.
Use quantities across all recipes and account for consumption: `consume` records
actual reported use with quantity/unit and evidence, without extending expiry. Do
not subtract merely because a meal was planned; do not assume a recipe was cooked.
Expired evidence becomes unknown, not a claim of an empty cupboard. Needed-on dates
matter: a fact that expires before cooking is not current coverage. A specialty spice,
large quantity, low stock, or ambiguity needs checking; ordinary confirmed spice
supplies do not require the same weekly question. Keep unrelated personal notes intact.

## Friday audit and noon recap

Start the native Friday task at 11:30 Denver so audits can finish before the 12:00
recap. Read fresh context and `mealplan audit --week W` for the same upcoming cycle
as Wednesday, including accepted undated recipes. Audit is read-only and must read
the actual retailer cart. Reconcile authorized missing groceries using approved
recipe contributions, current pantry evidence and verified product/package counts;
preserve manual household edits and ask about conflicting edits rather than restoring
them blindly. Never shop an unapproved proposal as part of the audit.

Run the audit again after any changes. Inspect every recipe's ingredients, aggregate
shared quantities, and verify cart quantities plus pantry evidence through the meal
date. `spice_baseline` is an assumption to disclose compactly, not counted physical
stock. Validate unusual spices and unusually large amounts yourself. Include all
unresolved items, stale pantry evidence, insufficient/unknown amounts, unavailable
products, approval gaps, and any failed cart access in the recap. Never say everything
is covered when the audit is incomplete. Distinguish missing groceries from a question
about stock, and ask one compact question covering actionable misses. If access fails,
still send the recipe recap with the specific verification failure at noon.

Recap every selected recipe with title and link, days/leftovers when known, remaining
unapproved suggestions clearly labeled, and concise cart/pantry results. Send once
with request_id `kitchen-friday:YYYY-MM-DD`, no reply_to, to Collette Haus at/after noon.
Before noon, park the native task until noon using its existing not-before/wait
mechanism, not a sleeping process. Delivery window 12:00–18:00. A delay or miss is
recorded honestly. Checkout remains Hal/Dani's action and is never required for task
completion. Household replies and subsequent agreed changes trigger cart edits.

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
