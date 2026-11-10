An author's repository, with nothing set up yet:

  $ export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  $ export FAKE="$PWD/fake"
  $ mkdir -p "$FAKE/bin"
  $ cp fake_gh.sh "$FAKE/bin/gh" && chmod +x "$FAKE/bin/gh"
  $ export PATH="$FAKE/bin:$PATH"
  $ touch "$FAKE/immutability_off"
  $ git init -q --bare "$FAKE/foo"
  $ git init -q -b main work && cd work
  $ git remote add origin git@github.com:o/foo.git
  $ git remote set-url --push origin "file://$FAKE/foo"
  $ mkdir src test
  $ cat > foo.opam <<'EOF'
  > opam-version: "2.0"
  > synopsis: "A scratch package"
  > description: "A scratch package to publish."
  > maintainer: "x <x@example.com>"
  > authors: "x"
  > license: "MIT"
  > homepage: "https://github.com/o/foo"
  > bug-reports: "https://github.com/o/foo/issues"
  > dev-repo: "git+https://github.com/o/foo.git"
  > depends: ["dune" {>= "3.18"}]
  > build: ["dune" "build" "-p" name "-j" jobs]
  > EOF
  $ touch dune-project src/foo.mli
  $ echo '# foo' > README.md
  $ echo '(test (name t))' > test/dune
  $ echo 'version $Format:%(describe:tags=true)$' > version.txt
  $ echo 'version.txt export-subst' > .gitattributes
  $ git add . && git commit -qm start && git push -q origin main

Declining init changes nothing:

  $ echo n | open-opam init
  This will:
    - turn on immutable releases for o/foo
    - offer foo.opam here, with x-open-opam: true
  Go ahead? [y/N] ✗ Nothing changed
  → To set up later: open-opam init
  $ git status --short
  $ test -f "$FAKE/immutability_off" && echo 'still off'
  still off

Before init, checking the commit says what is missing, and publishing has no release to read:

  $ git init -q -b main "$FAKE/registry"
  $ git -C "$FAKE/registry" commit -q --allow-empty -m start
  $ echo '[{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}]' > "$FAKE/checks.json"
  $ open-opam check 1.0.0
  ✓ Archive foo-1.0.0.tar.gz of this commit
  ✗ Release proof
    Immutable releases are off for this repository: run open-opam init. [immutability_off]
  ✗ Exact match
    foo.opam: needs x-open-opam: true, which is how a repository offers a release here: run open-opam init. [no_consent]
  ✓ Name ownership
  ✓ Metadata and standard
  ✓ Author's CI
  [1]
  $ open-opam publish 1.0.0
  ✗ Release proof
    There is no release 1.0.0 on GitHub: make it with open-opam release 1.0.0. [no_release]
  [1]
  $ git tag

A file init cannot write is a run that could not finish, said in a sentence:

  $ chmod a-w foo.opam
  $ open-opam init --yes 2>&1 | tail -1
    foo.opam cannot be written: permission denied.
  $ chmod u+w foo.opam && git checkout -q -- . && touch "$FAKE/immutability_off"

init sets it up, in one commit, and for dune writes the template too:

  $ open-opam init --yes
  This will:
    - turn on immutable releases for o/foo
    - offer foo.opam here, with x-open-opam: true
  ✓ Immutable releases on o/foo
  ✓ x-open-opam: true in foo.opam
  ✓ Commit "Offer releases to open-opam"
  → Release it: open-opam release <version>
  $ git log --format=%s -1
  Offer releases to open-opam
  $ git show --name-only --format= HEAD
  foo.opam
  foo.opam.template
  $ tail -1 foo.opam
  x-open-opam: true
  $ cat foo.opam.template
  x-open-opam: true
  $ test -f "$FAKE/immutability_off" || echo 'turned on'
  turned on

Running it again has nothing to do:

  $ open-opam init
  ✓ o/foo is set up to publish
  → Release a commit: open-opam release <version>

Checking a commit GitHub does not have yet says what to do:

  $ git commit -q --allow-empty -m 'not pushed'
  $ open-opam check 1.0.0 | tail -2
  ✗ Author's CI
    This commit is not on GitHub yet: push it, wait for its CI to pass, then run this again. [not_pushed]
  $ git tag
  $ git reset -q --hard HEAD~1

With only immutability to turn on, there is no commit to push:

  $ touch "$FAKE/immutability_off"
  $ open-opam init --yes
  This will:
    - turn on immutable releases for o/foo
  ✓ Immutable releases on o/foo
  → Release a commit: open-opam release <version>
  $ git status --short
  $ git push -q origin main

Checking a commit with uncommitted changes is refused, since a release is one commit:

  $ echo more >> README.md
  $ open-opam check 1.0.0
  Your changes are not committed: commit or remove them, then run this again.
  [2]
  $ git checkout -q README.md

A red job shows before the tag exists, so no version number is lost:

  $ echo '[{"check_runs":[{"name":"test (5.5)","status":"completed","conclusion":"failure"}]}]' > "$FAKE/checks.json"
  $ open-opam check 1.0.0 | tail -2
  ✗ Author's CI
    test (5.5) finished as failure. [failed]

