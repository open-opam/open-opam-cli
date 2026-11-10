(** Revoking a published version, and restoring it, by its author.

    Both are pull requests that only add a record, so they come from any fork,
    as a publication does: [.open-opam/revocations/foo.1.2.3.json] revokes,
    [.open-opam/restorations/foo.1.2.3.json] restores. The proof the author asks
    is on the release: its notes say {!mark} to revoke, and no longer say it to
    restore, and only someone who can write to the repository can change them.
    Once merged, the registry's own workflow makes the opam file match. *)

val mark : string
(** The line a revoked release's notes hold. *)

val marked : string option -> bool
(** Whether notes hold {!mark} as a line of their own. *)

val with_mark : string option -> string
val without_mark : string option -> string

type state =
  | Live
  | Revoked of Records.reason
  | Restored  (** revoked by its author, then restored *)

val state : Records.revocation option -> restored:bool -> state
val release_url : repository:string -> tag:string -> string

val intact : Github.release -> opam:string -> bool
(** Whether the release still holds the archive the opam file's checksum names.
*)

type problem =
  | Not_published of string  (** [name.version] *)
  | No_release of string  (** [owner/name tag] *)
  | Not_the_owner of string
  | Not_marked of string
  | Still_marked of string
  | Asset_changed of string
  | Revoked_before of string
  | Not_revoked of string
  | Already_revoked of string
  | Revoked_by_the_registry of { package : string; reason : Records.reason }
  | Record_differs of { path : string; expected : string }

val problem_code : problem -> string
val problem_to_string : problem -> string

val author_revocation :
  repository:string -> tag:string -> now:Ptime.t -> Records.revocation

val author_restoration :
  repository:string -> tag:string -> now:Ptime.t -> Records.restoration

val check_revocation :
  path:string -> repository:string -> tag:string -> string -> problem list
(** An author's revocation record holds [author-request], its repository as the
    actor and its release as the evidence. Its time is the author's. *)

val check_restoration :
  path:string -> repository:string -> tag:string -> string -> problem list
