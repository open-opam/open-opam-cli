(** Gate 1: a pull request only adds one release's files, or its records.

    A publication of [foo 1.2.3] adds [packages/foo/foo.1.2.3/opam], and
    [.open-opam/owners/foo.json] the first time [foo] is published. Anything
    else in a pull request is how a change to the registry's rules, or to
    someone else's package, would hide inside a release. A revocation adds
    [.open-opam/revocations/foo.1.2.3.json], and a restoration
    [.open-opam/restorations/foo.1.2.3.json], each for a version already
    published; neither changes a file, so either can come from any fork. *)

type kind = File | Symlink | Submodule

type change =
  | Added of { path : string; kind : kind }
  | Changed of string  (** modified, or its type changed *)
  | Deleted of string

type problem =
  | Nothing_added
  | Outside_the_publication_paths of string
  | Changes_what_exists of string
  | Deletes_what_exists of string
  | Not_a_regular_file of string
  | Differs_only_by_case of { path : string; existing : string }
  | Owner_without_a_package of string  (** the name *)
  | More_than_one_version of string list
  | Publishes_and_revokes
  | Record_without_a_version of string  (** the record's path *)

val problem_code : problem -> string
val problem_to_string : problem -> string

val of_raw_diff : string -> (change list, string) result
(** Reads [git diff --raw --no-renames -z]. [Error] says what could not be read,
    since a diff half understood must not pass. *)

val check : existing:string list -> change list -> problem list
(** [existing] is every path already in the registry. No problems means the
    changes are one release's files, or one release's records, and nothing else.
*)
