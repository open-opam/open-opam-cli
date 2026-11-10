(** Which repository official opam names for a package, by one rule that fails
    closed: no heuristic chooses between links. *)

type resolved =
  | Repository of string  (** [owner/name] on GitHub *)
  | Refused of string  (** why the metadata cannot name one *)

val resolve : string -> resolved
(** From the contents of a version's opam file. A GitHub [dev-repo], or with no
    [dev-repo] a GitHub release asset in [url]. Anything else is refused, as are
    two GitHub repositories that differ. *)

val github_repository : string -> string option
(** [owner/name] from a [dev-repo], in the ways opam spells one. *)

val compare_versions : string -> string -> int
(** opam's order: digits compare as numbers, and [~] sorts before everything,
    even the end of the version. *)

val latest : name:string -> string list -> string option
(** The newest of a package's version directories, [<name>.<version>]. *)
