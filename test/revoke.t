An author revokes a release of theirs. foo 1.0.0 is published, and the author's
fork is older than it, as a fork usually is:

  $ export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  $ export FAKE="$PWD/fake"
  $ mkdir -p "$FAKE/bin"
  $ cp fake_gh.sh "$FAKE/bin/gh" && chmod +x "$FAKE/bin/gh"
  $ export PATH="$FAKE/bin:$PATH"
  $ SHA=abc0000000000000000000000000000000000000000000000000000000000abc
  $ git init -q -b main "$FAKE/registry" && cd "$FAKE/registry"
  $ echo 'opam-version: "2.0"' > repo && git add . && git commit -qm 'The registry'
  $ git init -q --bare "$FAKE/fork.git" && git push -q "$FAKE/fork.git" main
  $ mkdir -p .open-opam/owners packages/foo/foo.1.0.0
  $ printf 'opam-version: "2.0"\nurl {\n  src: "https://github.com/o/foo/releases/download/1.0.0/foo-1.0.0.tar.gz"\n  checksum: "sha256=%s"\n}\n' "$SHA" > packages/foo/foo.1.0.0/opam
  $ printf '{"github_repository_id":42,"repository":"o/foo","status":"active","claimed_at":"2026-01-01T00:00:00Z"}\n' > .open-opam/owners/foo.json
  $ git add . && git commit -qm 'Publish foo 1.0.0' && cd ..
  $ printf 'foo.opam\nREADME.md\n' > "$FAKE/files"
  $ release() { printf '{"tag_name":"1.0.0","draft":false,"immutable":true,"published_at":"2026-01-01T00:00:00Z","body":"%s","assets":[{"name":"foo-1.0.0.tar.gz","digest":"sha256:%s","browser_download_url":"x"}]}' "$1" "${2:-$SHA}" > "$FAKE/release.json"; }
  $ release 'First release.'

A version that is not revoked has nothing to restore:

  $ open-opam revoke --undo --repo o/foo 1.0.0
  ✓ Registry open-opam/opam-repository
  ✗ Restore 1.0.0
    o/foo 1.0.0 is not revoked.
  [1]

Revoking marks the release's notes, as the author, and opens one pull request
that only adds a record, from the fork as it is:

  $ open-opam revoke --repo o/foo 1.0.0
  ✓ Registry open-opam/opam-repository
  ✓ Your fork of open-opam/opam-repository
  ✓ Branch revoke/foo-1.0.0 on author/opam-repository
  ✓ Pull request on open-opam/opam-repository
    https://github.com/open-opam/opam-repository/pull/1
  → The registry merges it once its checks pass
  $ cat "$FAKE/notes"; echo
  First release.
  
  Revoked on open-opam.
  $ cat "$FAKE/pr_title"
  Revoke foo 1.0.0
  $ git -C "$FAKE/fork.git" show --format=%s --name-status revoke/foo-1.0.0
  Revoke foo 1.0.0
  
  A	.open-opam/revocations/foo.1.0.0.json
  $ git -C "$FAKE/fork.git" show revoke/foo-1.0.0:.open-opam/revocations/foo.1.0.0.json | grep -o '"reason":"author-request","actor":"o/foo","evidence":"https://github.com/o/foo/releases/tag/1.0.0"'
  "reason":"author-request","actor":"o/foo","evidence":"https://github.com/o/foo/releases/tag/1.0.0"

Running it again finds the pull request open:

  $ open-opam revoke --repo o/foo 1.0.0 | tail -2
    https://github.com/open-opam/opam-repository/pull/1
  → The registry merges it once its checks pass

The registry's CI judges that pull request, against the release as it is now:

  $ release 'First release.\n\nRevoked on open-opam.'
  $ git clone -q "$FAKE/registry" ci && git -C ci fetch -q "$FAKE/fork.git" revoke/foo-1.0.0:revoke
  $ open-opam check --checkout ci --base main --head revoke
  ✓ Allowed files
  ✓ Release proof
  ✓ Exact match
  ✓ Name ownership

