# open-opam

[![ci](https://img.shields.io/github/actions/workflow/status/open-opam/open-opam-cli/ci.yml?branch=main&label=ci)](https://github.com/open-opam/open-opam-cli/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/open-opam/open-opam-cli?label=release)](https://github.com/open-opam/open-opam-cli/releases)
[![license](https://img.shields.io/github/license/open-opam/open-opam-cli)](LICENSE)
![OCaml 5.5+](https://img.shields.io/badge/OCaml-5.5%2B-EC6813?logo=ocaml&logoColor=white)

The command that publishes a GitHub release to the
[open-opam registry](https://github.com/open-opam/opam-repository), and the
gates a release must pass there. An author runs on their machine the same
gates the registry's CI runs.

**Status: being built.**

## Use

```sh
opam repo add open-opam https://github.com/open-opam/opam-repository.git --rank=-1
opam install open-opam

open-opam init            # once: immutable releases, and offering your packages
open-opam check 1.2.3     # before you tag: would this commit, released as 1.2.3, pass?
open-opam release 1.2.3   # check, then tag this commit and make its release
open-opam publish 1.2.3   # after you release: open its pull request
open-opam status          # what the registry holds of your packages, and what is waiting
open-opam revoke 1.2.3    # take a release back: opam stops installing it, it stays listed
open-opam --version
```

`release` makes the release the registry expects. It holds the commit to every
gate `check` runs, and tags it only once they pass, so a mistake never costs a
version number. Then it pushes the tag, makes a draft release, attaches the
archive the gates checked, and publishes the draft, as you, through `gh`.
Running it again reuses the tag and a draft left behind, and a release already
made is left as it is; a tag that names another commit is never moved.

Or release your own way, with your workflow and your notes. The release must be
immutable, with one archive attached before it is published, named
`<name>-1.2.3.tar.gz` or `<name>-1.2.3.tbz`; it holds the tag's files, as they
are or after `dune subst`, as dune-release makes it. With dune-release, publish
the release as a draft (`dune-release publish --draft`), then publish the draft,
since an immutable release takes no asset once it is published. Either way,
`publish` reads the release and changes nothing in your repository.

`publish` checks the release against the registry's gates, then opens one pull
request, which merges by itself once the registry's checks pass. Running it
again finds the pull request already open. It holds no credential: `gh` and
`git` act as you, so it runs wherever `gh` is signed in, your release workflow
too, given a token that can fork the registry and open a pull request.

`revoke` adds the line `Revoked on open-opam.` to the release's notes on GitHub,
as you, and opens one pull request that adds a record for each of its packages;
since only someone who can write to your repository can change those notes, that
is how the registry knows the request is yours. Once it merges, the registry
makes the version unavailable, and opam refuses to install it while still
listing it. `revoke --undo 1.2.3` takes the line out and asks for it back. A
version the registry revoked itself, for security or a legal reason, is its
maintainer's to restore.

## What a release must hold

The registry holds every release to the same standard, and `check` holds yours
to it before you tag:

- a `dune-project`, since a release is built with dune;
- an `.opam` file at the root for each package, with `synopsis`, `maintainer`,
  `license` and a `dev-repo` that names this repository, and
  `x-open-opam: true`, which `init` adds. A `version`, if it states one, is the
  tag's. It has no `url` or `x-commit-hash`, which the registry writes, and no
  `pin-depends`, `patches`, `extra-files` or `extra-source`, since a release is
  its archive and nothing else;
- a package name that is yours: the first repository to publish a name owns
  it, a name official opam holds comes from the repository it names, and a
  GitHub fork never takes a name its original publishes, so the original's
  author can always claim it;
- a `README` at the root that says something, an `.mli`, and a test;
- CI that runs on pushes to the branch you tag, and passes on the tagged commit.

## Licence

MIT, copyright open-opam contributors. See [LICENSE](LICENSE).
