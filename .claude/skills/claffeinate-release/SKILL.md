---
name: claffeinate-release
description: Cut a Claffeinate release for a given version — bump the version/build, build & notarize the app, create/close the GitHub milestone and its issues, and publish the GitHub Release. Use when the user says "release Claffeinate", "cut a release", "Claffeinate のリリース", "リリースして", or names a version to ship (e.g. "release 0.3.0"). A version argument (X.Y.Z) is REQUIRED.
argument-hint: <X.Y.Z>
---

# Claffeinate release

Ship a notarized Claffeinate release end to end. This skill orchestrates the
existing `scripts/release.sh` (archive → Developer ID sign → notarize → staple →
package) and the GitHub side (milestone, issues, Release).

## Required input

A target **marketing version** `X.Y.Z` (semver). If the user did not give one,
**stop and ask** — never guess. Everything below uses `$VERSION` for it.

The **build number** is bumped automatically (current app build + 1). The git
tag and Release are named `X.Y.Z` (no `v` prefix — matches the existing `0.1.0`
tag).

## Why this order (optimized from the rough draft)

The user's draft was: bump+commit → build → milestone → issues → done → release.
Re-ordered for safety and good notes:

1. **Preflight & confirm first** — validate everything and get one explicit
   go-ahead before any mutation (commits, notarization, closing issues, and a
   public Release are all consequential / outward-facing).
2. **Build is the gate for tag & Release** — bump and commit, then build; only
   tag/push/publish *after* a successful notarized build, so a broken or
   un-notarizable build never produces a dangling tag or a half-published
   Release.
3. **Milestone + issues before the Release** — so the Release notes can be
   generated from the milestone's issues, and the milestone is closed as part of
   shipping.

## Prerequisites (fail early if missing)

- `gh auth status` is logged in (account `matwu`), remote is `matwu/Claffeinate`.
- A "Developer ID Application" cert for team `9VMM83M3Y6` in the keychain, and a
  stored notarytool profile named `Claffeinate` (see the header of
  `scripts/release.sh`). Without these, `release.sh` cannot notarize.
- On branch `main` with the intended changes present (they will be committed).

---

## Procedure

### 0. Preflight (no side effects)

```bash
cd "$(git rev-parse --show-toplevel)"
gh auth status
git branch --show-current                       # expect: main
git status --short                               # changes that will be committed
CUR_VERSION=$(grep -m1 'MARKETING_VERSION = [0-9]' Claffeinate.xcodeproj/project.pbxproj | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
CUR_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' Claffeinate.xcodeproj/project.pbxproj | grep -oE '[0-9]+')
LAST_TAG=$(git tag --sort=-v:refname | head -1)
echo "current: $CUR_VERSION (build $CUR_BUILD) · last tag: $LAST_TAG · new: $VERSION (build $((CUR_BUILD+1)))"
```

Validate:
- `$VERSION` matches `^[0-9]+\.[0-9]+\.[0-9]+$`.
- A tag / Release named `$VERSION` does **not** already exist
  (`git tag | grep -qx "$VERSION"` and `gh release view "$VERSION"`); if it does,
  stop and tell the user.

