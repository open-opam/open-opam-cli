SWITCH ?= open-opam
OPAM = opam exec --switch=$(SWITCH) --
# Where the switch finds the registry; another checkout during development.
REGISTRY ?= https://github.com/open-opam/opam-repository.git

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

setup: ## create the switch and install dependencies
	@opam switch list --short | grep -qx $(SWITCH) || opam switch create $(SWITCH) --empty -y
	opam repo add open-opam $(REGISTRY) --switch=$(SWITCH) --rank=-1
	opam install . --switch=$(SWITCH) --deps-only --with-test --with-dev-setup -y

build: ## build everything
	$(OPAM) dune build @all

test: ## run the tests
	$(OPAM) dune test --force

# Release is the profile opam installs with.
lint: ## check formatting, docs and the release build
	$(OPAM) dune build @all @fmt @doc
	$(OPAM) dune build --profile release @all

fmt: ## format the code
	$(OPAM) dune fmt

