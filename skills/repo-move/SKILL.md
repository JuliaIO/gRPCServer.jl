---
name: repo-move
description: Re-point the gRPCServer.jl repository at a new GitHub owner/branch (used for csvance -> JuliaIO). Parameterized inventory-driven migration with a dry-run mode. Use when the repository is being transferred to a new GitHub org/owner or the default branch changes.
---

# repo-move: parameterized repository migration

Moves every repo-scoped URL and branch token in this repository from one
GitHub owner/branch to another. Originally authored for the
`s-celles` -> `csvance` move (interim testing home); the next expected run is
`csvance` -> `JuliaIO` (final home, via GitHub repo **transfer**).

## Parameters

| Parameter | Last used | Next expected |
|---|---|---|
| `OLD_OWNER` | `s-celles` | `csvance` |
| `NEW_OWNER` | `csvance` | `JuliaIO` |
| `OLD_BRANCH` | `master` | `main` |
| `NEW_BRANCH` | `main` | `main` (skip the rename block when `OLD_BRANCH == NEW_BRANCH`) |
| `DRY_RUN` | — | `true` = apply edits locally, verify, DO NOT commit/push |

Docs host derives as `https://$(NEW_OWNER).github.io/gRPCServer.jl`.

## Step 1 — Inventory (never skip)

Run these greps and classify EVERY hit before editing:

```
git grep -n "$(OLD_OWNER)/gRPCServer.jl"
git grep -n "$(OLD_OWNER).github.io/gRPCServer.jl"
git grep -n "$(OLD_OWNER)"            # catch-all, manual review
git grep -n "develop\|$(OLD_BRANCH)" -- .github docs README.md docs/make.jl
```

### Rewrite rule

Rewrite ONLY `{OLD_OWNER}/gRPCServer.jl`, `{OLD_OWNER}.github.io/gRPCServer.jl`,
badge/codecov/plugin slugs, workflow branch triggers, and `docs/make.jl`
(owner, canonical, deploydocs repo, devbranch).

### KEEP rule (a naive global replace corrupts these)

- `{OLD_OWNER}/{other repo}` links — PureHTTP2.jl, Nghttp2Wrapper.jl are
  **different repositories**; they keep their own owners.
- `{OLD_OWNER}` **profile** links (e.g. CONTRIBUTORS.md user page).
- Heritage prose: historical CHANGELOG entries, ROADMAP history narratives,
  design-doc references to removed code.
- The Zenodo DOI badge stays dropped until the FINAL home is settled
  (re-issue a DOI after the JuliaIO transfer; GitHub transfer preserves repo
  ID, so one clean DOI then).

## Step 2 — Branch rename (only if OLD_BRANCH != NEW_BRANCH)

```
git branch -m $(OLD_BRANCH) $(NEW_BRANCH)
git push -u origin $(NEW_BRANCH)        # owner action, not in DRY_RUN
# GitHub: Settings -> Branches -> default branch = NEW_BRANCH; then
git push origin --delete $(OLD_BRANCH)  # owner action
```

## Step 3 — File edits (from the verified `s-celles -> csvance` diff)

The csvance move touched exactly: `.github/workflows/CI.yml` +
`Documentation.yml` (branch triggers), `docs/make.jl` (4 values),
`README.md` (badges + install URL + docs link), `.claude-plugin/plugin.json` +
`marketplace.json`, `CONTRIBUTING.md:21,47`, `CONTRIBUTORS.md:3`,
`docs/src/index.md` + `quickstart.md` (install URL), `CHANGELOG.md` footer
links. Re-derive the list from Step 1 for the current tree — do not assume it
is still exactly this set.

## Step 4 — Owner-side checklist (perform nothing as the agent)

1. **Transfer, not new repo** (org move): Settings -> Transfer ownership.
   Transfers preserve issues/PRs/stars and redirect old URLs.
2. GitHub Pages does NOT redirect: new canonical is
   `$(NEW_OWNER).github.io/gRPCServer.jl`; old links keep pointing at the old
   host. Update external references where possible.
3. Secrets/webhooks/deploy keys survive transfer — re-verify
   `DOCUMENTER_KEY`, `CODECOV_TOKEN`, `GITHUB_TOKEN` permissions.
4. Re-install the Registrator GitHub App **for the org** (org-scoped).
5. Re-point CODEOWNERS to org teams if present.
6. Codecov: re-claim the new repo slug so uploads and the badge resolve.
7. Branch protection on `main` if desired.

## Step 5 — Registry guard (if a General registration exists)

If the package is already registered, a transferred repo URL requires a
maintainer-assisted PR against `JuliaRegistries/General` `Package.toml`
BEFORE any further version registration — JuliaHub/Registrator refuses new
versions from a changed URL until that PR lands. (For gRPCServer this is
moot while registration waits for the final home; keep this guard anyway.)

## Step 6 — Verification

```
git grep -n "$(OLD_OWNER)/gRPCServer.jl"        # must be 0
git grep -n "$(OLD_OWNER).github.io/gRPCServer.jl"  # must be 0
git grep -n "develop" -- .github docs README.md     # only historical prose
```

`DRY_RUN=true`: stop after `git diff --stat` + the greps; report; do not
commit. Final (owner-confirmed): commit, push, then owner runs Step 2's
remote half + Step 4, then verify CI + docs deploy on the new home.
