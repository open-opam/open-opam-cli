type status = Active | Disputed [@@deriving wiretype]

type owner = {
  github_repository_id : int;
  repository : string;
  status : status;
  claimed_at : Ptime.t;
}
[@@deriving wiretype]

type reason =
  | Security
  | Legal
  | Author_request [@name "author-request"]
  | Upstream_gone [@name "upstream-gone"]
  | Official_conflict [@name "official-conflict"]
[@@deriving wiretype]

type revocation = {
  reason : reason;
  actor : string;
  evidence : string;
  revoked_at : Ptime.t;
}
[@@deriving wiretype]

type restoration = { actor : string; evidence : string; restored_at : Ptime.t }
[@@deriving wiretype]

let decode description ~path text =
  match Wiretype.decode description text with
  | Ok value -> Ok value
  | Error problems ->
      Error
        (`Tool
           (Printf.sprintf "The registry's %s could not be read: %s" path
              (String.concat "; "
                 (List.map Wiretype.Problem.to_string problems))))
