(** GitHub's answers, validated where they enter. *)

type asset = {
  name : string;
  digest : string option;  (** [sha256:<hex>] *)
  browser_download_url : string;
}
[@@deriving wiretype]

type release = {
  tag_name : string;
  draft : bool;
  immutable : bool;
  published_at : Ptime.t option;
  body : string option;  (** the release's notes *)
  assets : asset list;
}
[@@deriving wiretype]

type parent = { full_name : string } [@@deriving wiretype]

type repository = {
  id : int;
  full_name : string;
  created_at : Ptime.t;
  parent : parent option;
      (** the repository this one was forked from, for a fork only *)
}
[@@deriving wiretype]

type commit = { sha : string } [@@deriving wiretype]

(** A word GitHub has not documented is kept, in its [Other] case, rather than
    refused: GitHub adds words, and the code judges what it does not know. *)

type object_type = Commit | Tag | Other_object of string

type git_object = {
  sha : string;
  type_ : object_type;  (** [Tag] for an annotated tag's object *)
}

type git_ref = {
  object_ : git_object;  (** what a tag's ref, or an annotated tag, names *)
}
[@@deriving wiretype]

type directory_entry = { name : string } [@@deriving wiretype]
type immutability = { enabled : bool } [@@deriving wiretype]
type run_status = Completed | Not_completed of string  (** [queued], … *)

type conclusion =
  | Success
  | Neutral
  | Skipped
  | Other_conclusion of string  (** [failure], [cancelled], … *)

type check_run = {
  name : string;
  status : run_status;
  conclusion : conclusion option;
}

type check_runs = { check_runs : check_run list } [@@deriving wiretype]

type state =
  | Success
  | Pending
  | Other_state of string  (** [failure], [error], … *)

type commit_status = { context : string; state : state }
type combined_status = { statuses : commit_status list } [@@deriving wiretype]
type digests = { sha1 : string option; sha256 : string option }
type subject = { digest : digests }
type predicate = { repository_id : string }
type statement = { subject : subject list; predicate : predicate }
type verification_result = { statement : statement }

type verification = { verification_result : verification_result }
[@@deriving wiretype]
(** What [gh release verify --format json] prints. *)

type pull_request = { html_url : string } [@@deriving wiretype]

type open_pull_request = { title : string; url : string; body : string }
[@@deriving wiretype]
(** What [gh pr list --json title,url,body] lists. *)

val decode :
  'a Wiretype.t -> what:string -> string -> ('a, [> `Tool of string ]) result
(** One of GitHub's answers, read by its description. [what] names it in the
    error, which is the run failing, never a release refused. *)

type release_view = { is_draft : bool } [@@deriving wiretype]
(** What [gh release view --json isDraft] prints. *)
