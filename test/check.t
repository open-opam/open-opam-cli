A project that meets the standard passes, from a real archive:

  $ mkdir -p foo-1.0.0/src foo-1.0.0/test
  $ cat > foo-1.0.0/foo.opam <<'EOF'
  > opam-version: "2.0"
  > synopsis: "A scratch package"
  > description: "A scratch package to hold the standard against."
  > maintainer: "x <x@example.com>"
  > authors: "x"
  > license: "MIT"
  > homepage: "https://github.com/o/foo"
  > bug-reports: "https://github.com/o/foo/issues"
  > dev-repo: "git+https://github.com/o/foo.git"
  > depends: ["dune" {>= "3.18"}]
  > build: ["dune" "build" "-p" name "-j" jobs]
  > EOF
  $ touch foo-1.0.0/dune-project foo-1.0.0/src/foo.mli
  $ echo '# foo' > foo-1.0.0/README.md
  $ echo '(test (name t))' > foo-1.0.0/test/dune
  $ tar -czf good.tar.gz foo-1.0.0
  $ open-opam check --archive good.tar.gz
  ✓ Metadata and standard

Taking away what the standard asks for fails, says why, and exits 1:

  $ rm foo-1.0.0/test/dune foo-1.0.0/src/foo.mli foo-1.0.0/README.md
  $ tar -czf bad.tar.gz foo-1.0.0
  $ open-opam check --archive bad.tar.gz
  ✗ Metadata and standard
    There is no README at the root. [no_readme]
    There is no .mli: a release states its public interface. [no_interface]
    There is no test: no dune test, tests or cram stanza, no *.t and no runtest rule. [no_test]
  [1]

The same result, as the JSON the CI check is written from:

  $ open-opam check --archive bad.tar.gz --format json | head -c 62
  {"passed":false,"gates":[{"gate":"metadata-and-standard","pass

An opam file lint refuses is refused here too, naming the file:

  $ mkdir -p bar-1.0.0
  $ cat > bar-1.0.0/bar.opam <<'EOF'
  > opam-version: "2.0"
  > synopsis: ""
  > maintainer: "x"
  > license: "MIT"
  > dev-repo: "git+https://github.com/o/bar.git"
  > EOF
  $ tar -czf lint.tar.gz bar-1.0.0
  $ open-opam check --archive lint.tar.gz | grep -c 'bar.opam: opam lint failed'
  1

A publication in a registry's history passes the allowed-files gate, and the
rest are judged as CI judges them:

  $ mkdir registry && cd registry
  $ git init -q -b main . && git config user.email t@t && git config user.name t
  $ mkdir -p packages/foo/foo.1.0.0 && echo x > packages/foo/foo.1.0.0/opam
  $ git add . && git commit -qm base
  $ git switch -qc publish
  $ mkdir -p packages/foo/foo.1.1.0 && echo x > packages/foo/foo.1.1.0/opam
  $ git add . && git commit -qm publish
  $ open-opam check --checkout . --base main --head publish
  ✓ Allowed files
  ✗ Release proof
    The release named by an added opam file was not found on GitHub. [not_found]
  [1]

and one that also rewrites a published version does not:

  $ echo y > packages/foo/foo.1.0.0/opam
  $ git add . && git commit -qm rewrite
  $ open-opam check --checkout . --base main --head publish
  ✗ Allowed files
    packages/foo/foo.1.0.0/opam: a publication may not change what is already published. [changes_what_exists]
  ✗ Release proof
    The release named by an added opam file was not found on GitHub. [not_found]
  [1]

A run that cannot finish is not a refusal, and exits 2:

  $ open-opam check --checkout . --base no-such-ref --head publish 2>/dev/null
  ✗ Allowed files
  [2]

Nor is a program it cannot run, which it says in a sentence:

  $ mkdir -p "$PWD/no-exec" && touch "$PWD/no-exec/gh"
  $ PATH="$PWD/no-exec:$PATH" open-opam status --repo o/foo 2>&1 | sed "s|$PWD/||"
  no-exec/gh cannot be run: permission denied.
  $ PATH="$PWD/no-exec:$PATH" open-opam status --repo o/foo 2>/dev/null
  [2]
