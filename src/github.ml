type asset = {
  name : string;
  digest : string option;
  browser_download_url : string;
}
[@@deriving wiretype]

type release = {
  tag_name : string;
  draft : bool;
  immutable : bool;
  published_at : Ptime.t option;
  body : string option;
  assets : asset list;
}
[@@deriving wiretype]

type parent = { full_name : string } [@@deriving wiretype]

(* GitHub sends a parent only for a fork. *)
type repository = {
  id : int;
  full_name : string;
  created_at : Ptime.t;
  parent : parent option; [@default None]
}
[@@deriving wiretype]

type commit = { sha : string } [@@deriving wiretype]

(* GitHub adds words to these sets, so a word it has not documented is kept for
   the code to judge, never a reason the answer cannot be read. *)
let words parse = Wiretype.map ~parse Wiretype.string

type object_type = Commit | Tag | Other_object of string

let object_type_json =
  words (function
    | "commit" -> Commit
    | "tag" -> Tag
    | other -> Other_object other)

type git_object = {
  sha : string;
  type_ : object_type; [@key "type"] [@with object_type_json]
}
[@@deriving wiretype]

type git_ref = { object_ : git_object [@key "object"] } [@@deriving wiretype]
type directory_entry = { name : string } [@@deriving wiretype]
type immutability = { enabled : bool } [@@deriving wiretype]
type run_status = Completed | Not_completed of string

let run_status_json =
  words (function "completed" -> Completed | other -> Not_completed other)

type conclusion = Success | Neutral | Skipped | Other_conclusion of string

let conclusion_json =
  words (function
    | "success" -> Success
    | "neutral" -> Neutral
    | "skipped" -> Skipped
    | other -> Other_conclusion other)

type check_run = {
  name : string;
  status : run_status; [@with run_status_json]
  conclusion : conclusion option; [@with conclusion_json]
}
[@@deriving wiretype]

type check_runs = { check_runs : check_run list } [@@deriving wiretype]
type state = Success | Pending | Other_state of string

let state_json =
  words (function
    | "success" -> Success
    | "pending" -> Pending
    | other -> Other_state other)

type commit_status = { context : string; state : state [@with state_json] }
[@@deriving wiretype]

type combined_status = { statuses : commit_status list } [@@deriving wiretype]

type digests = { sha1 : string option; sha256 : string option }
[@@deriving wiretype]

type subject = { digest : digests } [@@deriving wiretype]

(* GitHub writes this number as text. *)
type predicate = { repository_id : string [@key "repositoryId"] }
[@@deriving wiretype]

type statement = { subject : subject list; predicate : predicate }
[@@deriving wiretype]

type verification_result = { statement : statement } [@@deriving wiretype]

type verification = {
  verification_result : verification_result; [@key "verificationResult"]
}
[@@deriving wiretype]

type pull_request = { html_url : string } [@@deriving wiretype]

type open_pull_request = { title : string; url : string; body : string }
[@@deriving wiretype]

let decode description ~what text =
  match Wiretype.decode description text with
  | Ok value -> Ok value
  | Error problems ->
      Error
        (`Tool
           (Printf.sprintf "GitHub's answer for %s could not be read: %s" what
              (String.concat "; "
                 (List.map Wiretype.Problem.to_string problems))))

type release_view = { is_draft : bool [@key "isDraft"] } [@@deriving wiretype]
