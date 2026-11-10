What the registry holds of a repository's packages, and which pull requests
wait for it. foo 0.9.0 is published and its author revoked it, and foo 1.0.0
is published:

  $ export FAKE="$PWD/fake"
  $ mkdir -p "$FAKE/bin"
  $ cp fake_gh.sh "$FAKE/bin/gh" && chmod +x "$FAKE/bin/gh"
  $ export PATH="$FAKE/bin:$PATH"
  $ cd "$FAKE" && mkdir -p registry/packages/foo/foo.0.9.0 registry/packages/foo/foo.1.0.0 registry/.open-opam/owners registry/.open-opam/revocations
  $ echo 'opam-version: "2.0"' | tee registry/packages/foo/foo.0.9.0/opam > registry/packages/foo/foo.1.0.0/opam
  $ printf '{"github_repository_id":42,"repository":"o/foo","status":"active","claimed_at":"2026-01-01T00:00:00Z"}\n' > registry/.open-opam/owners/foo.json
  $ printf '{"reason":"author-request","actor":"o/foo","evidence":"x","revoked_at":"2026-02-01T00:00:00Z"}\n' > registry/.open-opam/revocations/foo.0.9.0.json
  $ echo foo.opam > files && cd - > /dev/null

Only the pull requests that name this repository's releases are its own, though
another repository's branch is named alike:

  $ cat > "$FAKE/pulls" <<'EOF'
  > [{"title":"Publish foo 1.1.0","url":"https://github.com/open-opam/opam-repository/pull/3","headRefName":"publish/foo-1.1.0",
  >   "body":"**foo 1.1.0**\n\nRelease: https://github.com/o/foo/releases/tag/1.1.0"},
  >  {"title":"Publish foo 2.0.0","url":"https://github.com/open-opam/opam-repository/pull/4","headRefName":"publish/foo-2.0.0",
  >   "body":"**foo 2.0.0**\n\nRelease: https://github.com/other/foo/releases/tag/2.0.0"},
  >  {"title":"Publish foo-bar 1.0.0","url":"https://github.com/open-opam/opam-repository/pull/5","headRefName":"publish/foo-bar-1.0.0",
  >   "body":"**foo-bar 1.0.0**\n\nRelease: https://github.com/o/foo-bar/releases/tag/1.0.0"}]
  > EOF
  $ open-opam status --repo o/foo
  foo
    0.9.0  revoked (by you)
    1.0.0  published
  Waiting
    Publish foo 1.1.0  https://github.com/open-opam/opam-repository/pull/3