A release whose notes do not say so was not revoked by its author:

  $ release 'First release.'
  $ open-opam check --checkout ci --base main --head revoke
  ✓ Allowed files
  ✗ Release proof
    The notes of o/foo 1.0.0 do not say "Revoked on open-opam.", so this is not its author's request. [not_marked]
  ✓ Exact match
  ✓ Name ownership
  [1]

A registry that cannot be read is a run that could not finish, never a missing
record and so a refused release:

  $ release 'Revoked on open-opam.'
  $ object=$(git -C ci rev-parse main:.open-opam/owners/foo.json)
  $ loose="ci/.git/objects/$(echo "$object" | cut -c1-2)/$(echo "$object" | cut -c3-)"
  $ mv "$loose" lost
  $ open-opam check --checkout ci --base main --head revoke 2>&1 | grep -v '^✓'
  ✗ Release proof
    git: fatal: git cat-file main:.open-opam/owners/foo.json: bad file
  $ mv lost "$loose"

A record that says something else, or a name another repository owns, is refused:

  $ release 'Revoked on open-opam.'
  $ git -C ci switch -q -c forged main
  $ mkdir -p ci/.open-opam/revocations
  $ printf '{"reason":"security","actor":"o/foo","evidence":"x","revoked_at":"2026-02-01T00:00:00Z"}' > ci/.open-opam/revocations/foo.1.0.0.json
  $ git -C ci add . && git -C ci commit -qm forged
  $ open-opam check --checkout ci --base main --head forged
  ✓ Allowed files
  ✓ Release proof
  ✗ Exact match
    .open-opam/revocations/foo.1.0.0.json: an author's revocation has the reason author-request [record_differs]
  ✓ Name ownership
  [1]
  $ git -C ci switch -q -c taken main
  $ printf '{"github_repository_id":7,"repository":"real/foo","status":"active","claimed_at":"2026-01-01T00:00:00Z"}\n' > ci/.open-opam/owners/foo.json
  $ git -C ci commit -qam 'foo is real/foo' && git -C ci switch -q -c taken-revoke taken
  $ git -C ci checkout -q revoke -- .open-opam/revocations && git -C ci commit -qm revoke
  $ open-opam check --checkout ci --base taken --head taken-revoke | grep -A1 '✗'
  ✗ Name ownership
    foo.1.0.0 belongs to another repository here. [not_the_owner]

A record of the registry's own that cannot be read is the registry's to mend,
not GitHub's:

  $ git -C ci switch -q -c damaged main
  $ echo '{}' > ci/.open-opam/owners/foo.json
  $ git -C ci commit -qam 'damaged' && git -C ci switch -q -c damaged-revoke damaged
  $ git -C ci checkout -q revoke -- .open-opam/revocations && git -C ci commit -qm revoke
  $ open-opam check --checkout ci --base damaged --head damaged-revoke 2>&1 | tail -1 | cut -d: -f1
    The registry's .open-opam/owners/foo.json could not be read

A record for a version the registry does not hold, or beside a publication, is
refused before anything is read:

  $ git -C ci switch -q -c nothing main
  $ mkdir -p ci/.open-opam/revocations && printf '{}' > ci/.open-opam/revocations/foo.9.9.9.json && git -C ci add . && git -C ci commit -qm nothing
  $ open-opam check --checkout ci --base main --head nothing | head -2
  ✗ Allowed files
    .open-opam/revocations/foo.9.9.9.json: the registry holds no such version. [record_without_a_version]

