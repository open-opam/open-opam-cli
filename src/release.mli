(** Gates 2, 4 and 7, as pure functions of what was found. *)

val version_of_tag : string -> string
(** The tag with one leading [v] removed. *)

val valid_tag : string -> bool
(** Whether a tag can name a version. It reaches programs' arguments and paths,
    so a dash first, a slash or a space is refused before anything runs. *)

val valid_repository : string -> bool
(** Whether [owner/name] can name a GitHub repository. It reaches the same
    arguments and paths, so it is held to GitHub's characters first. *)

val is_archive : version:string -> string -> bool
(** Whether a file of this name would be taken for the release's archive. *)

val archives : version:string -> Github.asset list -> Github.asset list
(** The assets named [<name>-<version>.tar.gz] or [<name>-<version>.tbz]. A
    release is published from exactly one. *)

(** {1 Gate 2: release proof} *)

type facts = {
  repository : Github.repository;
  tag : string;
  commit : string;
  tag_object : string option;
      (** what the tag's ref names, when it leads to [commit]: the commit for a
          lightweight tag, the tag object for an annotated one, which is what
          GitHub attests *)
  release : Github.release;
  verification : Github.verification option;
      (** [None] when the release has no attestation, or [gh release verify]
          refused it *)
  asset_verified : bool;
  archive_sha256 : string option;  (** of the downloaded asset's bytes *)
}

type proof_problem =
  | Not_found of string
  | No_release of string  (** the tag *)
  | Invalid_tag of string
  | Invalid_repository of string
  | Draft
  | Not_immutable
  | Immutability_off
  | No_asset of string  (** the version *)
  | Several_archives of string list
  | Not_verified
  | Asset_not_verified
  | Attested_repository of { attested : string; actual : int }
  | Attested_commit of string
  | Asset_digest_differs
  | Attested_digest_differs

val proof_problem_code : proof_problem -> string
val proof_problem_to_string : proof_problem -> string
val check_proof : facts -> proof_problem list

(** {1 Gate 4: exact match} *)

type definition_problem =
  | Unreadable of { file : string; reason : string }
  | No_consent of string
  | Other_version of { file : string; stated : string; version : string }
  | Other_repository of { file : string; stated : string }
  | Own_url of string
  | Own_commit_hash of string
  | Not_generated of { path : string; line : int }
  | Missing_from_the_change of string

val definition_problem_code : definition_problem -> string
val definition_problem_to_string : definition_problem -> string

val check_definitions :
  repository:string ->
  version:string ->
  (string * string) list ->
  definition_problem list
(** Each [*.opam] file of a release: it offers itself here, states this version
    if any, names this repository, and carries no [url] or [x-commit-hash],
    which are the registry's to write. *)

val opam_file :
  source:string -> commit:string -> url:string -> sha256:string -> string
(** The registry's opam file for a package: its source, without dune's header
    comment, then the commit and the archive. It is a function of the release,
    so CI can write it again and compare. *)

val owner_record :
  repository:Github.repository -> claimed_at:Ptime.t -> (string, string) result
(** A new name's owners record. [claimed_at] is the release's, so that this too
    can be written again. *)

val release_of_opam_file : string -> (string * string) option
(** The repository and tag a registry opam file's [url] names, if it is a GitHub
    release asset. *)

val compare_generated :
  expected:(string * string) list ->
  actual:(string -> string option) ->
  definition_problem list
(** Every generated file against what a change holds, byte for byte. *)

(** {1 Gate 7: the author's CI} *)

type ci_problem =
  | No_checks
  | Still_running of string
  | Failed of { name : string; conclusion : string }
  | Nothing_succeeded
  | Not_pushed  (** GitHub does not have the commit *)

val ci_problem_code : ci_problem -> string
val ci_problem_to_string : ci_problem -> string

val check_ci :
  Github.check_run list -> Github.commit_status list -> ci_problem list
(** All of them, not one, since the registry cannot tell which runs the tests.
*)
