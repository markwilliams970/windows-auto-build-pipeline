# Engineering Approach: Research-First, Evidence-Gated Development

A reusable discipline for projects that involve genuine unsolved-problem engineering — not routine
CRUD/feature work, but systems where the right mechanism isn't known in advance and has to be found,
tested, and proven. Adapt the specifics; keep the shape.

Copy this into a new project's own instructions file (e.g. `CLAUDE.md`, `AGENTS.md`) and edit the
placeholders, or keep it as a standing reference and cite it. It's deliberately written as
principles + concrete practices, not a checklist to rubber-stamp — the value is in actually
following the reasoning, not in ticking boxes.

---

## 1. Research before you build, and research before you troubleshoot

Two distinct habits, often conflated:

- **Symptom-level research**: before spending real time diagnosing something that looks broken,
  search for the literal, exact symptom (error text, log line, observed behavior) verbatim.
  Someone else has often hit it first.
- **Capability-level research** (bigger, more valuable, easier to skip): before building *any* new
  mechanism — even a small one — search for whether an existing, reasonably-maintained tool already
  does the whole job, or a documented recipe already exists from a primary source (vendor docs, or a
  mature open-source project solving the same underlying problem in a different context). This is a
  search for *solutions*, not just *known bugs*.

**How to search well** (a specific technique, not just "look it up"):

- Multiple angles per problem, not one query: the literal symptom, the mechanism framed as
  "from X without Y" (when trying to avoid a heavyweight dependency), and a code-host-native search
  (repo/topic search) for tools that already wrap the primitive you're about to build.
- **Verify the primary source; don't trust a search summary.** A tool's README, real commit history,
  and issue tracker are ground truth. An AI-generated search summary is a pointer to go check that
  ground truth, not a citation in its own right — it can be stale or simply wrong.
- Prefer sources that show their work (a real walkthrough with actual commands run, a repo with
  visible recent activity) over sources that only assert a conclusion.
- A negative result is still a result: if a genuine multi-angle search turns up nothing, that's a
  legitimate signal to proceed to original engineering — not a reason to search forever. This is a
  mandate to search *properly*, not to search *infinitely*.

## 2. Deciding what to build vs. adopt vs. wrap

Not every finding is a clean "use this instead." Be deliberate:

- **An existing tool solves the whole problem**: adopt it directly as a dependency. Don't
  reimplement it "to keep things simple" — a well-established external tool a subprocess call away
  is *simpler* than an in-house reimplementation of the same logic, even though it looks like "one
  more dependency" on paper.
- **An existing tool solves most of the problem but doesn't fit your shape as-is**: build the thin
  adapter/wrapper, not the underlying mechanism. The wrapper should be glue around something that
  already works, not a parallel reimplementation.
- **No tool exists, but a documented mechanism from a primary, credible source does**: implement
  that documented mechanism directly rather than deriving a novel approach through trial and error.
- **Only build genuinely from scratch when neither of the above holds** — or when an existing option
  was *actually tried and empirically found insufficient* for your specific constraints, not just
  "seemed complicated." Even then, keep and document what was learned from the failed adoption
  attempt rather than discarding it silently.
- Evaluate whether a candidate tool is actually maintained and actually does what it claims, as part
  of adoption — not an afterthought. A single-maintainer project with real recent activity and a
  documented matching use case is worth a cheap empirical test; an abandoned or vague one isn't
  worth the same trust without more scrutiny.

## 3. Work in phases, with explicit gates — don't generate the whole system at once

- Break the work into phases with **stated success criteria**, not just a task list. A phase is
  "done" when its criteria are met and demonstrated, not when the code compiles or looks plausible.
- **Gate later phases on earlier ones actually being confirmed**, especially when a later phase's
  design assumes an earlier mechanism generalizes (across environments, configurations, or targets)
  that hasn't actually been tested across all of them yet. Don't invest in the next layer on the
  assumption the foundation holds everywhere — confirm it first.
- When a phase turns out to have more real unknowns than expected, decompose it into sub-milestones
  *within* that phase rather than quietly redefining what the phase means. Keep the outer numbering
  stable if other documents or a related project cross-reference it.
- Explain the proposed design, identify assumptions, identify risks, and ask questions **before**
  writing substantial implementation code for a non-trivial step — especially when the surrounding
  problem is still genuinely unsolved. Expect real investigation and small experiments before
  writing much code; that's the actual shape of R&D work, not a detour from it.

## 4. Don't trust a single success — set an evidentiary bar and mean it

- Decide, per project, how many independent clean reproductions are needed before calling a
  mechanism "confirmed" (two or three is a reasonable default for anything with real
  environment-sensitivity). A single lucky run is not evidence it generalizes.
- **Distinguish, explicitly and in writing, "implemented" from "verified."** A change that's written
  carefully and reasoned through thoroughly is still not the same claim as a change that's been
  proven by a real, fresh, end-to-end run. Say which one you mean, every time, especially in status
  documents other people (or future you) will read and trust.