**Determine the milestone & candidate issues.** Milestone title = `$VERSION`.
Gather issues this release should cover from commit references since the last
tag, then confirm with the user (don't assume "relevant"):

```bash
git log "${LAST_TAG}..HEAD" --pretty=%B | grep -oiE '#[0-9]+' | tr -d '#' | sort -un
gh issue list --repo matwu/Claffeinate --state all --limit 50
```

Present a **plan summary** and get explicit confirmation before proceeding:
- version `$CUR_VERSION` → `$VERSION`, build `$CUR_BUILD` → `$((CUR_BUILD+1))`
- files that will be committed (`git status`)
- milestone to create/use, and the exact issue numbers that will be assigned to
  it **and closed**
- that a notarized build, a `git push`, and a public GitHub Release will happen

If the user named specific issues, use those instead of the commit-derived list.

### 1. Bump version & build number

Edit `Claffeinate.xcodeproj/project.pbxproj`:
- Set the **app** `MARKETING_VERSION` to `$VERSION` (both Debug & Release configs
  — they currently read the old `$CUR_VERSION`; the Helper's `1.0` must stay).
- Bump **every** `CURRENT_PROJECT_VERSION` to `$((CUR_BUILD+1))` (unifies the app
  and Helper build numbers; bumping the Helper too makes `SMAppService`
  re-register the updated daemon).

```bash
NEW_BUILD=$((CUR_BUILD+1))
sed -i '' "s/MARKETING_VERSION = ${CUR_VERSION};/MARKETING_VERSION = ${VERSION};/g" Claffeinate.xcodeproj/project.pbxproj
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" Claffeinate.xcodeproj/project.pbxproj
```

Verify with `grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION'` — expect the
app at `$VERSION`, the Helper still `1.0`, all build numbers `$NEW_BUILD`.

### 2. Commit everything

```bash
git add -A
git commit -m "Release ${VERSION} (build ${NEW_BUILD})"
```

(Use the project's commit trailer convention.)

### 3. Build, sign, notarize, package — the gate

```bash
scripts/release.sh        # NO --publish here; we publish ourselves in step 6
```

This archives, exports with Developer ID, **notarizes (waits)**, staples,
verifies with `spctl`, and writes `build/release/Claffeinate-${VERSION}.zip`.
**If this fails, stop** — fix forward; the commit from step 2 is local-only and
no tag/Release exists yet. Confirm the artifact:

```bash
ls -la "build/release/Claffeinate-${VERSION}.zip"
```

### 4. Tag & push

```bash
git tag "${VERSION}"
git push origin main
git push origin "${VERSION}"
```

### 5. Milestone & issues

```bash
# create the milestone if absent
gh api repos/matwu/Claffeinate/milestones --jq '.[].title' | grep -qx "${VERSION}" \
  || gh api repos/matwu/Claffeinate/milestones -f title="${VERSION}" -f state=open >/dev/null
MS_NUM=$(gh api repos/matwu/Claffeinate/milestones --jq ".[] | select(.title==\"${VERSION}\") | .number")
```

For each confirmed issue number `N`: assign the milestone and close it.

```bash
gh issue edit N --repo matwu/Claffeinate --milestone "${VERSION}"
gh issue close N --repo matwu/Claffeinate
```

Then close the milestone (it's shipped):

```bash
gh api -X PATCH "repos/matwu/Claffeinate/milestones/${MS_NUM}" -f state=closed >/dev/null
```

If there were no relevant issues, skip issue assignment but still create (and
close) the milestone, and say so.

### 6. Create the GitHub Release

Write user-facing notes from the milestone's closed issues (their titles), with
a short summary line; fall back to a brief summary if there were none. Then:

```bash
gh release create "${VERSION}" "build/release/Claffeinate-${VERSION}.zip" \
  --title "Claffeinate ${VERSION}" \
  --notes "<curated notes>"
gh release view "${VERSION}" --json url -q .url   # report this to the user
```

The asset is the notarized zip; mention in the notes that it's Developer
ID-signed and notarized (users can unzip → move to /Applications → launch
without a Gatekeeper prompt).

### 7. Report

Summarize: new version/build, commit, tag, milestone (closed), issues closed,
and the Release URL.

## Notes & guardrails

- **Confirm before mutating** (step 0). Re-running for an existing version must
  not silently re-tag or duplicate a Release.
- The README has no hardcoded version (it links `/releases/latest` and uses a
  `<version>` placeholder), so it needs no edit.
- Notarization takes a few minutes (`notarytool --wait`); that's expected.
- If `release.sh` lacks the signing cert / notary profile, surface that as the
  blocker rather than attempting an unsigned release (the Helper won't register
  without a notarized bundle).
