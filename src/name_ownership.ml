type official =
  | Not_official
  | Official_repository of { id : int; repository : string }
  | Official_refused of string

type fork = Not_a_fork | Fork_of of { original : string; names : string list }

type problem =
  | Official_elsewhere of { name : string; repository : string }
  | Official_unresolved of { name : string; reason : string }
  | Owned_by_another of { name : string; repository : string }
  | Disputed of string
  | Fork_of_the_original of {
      name : string;
      original : string;
      instead : string;
    }

let problem_code = function
  | Official_elsewhere _ -> "official_elsewhere"
  | Official_unresolved _ -> "official_unresolved"
  | Owned_by_another _ -> "owned_by_another"
  | Disputed _ -> "disputed"
  | Fork_of_the_original _ -> "fork_of_the_original"

let problem_to_string = function
  | Official_elsewhere { name; repository } ->
      Printf.sprintf
        "%s: official opam's %s comes from %s. A fork publishes under its own \
         name, or a consumer uses opam pin."
        name name repository
  | Official_unresolved { name; reason } ->
      Printf.sprintf "%s: official opam holds this name, and %s." name reason
  | Owned_by_another { name; repository } ->
      Printf.sprintf "%s: this name belongs to %s." name repository
  | Disputed name ->
      Printf.sprintf
        "%s: this name is disputed, so nothing new can publish under it." name
  | Fork_of_the_original { name; original; instead } ->
      Printf.sprintf
        "%s: this repository is a fork of %s, which publishes %s. A fork \
         publishes under its own name, such as %s."
        name original name instead

(* The fork's owner names it apart, as official opam's forks do. *)
let own_name ~repository ~name =
  match String.index_opt repository '/' with
  | Some i -> name ^ "-" ^ String.sub repository 0 i
  | None -> name ^ "-fork"

let check ~official ~(owner : Records.owner option) ~fork ~repository
    ~repository_id ~name =
  let official_problem =
    match official with
    | Not_official -> []
    | Official_refused reason -> [ Official_unresolved { name; reason } ]
    | Official_repository { id; repository } ->
        if id = repository_id then []
        else [ Official_elsewhere { name; repository } ]
  in
  let owner_problem =
    match owner with
    | None -> []
    | Some { status = Disputed; _ } -> [ Disputed name ]
    | Some { status = Active; github_repository_id; repository; _ } ->
        if github_repository_id = repository_id then []
        else [ Owned_by_another { name; repository } ]
  in
  (* Only a name nobody holds here yet: one the registry gave this repository
     is the maintainer's word that the fork may have it. *)
  let fork_problem =
    match (owner, fork) with
    | None, Fork_of { original; names } when List.mem name names ->
        [
          Fork_of_the_original
            { name; original; instead = own_name ~repository ~name };
        ]
    | None, (Fork_of _ | Not_a_fork) | Some _, (Fork_of _ | Not_a_fork) -> []
  in
  official_problem @ owner_problem @ fork_problem