- When a fix depends on an inference about *why* something worked (e.g., "this generalizes because
  the underlying mechanism doesn't depend on the specific value that varied last time") — treat that
  inference as a hypothesis to test, not a conclusion to build on, until it's actually been tested
  under the different condition it claims to be robust to.

## 5. Prefer deterministic fixes over probabilistic ones

- When something is unreliable, resist the pull toward timing tweaks, retries, or "usually works"
  heuristics as the first response. Look for the structural cause: an ordering guarantee, an
  explicit identity/priority mechanism, a documented ranking rule — something that makes the outcome
  *certain* given the inputs, not just *likely*.
- A fix that relies on winning a race, guessing a delay, or hoping a nondeterministic process
  resolves favorably is a patch, not a fix. It's acceptable as a stopgap if labeled as one; it's not
  acceptable as the final state of a documented, relied-upon mechanism.
- If you can't find the structural cause, that's a real signal to research more (§1) before
  shipping a heuristic — the deterministic mechanism often already exists and just hasn't been found
  yet.

## 6. Verify before trusting — always, not just when something looks suspicious

- Check things empirically rather than assuming: confirm a URL actually resolves and returns what
  you expect, confirm a file's actual contents rather than assuming a name implies its structure,
  confirm a described mechanism actually behaves as expected by testing it directly rather than
  taking documentation (yours or someone else's) as automatically current.
- This applies to your own project's prior work too. A past finding, once true, can go stale as
  dependencies move — re-verify a load-bearing claim before building further on it if there's reason
  to think time has passed or an environment has changed.

## 7. Bake in robustness from the start, not after the first collision

- For anything that produces named, repeatable output (build artifacts, generated files, provisioned
  resources), design in a uniqueness/idempotency mechanism (a run identifier threaded through every
  derived path, not just the most visible one) from the first version — don't wait to discover the
  collision the hard way.
- Ask, while sketching a new repeatable process: "what happens if this runs twice with the same
  inputs?" Add a cheap existence check that fails loudly rather than silently colliding or
  overwriting, even if a collision seems unlikely — it's cheap insurance, not overengineering.

## 8. Track brittleness as a standing risk category, not a one-time worry

- Explicitly identify which parts of the system are sensitive to a dependency version changing
  (a pinned download, a driver/library version, a third-party tool's own behavior) versus which
  parts are built on long-stable, well-documented primitives. Rank them — most fragile first — so
  attention is spent where drift is actually likely to bite.
- When you catch a real instance of this kind of drift (a cached dependency now resolving to a newer
  version than what's tested, a tool changing behavior across versions), record it as a concrete,
  dated example, not just a hypothetical — it's what justifies the standing concern to future
  readers (including future you) who might otherwise dismiss it as theoretical.

## 9. Document findings as you go — including the failures

- Keep a running engineering log: symptom, diagnosis, root cause, fix — or honestly, "tried, didn't
  work, here's why, shelved." Write this at the time, not only once something fully succeeds.
  Failed approaches are worth exactly as much ink as working ones; they're what stops the next
  person (or future you) from re-attempting something already ruled out.
- Keep **one** canonical, current status document per project. If a second document (a README, a
  status page) exists for a different audience, make sure it doesn't duplicate the same
  phase-by-phase status — duplicated status drifts, and drifted status is worse than no status,
  because it looks authoritative while being wrong.

## 10. Resource hygiene

- Clean up disposable intermediate artifacts once their evidentiary value has been captured (in the
  log, in a screenshot, in a committed finding) — don't let scratch output accumulate indefinitely
  just because deleting it feels risky.
- Always confirm before deleting anything with real size or history behind it, and prefer a
  targeted, explicitly-reviewed list ("these two files, because X") over a broad or wildcard delete.
  The cost of asking is low; the cost of deleting the wrong thing is not always recoverable.

---

## A short, real illustration of the loop (generalized from an actual project)

A newly-added display driver was suspected, then confirmed, to be the cause of a UI component
crashing under a specific virtualized environment — but only diagnosed by connecting directly to the
running system and reading its own logs (not guessing from the outside), which produced an exact
crash signature. That signature was cross-checked against a real, primary-source bug report from the
component vendor confirming it as a known, named limitation — not just a plausible-sounding theory.
The fix was corroborated a second way: an independent, already-working reference system was checked
directly and found to be using a different, newer driver build successfully. That newer build turned
out to already be sitting inside a dependency the project already trusted and used elsewhere — no new
download, no new supply chain. Rather than relying on "install the better one and hope it wins," the
fix was made deterministic by reading both drivers' own declared priority values and confirming, from
the documented ranking rule, that the better driver would always be chosen — removing the need to
force anything. The fix was then written up as a dated, numbered finding (what broke, how it was
diagnosed, the exact fix, and — importantly — explicitly marked as *implemented but not yet
re-verified by a fresh end-to-end run*, since implementing a fix and proving it are different claims).

Every numbered section above shows up in that one story: research before theorizing, verifying
against a primary source, corroborating against independent real-world evidence, preferring a
deterministic mechanism over a probabilistic one, and being honest in writing about what's confirmed
versus what's merely implemented.
