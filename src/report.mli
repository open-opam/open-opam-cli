(** What a run of the gates found: the one document the terminal's text and the
    CI check are written from. *)

type gate =
  | Allowed_files
  | Release_proof
  | Archive_equals_tag
  | Exact_match
  | Name_ownership
  | Metadata_and_standard
  | Author_ci

type problem = { code : string; message : string }
type outcome = { gate : gate; passed : bool; problems : problem list }
type t = { passed : bool; gates : outcome list } [@@deriving wiretype]

val outcome : gate -> problem list -> outcome
val of_outcomes : outcome list -> t

val gate_to_string : gate -> string
(** The gate's name, as a person reads it. *)

val problem_to_string : problem -> string
(** The problem's message, then its code. *)