Once merged, the registry's workflow makes the version unavailable. Undoing
takes the mark out of the notes, and adds a restoration record:

  $ git -C "$FAKE/registry" fetch -q "$FAKE/fork.git" revoke/foo-1.0.0 && git -C "$FAKE/registry" merge -q --ff-only FETCH_HEAD 2>/dev/null || git -C "$FAKE/registry" merge -q --no-edit FETCH_HEAD
  $ rm "$FAKE/open_pr"
  $ open-opam revoke --repo o/foo 1.0.0
  ✓ Registry open-opam/opam-repository
  ✗ Revoke 1.0.0
    o/foo 1.0.0 is already revoked.
  [1]
  $ open-opam revoke --undo --repo o/foo 1.0.0 | tail -1
  → The registry merges it once its checks pass
  $ cat "$FAKE/notes"; echo
  
  $ cat "$FAKE/pr_title"
  Restore foo 1.0.0
  $ git -C "$FAKE/fork.git" show --format=%s --name-status restore/foo-1.0.0
  Restore foo 1.0.0
  
  A	.open-opam/restorations/foo.1.0.0.json

and CI accepts it while the release's archive is the one published:

  $ release ''
  $ git -C ci fetch -q "$FAKE/registry" main:merged && git -C ci fetch -q "$FAKE/fork.git" restore/foo-1.0.0:restore
  $ open-opam check --checkout ci --base merged --head restore
  ✓ Allowed files
  ✓ Release proof
  ✓ Exact match
  ✓ Name ownership

but not while the notes still say it is revoked, nor for a version that is not:

  $ release 'Revoked on open-opam.'
  $ open-opam check --checkout ci --base merged --head restore | grep -A1 '✗'
  ✗ Release proof
    The notes of o/foo 1.0.0 still say "Revoked on open-opam.". [still_marked]
  $ release ''
  $ git -C ci switch -q -c live-restore main && git -C ci checkout -q restore -- .open-opam/restorations && git -C ci commit -qm restore
  $ open-opam check --checkout ci --base main --head live-restore | grep -A1 '✗'
  ✗ Exact match
    foo.1.0.0 is not revoked. [not_revoked]
  $ release '' def0000000000000000000000000000000000000000000000000000000000def
  $ open-opam check --checkout ci --base merged --head restore | grep -A1 '✗'
  ✗ Release proof
    foo.1.0.0 cannot be restored: its release's archive is not the one published. [asset_changed]

Revoking again after a restore is its maintainer's to do, and a version the
registry revoked is its maintainer's to restore:

  $ git -C "$FAKE/registry" fetch -q "$FAKE/fork.git" restore/foo-1.0.0 && git -C "$FAKE/registry" merge -q --no-edit FETCH_HEAD
  $ rm "$FAKE/open_pr"
  $ open-opam revoke --repo o/foo 1.0.0
  ✓ Registry open-opam/opam-repository
  ✗ Revoke 1.0.0
    foo.1.0.0 was revoked and restored before. Only the registry's maintainer can revoke it again.
  [1]
  $ cd "$FAKE/registry" && git rm -q .open-opam/restorations/foo.1.0.0.json && printf '{"reason":"security","actor":"maintainer","evidence":"x","revoked_at":"2026-02-01T00:00:00Z"}' > .open-opam/revocations/foo.1.0.0.json && git commit -qam 'Revoke foo 1.0.0 for security' && cd - >/dev/null
  $ open-opam revoke --undo --repo o/foo 1.0.0 2>&1 | tail -1
    foo.1.0.0 was revoked by the registry (security), and only its maintainer can restore it.

and CI refuses such a restoration as well:

  $ release ''
  $ git -C ci fetch -q "$FAKE/registry" main:security && git -C ci switch -q -c security-restore security
  $ git -C ci checkout -q restore -- .open-opam/restorations && git -C ci commit -qm restore
  $ open-opam check --checkout ci --base security --head security-restore | grep -A1 '✗'
  ✗ Exact match
    foo.1.0.0 was revoked by the registry (security), and only its maintainer can restore it. [revoked_by_the_registry]

A release that does not exist, or a version not published here, is said so:

  $ open-opam revoke --repo o/foo 2.0.0
  ✓ Registry open-opam/opam-repository
  ✗ Revoke 2.0.0
    o/foo 2.0.0 is not published on open-opam.
  [1]
  $ rm "$FAKE/release.json"
  $ open-opam revoke --repo o/foo 3.0.0
  ✗ Revoke 3.0.0
    o/foo 3.0.0 has no release.
  [1]
