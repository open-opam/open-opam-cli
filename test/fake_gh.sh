#!/bin/sh
# GitHub, for the tests: what gh answers, from files a test writes under $FAKE.
# git, tar and opam are the real ones.
case "$*" in
  "api repos/ocaml/opam-repository/contents/packages/"*)
    dir="$FAKE/official/${2#repos/ocaml/opam-repository/contents/packages/}"
    if [ -d "$dir" ]; then
      printf '[%s]' "$(ls "$dir" | sed 's/.*/{"name":"&"}/' | paste -sd, -)"
    else
      echo "gh: Not Found (HTTP 404)" >&2; exit 1
    fi ;;
  "api -H Accept: application/vnd.github.raw+json repos/ocaml/opam-repository/contents/packages/"*)
    exec cat "$FAKE/official/${4#repos/ocaml/opam-repository/contents/packages/}" ;;
  "api repos/real/foo")
    echo '{"id":7,"full_name":"real/foo","created_at":"2026-01-01T00:00:00Z"}' ;;
  "api repos/gone/foo")
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "api repos/o/foo/immutable-releases")
    if [ -f "$FAKE/immutability_off" ]; then echo '{"enabled":false}'; else echo '{"enabled":true}'; fi ;;
  "api -X PUT repos/o/foo/immutable-releases")
    rm -f "$FAKE/immutability_off" ;;
  "api repos/o/foo")
    # A fork names its original as its parent.
    if [ -f "$FAKE/fork_of" ]; then parent=$(printf ',"parent":{"full_name":"%s"}' "$(cat "$FAKE/fork_of")"); fi
    printf '{"id":42,"full_name":"o/foo","created_at":"2026-01-01T00:00:00Z"%s}\n' "$parent" ;;
  "api repos/up/foo/contents")
    echo '[{"name":"README.md"},{"name":"foo.opam"},{"name":"foo-cli.opam"}]' ;;
  "api repos/o/foo/releases/tags/"*)
    [ -f "$FAKE/release.json" ] && exec cat "$FAKE/release.json"
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "api repos/o/foo/git/ref/tags/"*)
    sha=$(git -C "$FAKE/foo" rev-parse -q --verify "refs/tags/${2#repos/o/foo/git/ref/tags/}") \
      || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    printf '{"object":{"sha":"%s","type":"%s"}}' "$sha" "$(git -C "$FAKE/foo" cat-file -t "$sha")" ;;
  "api repos/o/foo/git/tags/"*)
    printf '{"object":{"sha":"%s","type":"commit"}}' "$(git -C "$FAKE/foo" rev-parse "${2#repos/o/foo/git/tags/}^{commit}")" ;;
  "api repos/o/foo/commits/"*"/status")
    echo '{"statuses":[]}' ;;
  "api repos/o/foo/commits/"*)
    if [ -f "$FAKE/commit" ]; then sha=$(cat "$FAKE/commit")
    else sha=$(git -C "$FAKE/foo" rev-parse "${2#repos/o/foo/commits/}^{commit}"); fi
    printf '{"sha":"%s"}' "$sha" ;;
  "api repos/o/foo/attestations/"*)
    if [ -f "$FAKE/github_down" ]; then
      echo "gh: Bad Gateway (HTTP 502)" >&2
      echo '{"message":"Bad Gateway","status":"502"}' >&2; exit 1
    fi
    [ -f "$FAKE/verify.json" ] && exec echo '{"attestations":[{}]}'
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "release verify "*)
    if [ -f "$FAKE/verify_down" ]; then
      echo "Get \"https://api.github.com/repos/o/foo/git/ref/tags%2F$3\": dial tcp: lookup api.github.com: no such host" >&2; exit 1
    fi
    if [ -f "$FAKE/verify_refused" ]; then
      echo "failed to verify attestations for tag $3: verifying with issuer \"sigstore.dev\"" >&2; exit 1
    fi
    cat "$FAKE/verify.json" ;;
  "release verify-asset "*)
    if [ -f "$FAKE/asset_refused" ]; then
      echo "attestation for $3 does not contain subject sha256:0000" >&2; exit 1
    fi ;;
  "release download "*)
    cp "$FAKE/asset.tar.gz" "$9/$7" ;;
  "api --paginate --slurp "*)
    # GitHub knows only the commits pushed to it.
    sha=${4#repos/*/commits/}; sha=${sha%%/*}
    if [ -d "$FAKE/foo" ] && ! git -C "$FAKE/foo" cat-file -e "$sha^{commit}" 2>/dev/null; then
      echo "gh: No commit found for SHA: $sha (HTTP 422)" >&2
      printf '[{"message":"No commit found for SHA: %s","status":"422"}]\n' "$sha" >&2
      exit 1
    fi
    cat "$FAKE/checks.json"
    # The checks a later ask finds, as CI finishes.
    if [ -f "$FAKE/checks_next.json" ]; then mv "$FAKE/checks_next.json" "$FAKE/checks.json"; fi ;;
  "api -H Accept: application/vnd.github.raw+json repos/open-opam/opam-repository/contents/"*)
    file="$FAKE/registry/${4#repos/open-opam/opam-repository/contents/}"
    [ -f "$file" ] && exec cat "$file"
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "repo clone o/foo "*)
    dir=$4; shift 5; exec git clone "$@" "file://$FAKE/foo" "$dir" ;;
  "repo clone open-opam/opam-repository "*)
    dir=$4; shift 5; exec git clone "$@" "file://$FAKE/registry" "$dir" ;;
  "api -X POST repos/open-opam/opam-repository/forks "*)
    echo "file://$FAKE/fork.git author author/opam-repository" ;;
  "api repos/open-opam/opam-repository/pulls?head="*)
    if [ -f "$FAKE/open_pr" ]; then cat "$FAKE/open_pr"; else echo '[]'; fi ;;
  "pr create "*)
    if [ -f "$FAKE/pr_refused" ]; then
      printf 'pull request create failed: GraphQL: No commits between main and publish\nhint: try again\n' >&2; exit 1
    fi
    printf '%s\n' "$*" > "$FAKE/pr"
    printf '%s\n' "${10}" > "$FAKE/pr_title"
    printf '%s\n' "${12}" > "$FAKE/pr_body"
    echo '[{"html_url":"https://github.com/open-opam/opam-repository/pull/1"}]' > "$FAKE/open_pr"
    echo "https://github.com/open-opam/opam-repository/pull/1" ;;
  "api repos/o/foo/contents?ref="*|"api repos/o/foo/contents")
    printf '[%s]' "$(cat "$FAKE/files" | sed 's/.*/{"name":"&"}/' | paste -sd, -)" ;;
  "api repos/open-opam/opam-repository/contents/packages/"*)
    dir="$FAKE/registry/${2#repos/open-opam/opam-repository/contents/}"
    if [ -d "$dir" ]; then
      printf '[%s]' "$(ls "$dir" | sed 's/.*/{"name":"&"}/' | paste -sd, -)"
    else
      echo "gh: Not Found (HTTP 404)" >&2; exit 1
    fi ;;
  "release view "*)
    grep -qs "\"tag_name\":\"$3\"" "$FAKE/release.json" || { echo "release not found" >&2; exit 1; }
    if grep -q '"draft":true' "$FAKE/release.json"; then echo '{"isDraft":true}'
    else echo '{"isDraft":false}'; fi ;;
  "release create "*)
    [ -f "$FAKE/release_refused" ] && { echo "HTTP 422: Validation Failed" >&2; exit 1; }
    printf '{"tag_name":"%s","draft":true,"immutable":false,"published_at":null,"body":"","assets":[]}' "$3" > "$FAKE/release.json" ;;
  "release upload "*)
    cp "$4" "$FAKE/asset.tar.gz"
    sha=$(openssl dgst -sha256 -r "$4" | cut -d' ' -f1)
    printf '{"tag_name":"%s","draft":true,"immutable":false,"published_at":null,"body":"","assets":[{"name":"%s","digest":"sha256:%s","browser_download_url":"x"}]}' \
      "$3" "$(basename "$4")" "$sha" > "$FAKE/release.json" ;;
  "release edit "*" --draft=false")
    # GitHub publishes the draft, immutable, and attests the tag and its asset.
    sed 's/"draft":true,"immutable":false,"published_at":null/"draft":false,"immutable":true,"published_at":"2026-11-09T12:00:00Z"/' "$FAKE/release.json" > "$FAKE/published.json"
    mv "$FAKE/published.json" "$FAKE/release.json"
    named=$(git -C "$FAKE/foo" rev-parse "refs/tags/$3")
    sha=$(openssl dgst -sha256 -r "$FAKE/asset.tar.gz" | cut -d' ' -f1)
    printf '{"verificationResult":{"statement":{"subject":[{"digest":{"sha1":"%s"}},{"digest":{"sha256":"%s"}}],"predicate":{"repositoryId":"42"}}}}' \
      "$named" "$sha" > "$FAKE/verify.json" ;;
  "release edit "*)
    printf '%s' "$7" > "$FAKE/notes" ;;
  "issue list "*)
    if [ -f "$FAKE/issues" ]; then cat "$FAKE/issues"; else echo '[]'; fi ;;
  "issue create "*)
    printf '%s\n' "$6" > "$FAKE/issue_title"
    printf '%s\n' "$8" > "$FAKE/issue_body"
    printf '[{"title":"%s","url":"https://github.com/open-opam/opam-repository/issues/2"}]' "$6" > "$FAKE/issues"
    echo "https://github.com/open-opam/opam-repository/issues/2" ;;
  "pr list "*)
    if [ -f "$FAKE/pulls" ]; then cat "$FAKE/pulls"; else echo '[]'; fi ;;
  *)
    echo "fake gh does not know: $*" >&2; exit 3 ;;
esac
