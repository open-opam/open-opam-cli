(lang dune 3.18)
(name open-opam)

(implicit_transitive_deps false)

(generate_opam_files true)

(cram enable)

(source
 (github open-opam/open-opam-cli))

(maintainers "open-opam <dev@hyphatech.io>")

(authors "open-opam contributors")

(license MIT)

(package
 (name open-opam)
 (synopsis "Publish a GitHub release to the open-opam registry")
 (description
  "The checks a release must pass to enter the open-opam registry, the same for an author on their machine and for the registry's CI.")
 (depends
  (ocaml (>= 5.5))
  (cmdliner (>= 2.1.1))
  (digestif (>= 1.3.1))
  (dune-build-info (>= 3.18))
  (eio (>= 1.6))
  (eio_main (>= 1.6))
  (fmt (>= 0.9.0))
  (mtime (>= 2.0.0))
  (opam-file-format (>= 2.1.6))
  (ptime (>= 1.2.0))
  (wiretype (and (>= 0.7.0) (< 0.8.0)))
  (ppx_wiretype (and (>= 0.7.0) (< 0.8.0)))
  (progress (>= 0.5.0))
  (alcotest (and :with-test (>= 1.9.1)))
  (qcheck-alcotest (and :with-test (>= 0.91)))
  (qcheck-core (and :with-test (>= 0.91)))
  (merlin (and :with-dev-setup (>= 5.6-504)))
  (ocaml-lsp-server (and :with-dev-setup (>= 1.25.0)))
  (ocamlformat (and :with-dev-setup (= 0.29.0)))
  (odoc (and :with-dev-setup (>= 3.2.1)))))
