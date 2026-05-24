# Git workflow — quick reference

Short, practical Windows / PowerShell git commands for day-to-day use on
this repo. Companion to
[`output_commit_policy.md`](output_commit_policy.md) (what to commit /
ignore) and [`release_checklist.md`](release_checklist.md) (pre-release
pre-flight).

Open a PowerShell terminal in the repo root and you're ready.

## The 30-second loop

```powershell
# 1. See what changed
git status --short

# 2. Stage exactly the files you mean to commit (NOT git add -A; see below)
git add scripts/00_utils.R docs/runbook.md

# 3. Preview what will be committed
git diff --cached --stat

# 4. Commit with a message
git commit -m "Document v4 sidecar contract"

# 5. Push when ready
git push
```

That's the whole loop. Everything below is for when something looks off.

## Inspect

```powershell
# Short summary of working-tree changes
git status --short

# Numeric diff stat of unstaged changes
git diff --stat

# Numeric diff stat of what's currently staged
git diff --cached --stat

# Show staged content for one file (the actual hunks)
git diff --cached scripts/00_utils.R

# Recent commits, one per line
git log --oneline -10

# Which files are currently tracked
git ls-files | Measure-Object   # how many tracked files in total
git ls-files docs/              # which docs files are tracked
```

## Stage

```powershell
# Stage one file
git add docs/runbook.md

# Stage all changes under one directory
git add docs/

# Stage every modification & deletion of a file (but NOT new untracked)
git add -u

# Stage only specific lines in a file (interactive)
git add -p scripts/00_utils.R
```

### Avoid `git add -A` until the working tree is small

`git add -A` stages **everything** untracked, including anything not
caught by `.gitignore`. After a heavy fit run this could try to stage
millions of files / many GB. Until `git status --short` shows a tidy
working tree, prefer naming files / directories explicitly.

A safe variant if you're sure: `git add -u` only stages
modifications & deletions of already-tracked files — it never adds new
untracked files.

### Force-add a normally-ignored file

```powershell
# Override .gitignore for one specific file:
git add -f output_sim_v30/sim_null_lowhet_clean/sim_null_lowhet_clean_robma_summary.csv

# Verify it staged correctly:
git diff --cached --stat
```

## Check whether a large file is staged

```powershell
# Show every staged file with its size impact
git diff --cached --stat

# Hunt for any staged file > N kilobytes (here: > 5 MB):
git diff --cached --name-only | ForEach-Object {
  if (Test-Path $_) {
    $size = (Get-Item $_).Length
    if ($size -gt 5MB) { "{0,8} KB  {1}" -f [int]($size/1KB), $_ }
  }
}

# Quickly check whether a path is currently ignored by .gitignore:
git check-ignore -v simulation/results/empirical_resampling/empirical_resampling_size_curve.csv
# (prints the rule that ignores it; exits 1 silently if NOT ignored)
```

If you ever see a file in `git diff --cached --stat` whose size column
runs into hundreds of MB, **stop** — that file should almost certainly
be unstaged.

## Unstage

```powershell
# Remove ONE file from the stage but keep the working-tree change
git restore --staged simulation/results/cell_behavior/synthetic_cell_size_curve_draws.csv

# Equivalent (older syntax, still works)
git reset HEAD simulation/results/cell_behavior/synthetic_cell_size_curve_draws.csv

# Remove EVERYTHING from the stage (working-tree untouched)
git restore --staged .
```

Neither of these deletes any file on disk — they only un-mark the file
for the next commit.

## Commit message style

A one-liner is fine for routine work; use a body when the change deserves
explanation.

```powershell
# Single-line commit
git commit -m "Update runbook step C to call sim_fit_library() directly"

# Multi-line commit (PowerShell heredoc-equivalent)
git commit -m "Reconcile docs vs disk" -m "Phase B: remove stale references to retired wrapper + orchard module; update v3.0 -> v3.1 sim README links."
```

Don't commit a half-finished or untested change just to make the diff
visible; the commit history is the audit trail.

## Push

```powershell
# Push the current branch to its tracked upstream
git push

# First push of a new branch (sets upstream on the remote)
git push -u origin <branch-name>
```

## Tag a release later

When you're ready to cut a public manuscript-aligned release, use an
annotated tag (annotated tags carry a message; lightweight tags don't):

```powershell
# Create the tag on the latest commit
git tag -a v1.0.0 -m "Manuscript revision 1.0 — frozen for submission"

# Push the tag to GitHub
git push origin v1.0.0

# List all tags
git tag --list

# See the message on a specific tag
git show v1.0.0
```

Suggested versioning convention for this project:

| Tag pattern | Meaning |
|---|---|
| `v0.1.0-pre-public` | Pre-public methods-cleanup snapshot. |
| `v1.0.0` | First public manuscript-aligned release. |
| `v1.0.1` | Bug fix / typo on the v1.0 release. |
| `v1.1.0` | Pipeline improvement that preserves v4 contract. |
| `v2.0.0` | Breaking schema change (sidecar v5, new estimand version). |

## Recover from common mistakes

```powershell
# I committed something I shouldn't have (but haven't pushed yet):
# Undo the LAST commit, keep all the changes staged for re-editing
git reset --soft HEAD~1

# Undo the LAST commit, keep changes UN-staged in the working tree
git reset HEAD~1

# I accidentally `git add`-ed a giant file but haven't committed:
git restore --staged path/to/giant_file.csv

# I want to throw away a local-only edit to a file (DESTRUCTIVE):
git restore path/to/file.R                    # restores from staged or HEAD
git checkout -- path/to/file.R                # older equivalent

# I want to see what HEAD looks like for one file
git show HEAD:path/to/file.R
```

The `git reset --hard` and `git clean -fd` family is **destructive** —
prefer the non-`--hard` variants above unless you're sure.

## Quick troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `git status` says hundreds of new files | A fit run wrote into a folder not in `.gitignore` | `git check-ignore -v <path>`; add a rule before staging. |
| `git push` rejected: "pack exceeds maximum size" | A large file (>100 MB) is in the commit | Find it with `git diff --cached --stat`, unstage, commit without it. |
| `git push` rejected: "file > 100 MB" | Same — GitHub blocks per-file >100 MB | Add the path to `.gitignore` + `git restore --staged <path>`. |
| `git add -A` staged a `.rds` | The file was force-added once and is now tracked | `git rm --cached <path>` (does not delete on disk). |
| Pre-commit hook says CRLF will be replaced | Windows line-ending warning, harmless | Ignore it; the file commits fine. |

## See also

- [`output_commit_policy.md`](output_commit_policy.md) — what each
  category of file should do (commit vs ignore vs force-add).
- [`release_checklist.md`](release_checklist.md) — pre-flight before a
  public release.
- [`pipeline_layout.md`](pipeline_layout.md) — the folder layout this
  policy applies to.
