The command says which release it is, so an author can match the gates they ran
to the release the registry's workflow names. Dune writes the version when it
installs the command, the release's own or git's in a checkout, so the build
tree the tests run has none to give:

  $ open-opam --version
  unknown

Every command answers it alike:

  $ open-opam revoke --version
  unknown
