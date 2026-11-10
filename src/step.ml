type t =
  | Gate of Report.gate
  | Archive of string
  | Tag of { tag : string; repository : string }
  | Release of { tag : string; repository : string }
  | Registry of string
  | Fork of string
  | Branch of { fork : string; branch : string }
  | Pull_request of string
  | Immutable_releases of string
  | Offer of string
  | Commit of string
  | Push of string
  | Waiting_for of string

type event = Started of t | Finished of t | Judged of Report.outcome

let to_string = function
  | Gate gate -> Report.gate_to_string gate
  | Archive name -> Printf.sprintf "Archive %s of this commit" name
  | Tag { tag; repository } -> Printf.sprintf "Tag %s on %s" tag repository
  | Release { tag; repository } ->
      Printf.sprintf "Release %s of %s, with its archive" tag repository
  | Registry registry -> Printf.sprintf "Registry %s" registry
  | Fork registry -> Printf.sprintf "Your fork of %s" registry
  | Branch { fork; branch } -> Printf.sprintf "Branch %s on %s" branch fork
  | Pull_request registry -> Printf.sprintf "Pull request on %s" registry
  | Immutable_releases repository ->
      Printf.sprintf "Immutable releases on %s" repository
  | Offer file -> Printf.sprintf "x-open-opam: true in %s" file
  | Commit subject -> Printf.sprintf "Commit \"%s\"" subject
  | Push remote -> Printf.sprintf "Push this commit to %s" remote
  | Waiting_for what -> Printf.sprintf "Author's CI, waiting for %s" what
