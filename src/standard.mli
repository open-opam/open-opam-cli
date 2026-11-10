(** Gate 6: what a machine can hold every release to.

    Its input is a release's source: every path in it, and the contents of the
    files this gate reads ({!reads}). It does no I/O, so {!Tools.read_archive}
    or a test can give it a tree. *)

type source = (string * string) list
(** Each path, relative to the project's root, and its contents when {!reads}
    asked for them; the empty string otherwise. *)

val reads : string -> bool
(** Whether the gate needs this path's contents. *)

type problem =
  | No_opam_file
  | Unreadable_opam_file of { file : string; reason : string }
  | Missing_field of { file : string; field : string }
  | Refused_field of { file : string; field : string }
  | No_dune_project
  | No_readme
  | Empty_readme of string
  | No_interface
  | No_test

val problem_code : problem -> string
val problem_to_string : problem -> string

val opam_files : source -> (string * string) list
(** The [*.opam] files at the root, each file's name and contents. *)

val check : source -> problem list
