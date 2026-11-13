(** Where the registry keeps each of its files: the one place a path is written
    from what it holds, and read back. *)

type record =
  | Revocation  (** the version is refused *)
  | Restoration  (** its author took a revocation back *)

type file =
  | Opam of { name : string; version : string }
      (** [packages/<name>/<name>.<version>/opam] *)
  | Owner of string  (** [.open-opam/owners/<name>.json] *)
  | Record of { record : record; name : string; version : string }
      (** [.open-opam/revocations/<name>.<version>.json], or [restorations/] *)
  | Block of int
      (** [.open-opam/blocked/<account id>.json], the account's numeric GitHub
          ID *)

val path : file -> string

val of_path : string -> file option
(** The file a path is, when its name and version are made of the characters
    opam allows in them; [None] for any other path. *)
