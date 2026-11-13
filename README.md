# open-opam

[![ci](https://img.shields.io/github/actions/workflow/status/open-opam/open-opam-cli/ci.yml?branch=main&label=ci)](https://github.com/open-opam/open-opam-cli/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/open-opam/open-opam-cli?label=release)](https://github.com/open-opam/open-opam-cli/releases)
[![license](https://img.shields.io/github/license/open-opam/open-opam-cli)](LICENSE)
![OCaml 5.5+](https://img.shields.io/badge/OCaml-5.5%2B-EC6813?logo=ocaml&logoColor=white)

The CLI to publish and manage your packages on [open-opam](https://open-opam.org/).

## Install

```sh
opam repo add open-opam https://github.com/open-opam/opam-repository.git
opam install open-opam
```

Requires [GitHub CLI](https://cli.github.com).

## Commands

| Command | Arguments | Purpose |
|---|---|---|
| `init` | `[--yes]` | Set your repository up, once |
| `check` | `[VERSION]` | See if this commit would pass, before you release |
| `release` | `VERSION [--attach FILE]` | Tag this commit and make its GitHub release |
| `publish` | `VERSION [--dry-run]` | Publish the release to open-opam |
| `status` | | Show what open-opam holds of your packages |
| `revoke` | `VERSION [--undo]` | Take a published version back, or restore it |

`open-opam COMMAND --help` for more.

## Example

```sh
cd my-library
open-opam init
open-opam release 1.0.0
open-opam publish 1.0.0
```

## Licence

MIT, copyright open-opam contributors. See [LICENSE](LICENSE).
