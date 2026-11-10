(** The registry's records under [.open-opam/], one description each for what
    reads them, writes them and prints their JSON Schema. *)

type status = Active | Disputed

type owner = {
  github_repository_id : int;
      (** the identity; it survives a rename and a transfer *)
  repository : string;  (** a display name, [owner/name] *)
  status : status;  (** {!Disputed} blocks new publications *)
  claimed_at : Ptime.t;
}
[@@deriving wiretype]

type reason =
  | Security
  | Legal
  | Author_request
  | Upstream_gone
  | Official_conflict

type revocation = {
  reason : reason;
  actor : string;  (** who revoked it *)
  evidence : string;  (** a link to what shows why *)
  revoked_at : Ptime.t;
}
[@@deriving wiretype]
(** [revocations/<name>.<version>.json]: the version is refused. *)

type restoration = {
  actor : string;  (** who restored it *)
  evidence : string;  (** a link to what shows why *)
  restored_at : Ptime.t;
}
[@@deriving wiretype]
(** [restorations/<name>.<version>.json]: its author took a revocation back. *)

val decode :
  'a Wiretype.t -> path:string -> string -> ('a, [> `Tool of string ]) result
(** A record the registry holds at [path]. One that cannot be read is the
    registry's to mend: the run fails, and no release is refused for it. *)
