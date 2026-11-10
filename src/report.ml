type gate =
  | Allowed_files [@name "allowed-files"]
  | Release_proof [@name "release-proof"]
  | Archive_equals_tag [@name "archive-equals-tag"]
  | Exact_match [@name "exact-match"]
  | Name_ownership [@name "name-ownership"]
  | Metadata_and_standard [@name "metadata-and-standard"]
  | Author_ci [@name "author-ci"]
[@@deriving wiretype]

type problem = { code : string; message : string } [@@deriving wiretype]

type outcome = { gate : gate; passed : bool; problems : problem list }
[@@deriving wiretype]

type t = { passed : bool; gates : outcome list } [@@deriving wiretype]

let outcome gate problems =
  {
    gate;
    passed = (match problems with [] -> true | _ :: _ -> false);
    problems;
  }

let of_outcomes gates =
  { passed = List.for_all (fun (o : outcome) -> o.passed) gates; gates }

let gate_to_string = function
  | Allowed_files -> "Allowed files"
  | Release_proof -> "Release proof"
  | Archive_equals_tag -> "Archive equals tag"
  | Exact_match -> "Exact match"
  | Name_ownership -> "Name ownership"
  | Metadata_and_standard -> "Metadata and standard"
  | Author_ci -> "Author's CI"

let problem_to_string p = Printf.sprintf "%s [%s]" p.message p.code