and releasing such a commit is refused before anything is tagged:

  $ open-opam release 1.0.0 | tail -2
  ✗ Author's CI
    test (5.5) finished as failure. [failed]
  $ open-opam release 1.0.0 > /dev/null
  [1]
  $ git tag; git ls-remote --tags "$FAKE/foo"
  $ echo '[{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}]' > "$FAKE/checks.json"
  $ open-opam check 1.0.0
  ✓ Archive foo-1.0.0.tar.gz of this commit
  ✓ Release proof
  ✓ Exact match
  ✓ Name ownership
  ✓ Metadata and standard
  ✓ Author's CI
  $ git tag

A tag with a v names the version without it, as the archive does:

  $ open-opam check v1.0.0 | head -1
  ✓ Archive foo-1.0.0.tar.gz of this commit

release makes the release those gates expect: it tags the commit it checked,
then makes a draft, attaches the archive it checked, and publishes the draft,
so the release is immutable with its one archive. git acts as the author, here
through the address it pushes the tag to:

  $ git config url."file://$FAKE/foo".insteadOf https://github.com/o/foo.git

A push refused, as by a protected branch, stops before anything is tagged:

  $ git remote set-url --push origin "$FAKE/nowhere"
  $ open-opam release 1.0.0 2>&1
  ✓ Archive foo-1.0.0.tar.gz of this commit
  ✗ Push this commit to origin
    git: fatal: '$TESTCASE_ROOT/fake/nowhere' does not appear to be a git repository
    fatal: Could not read from remote repository.
    Please make sure you have the correct access rights
    and the repository exists.
  → Once the push works: open-opam release 1.0.0
  [2]
  $ git tag
  $ git remote set-url --push origin "file://$FAKE/foo"

A file attached under the archive's name is refused before anything is tagged,
since a release has one archive:

  $ echo other > "$FAKE/foo-1.0.0.tar.gz"
  $ open-opam release 1.0.0 --attach "$FAKE/foo-1.0.0.tar.gz" 2>&1
  foo-1.0.0.tar.gz would be a second archive of 1.0.0, and a release has one: attach it under another name.
  [2]
  $ git tag

release pushes the commit, since CI runs on GitHub, waits while its checks
run, and gives the draft any file attached, such as a binary, with its archive:

  $ echo '[{"check_runs":[{"name":"test","status":"in_progress","conclusion":null}]}]' > "$FAKE/checks.json"
  $ echo '[{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}]' > "$FAKE/checks_next.json"
  $ echo plugin > "$FAKE/plugin-1.0.0.tgz"
  $ open-opam release 1.0.0 --attach "$FAKE/plugin-1.0.0.tgz"
  ✓ Archive foo-1.0.0.tar.gz of this commit
  ✓ Push this commit to origin
  ✓ Release proof
  ✓ Exact match
  ✓ Name ownership
  ✓ Metadata and standard
  ✓ Author's CI
  ✓ Tag 1.0.0 on o/foo
  ✓ Release 1.0.0 of o/foo, with its archive
    https://github.com/o/foo/releases/tag/1.0.0
  → Publish it: open-opam publish 1.0.0
  $ git ls-remote --tags "$FAKE/foo" | cut -f2
  refs/tags/1.0.0
  $ tar -tzf "$FAKE/asset.tar.gz" | head -1
  foo-1.0.0/

A file git archive fills in from git describe says the version the release is,
since the commit carries its tag while it is archived:

  $ tar -xzOf "$FAKE/asset.tar.gz" foo-1.0.0/version.txt
  version 1.0.0
  $ grep -o '"name":"[^"]*"' "$FAKE/release.json"
  "name":"foo-1.0.0.tar.gz"
  "name":"plugin-1.0.0.tgz"

Releasing again changes nothing, since the release is made:

  $ open-opam release 1.0.0 | tail -2
    https://github.com/o/foo/releases/tag/1.0.0
  → Publish it: open-opam publish 1.0.0

Then publishing reads that release, and opens its pull request:

  $ git init -q --bare "$FAKE/fork.git"
  $ open-opam publish 1.0.0
  ✓ Release proof
  ✓ Archive equals tag
  ✓ Exact match
  ✓ Name ownership
  ✓ Metadata and standard
  ✓ Author's CI
  ✓ Registry open-opam/opam-repository
  ✓ Your fork of open-opam/opam-repository
  ✓ Branch publish/foo-1.0.0 on author/opam-repository
  ✓ Pull request on open-opam/opam-repository
    https://github.com/open-opam/opam-repository/pull/1
  → The registry merges it once its checks pass
  $ git -C "$FAKE/fork.git" show --format=%s --name-only publish/foo-1.0.0
  Publish foo 1.0.0
  
  .open-opam/owners/foo.json
  packages/foo/foo.1.0.0/opam

A tag is never moved: one that already names another commit is refused, and
nothing is released:

  $ echo more >> README.md && git commit -qam more && git push -q origin main
  $ git tag 2.0.0 HEAD~1
  $ open-opam release 2.0.0 2>&1 | tail -1 | sed "s/$(git rev-parse HEAD~1)/THE-FIRST-COMMIT/"
    The tag 2.0.0 already names THE-FIRST-COMMIT, not this commit: a published tag is never moved.
  $ open-opam release 2.0.0 > /dev/null 2>&1
  [2]
  $ git ls-remote --tags "$FAKE/foo" | cut -f2
  refs/tags/1.0.0
