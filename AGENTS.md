# AGENTS.md

This repository is open-opam's command line and the gates of its registry, and
is in OCaml. This file is for anyone changing it, human or agent. Users start at
[README.md](README.md).

## Commands

```sh
make setup    # once: the switch open-opam and all dependencies
make test     # every test
make lint     # formatting, odoc, and the release build
make fmt      # format in place
```

Its libraries come from the registry, so `make setup` adds it. `REGISTRY=<a
checkout>` uses another copy, reading what that checkout has committed.

## Layout

```
src/allowed_files   gate 1: a change only adds one release's files, or its records
src/release         gates 2, 4 and 7, as pure functions of what was found
src/official        which repository official opam names for a name
src/name_ownership  gate 5: a name belongs to one repository, by its ID
src/standard        gate 6: what a machine can hold every release to
src/opam_file       an opam file's fields, by opam's own grammar
src/github          GitHub's answers, validated where they enter
src/records         the registry's records
src/layout          where the registry keeps each file: its paths, written and read
src/report          the document the terminal and the CI check are written from
src/tools           the programs it calls: gh, git, tar, diff, opam, dune, mktemp, mkdir, ls
src/gates           finds what the gates judge, and runs them
src/releasing       tags a checked commit and makes its release, immutable with that archive
src/publish         opens the one pull request a release is published or revoked through
src/revocation      revoking and restoring: the release's mark, the records, what CI holds them to
src/status          what the registry holds of a repository's packages
src/step            what a run is doing, for whoever shows it
bin/main            the command
bin/display         what a person sees: a spinner on the running step, a line for each one done
```

## Rules that must hold

- **A refused release and a run that could not finish exit differently**: 1 and
  2. Why: CI must never read a broken run as a refusal, or the reverse. Symptom:
  a `` `Tool `` error reported as a gate's problem.
- **`open-opam` is only what an author does with their own packages**: set up,
  check, release, publish, revoke, status. The registry's CI runs the same
  `check` on each pull request, from the release the registry names; anything
  else the registry does is its own workflows'. Why: a public tool offers no
  control of the registry, and the checks an author runs are the ones that
  decide. Symptom: a command that writes to a checkout of the registry.
- **A pull request only adds files.** A revocation or a restoration is a
  record added, as a publication is an opam file added; the registry's workflow
  makes the opam file match once it merges. Why: an author's fork is usually
  behind the registry, and GitHub refuses to bring it up to date without a
  permission an author should never need. Symptom: a branch that changes a file
  the registry holds.
- **It holds no credential.** `gh` and `git` act as the author. Why: there is
  nothing here to steal, and no account to register. Symptom: a token in an
  argument, a file or a log.
- **It never extracts an archive to read it.** It lists and reads, or unpacks
  only below its own temporary directory to compare. Why: an archive is
  untrusted. Symptom: a path from an archive used outside that directory.
- **What a publication adds is a function of the release.** Why: CI writes it
  again and compares byte for byte, so anything not derived from the release,
  such as the current time, makes every publication fail. A revocation's or a
  restoration's record carries the author's time, which CI does not compare.
  Symptom: `Ptime_clock` in what `Release` generates.
