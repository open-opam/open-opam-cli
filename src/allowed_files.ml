type kind = File | Symlink | Submodule

type change =
  | Added of { path : string; kind : kind }
  | Changed of string
  | Deleted of string

type problem =
  | Nothing_added
  | Outside_the_publication_paths of string
  | Changes_what_exists of string
  | Deletes_what_exists of string
  | Not_a_regular_file of string
  | Differs_only_by_case of { path : string; existing : string }
  | Owner_without_a_package of string
  | More_than_one_version of string list
  | Publishes_and_revokes
  | Record_without_a_version of string

let problem_code = function
  | Nothing_added -> "nothing_added"
  | Outside_the_publication_paths _ -> "outside_the_publication_paths"
  | Changes_what_exists _ -> "changes_what_exists"
  | Deletes_what_exists _ -> "deletes_what_exists"
  | Not_a_regular_file _ -> "not_a_regular_file"
  | Differs_only_by_case _ -> "differs_only_by_case"
  | Owner_without_a_package _ -> "owner_without_a_package"
  | More_than_one_version _ -> "more_than_one_version"
  | Publishes_and_revokes -> "publishes_and_revokes"
  | Record_without_a_version _ -> "record_without_a_version"

let problem_to_string = function
  | Nothing_added -> "The pull request adds no package and no record."
  | Outside_the_publication_paths path ->
      Printf.sprintf
        "%s: a pull request may only add a package's opam file and owners \
         record, or a revocation or restoration record."
        path
  | Changes_what_exists path ->
      Printf.sprintf
        "%s: a publication may not change what is already published." path
  | Deletes_what_exists path ->
      Printf.sprintf "%s: a publication may not delete anything." path
  | Not_a_regular_file path ->
      Printf.sprintf "%s: a symlink or a submodule is not allowed." path
  | Differs_only_by_case { path; existing } ->
      Printf.sprintf "%s: differs only by case from %s." path existing
  | Owner_without_a_package name ->
      Printf.sprintf "%s: an owners record needs a package added beside it."
        name
  | More_than_one_version versions ->
      Printf.sprintf "One release is one version, and this adds %s."
        (String.concat ", " versions)
  | Publishes_and_revokes ->
      "A pull request publishes a release or revokes one, not both."
  | Record_without_a_version path ->
      Printf.sprintf "%s: the registry holds no such version." path

(* Git's modes for a symlink and a submodule; anything else it can track is a
   regular file. *)
let kind_of_mode = function
  | "120000" -> Symlink
  | "160000" -> Submodule
  | _ -> File

let of_raw_diff raw =
  (* With -z each entry is ":<old mode> <new mode> <old> <new> <status>", NUL,
     then the path, NUL. Without renames there is one path. *)
  let rec entries changes = function
    | [] | [ "" ] -> Ok (List.rev changes)
    | meta :: path :: rest -> (
        match String.split_on_char ' ' meta with
        | [ _old_mode; new_mode; _old; _new; status ] ->
            let change =
              match status with
              | "A" -> Ok (Added { path; kind = kind_of_mode new_mode })
              | "D" -> Ok (Deleted path)
              | "M" | "T" -> Ok (Changed path)
              | other ->
                  Error
                    (Printf.sprintf "git reported status %s for %s" other path)
            in
            Result.bind change (fun change -> entries (change :: changes) rest)
        | _ ->
            Error
              (Printf.sprintf "git reported an entry it should not: %s" meta))
    | [ entry ] -> Error (Printf.sprintf "git reported no path after: %s" entry)
  in
  entries [] (String.split_on_char '\000' raw)

let check ~existing changes =
  let lowered = List.map (fun p -> (String.lowercase_ascii p, p)) existing in
  let added =
    List.filter_map
      (function
        | Added { path; kind = File } -> Some path
        | Added { kind = Symlink | Submodule; _ } | Changed _ | Deleted _ ->
            None)
      changes
  in
  let allowed = List.filter_map Layout.of_path added in
  let packages =
    List.filter_map
      (function
        | Layout.Opam { name; _ } -> Some name | Owner _ | Record _ -> None)
      allowed
  in
  let records =
    List.filter_map
      (function
        | Layout.Record r -> Some (r.name, r.version) | Opam _ | Owner _ -> None)
      allowed
  in
  let versions =
    List.sort_uniq String.compare
      (List.filter_map
         (function
           | Layout.Opam { version; _ } | Record { version; _ } -> Some version
           | Owner _ -> None)
         allowed)
  in
  let per_change = function
    | Deleted path -> [ Deletes_what_exists path ]
    | Changed path -> [ Changes_what_exists path ]
    | Added { path; kind = Symlink | Submodule } -> [ Not_a_regular_file path ]
    | Added { path; kind = File } -> (
        let collision =
          match List.assoc_opt (String.lowercase_ascii path) lowered with
          | Some existing -> [ Differs_only_by_case { path; existing } ]
          | None -> []
        in
        match Layout.of_path path with
        | None -> Outside_the_publication_paths path :: collision
        | Some (Owner name) when not (List.mem name packages) ->
            Owner_without_a_package name :: collision
        | Some (Record { name; version; _ }) ->
            let opam = Layout.path (Opam { name; version }) in
            if List.mem opam existing then collision
            else Record_without_a_version path :: collision
        | Some (Owner _ | Opam _) -> collision)
  in
  let several =
    match versions with
    | [] | [ _ ] -> []
    | several -> [ More_than_one_version several ]
  in
  let shape =
    match (packages, records) with
    | [], [] -> [ Nothing_added ]
    | _ :: _, _ :: _ -> [ Publishes_and_revokes ]
    | _ :: _, [] | [], _ :: _ -> []
  in
  List.concat_map per_change changes @ several @ shape
