type resolved = Repository of string | Refused of string

let strip_prefix ~prefix s =
  if String.starts_with ~prefix s then
    let n = String.length prefix in
    Some (String.sub s n (String.length s - n))
  else None

let github_repository dev_repo =
  let path =
    List.find_map
      (fun prefix -> strip_prefix ~prefix dev_repo)
      [
        "git+https://github.com/";
        "https://github.com/";
        "git+ssh://git@github.com/";
        "git://github.com/";
        "git@github.com:";
      ]
  in
  Option.map
    (fun path ->
      if Filename.check_suffix path ".git" then Filename.chop_suffix path ".git"
      else path)
    path

let release_asset_repository src =
  match strip_prefix ~prefix:"https://github.com/" src with
  | None -> None
  | Some path -> (
      match String.split_on_char '/' path with
      | owner :: name :: "releases" :: "download" :: _ :: _ ->
          Some (owner ^ "/" ^ name)
      | _ -> None)

let same a b =
  String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)

let resolve contents =
  match Opam_file.of_string contents with
  | Error _ -> Refused "its opam file cannot be read"
  | Ok opam -> (
      let asset =
        Option.bind
          (Opam_file.section_string_field opam ~section:"url" "src")
          release_asset_repository
      in
      match Opam_file.string_field opam "dev-repo" with
      | Some dev_repo -> (
          match (github_repository dev_repo, asset) with
          | None, _ -> Refused "its dev-repo is not on GitHub"
          | Some repository, None -> Repository repository
          | Some repository, Some other ->
              if same repository other then Repository repository
              else
                Refused "its dev-repo and its url name different repositories")
      | None -> (
          match asset with
          | Some repository -> Repository repository
          | None -> Refused "its metadata names no GitHub repository"))

(* A character's rank among non-digits: tilde first, then the end of a part,
   then letters, then everything else. *)
let rank = function
  | '~' -> -1
  | ('a' .. 'z' | 'A' .. 'Z') as c -> Char.code c
  | c -> Char.code c + 256

let is_digit = function '0' .. '9' -> true | _ -> false

let compare_versions a b =
  let na = String.length a and nb = String.length b in
  let rec non_digits i j =
    let ca = if i < na && not (is_digit a.[i]) then Some a.[i] else None in
    let cb = if j < nb && not (is_digit b.[j]) then Some b.[j] else None in
    match (ca, cb) with
    | None, None -> digits i j
    | _ ->
        let ra = Option.fold ~none:0 ~some:rank ca
        and rb = Option.fold ~none:0 ~some:rank cb in
        if ra <> rb then Int.compare ra rb else non_digits (i + 1) (j + 1)
  and digits i j =
    if i >= na && j >= nb then 0
    else
      let skip s n k =
        let rec go k = if k < n && s.[k] = '0' then go (k + 1) else k in
        go k
      in
      let stop s n k =
        let rec go k = if k < n && is_digit s.[k] then go (k + 1) else k in
        go k
      in
      let ea = stop a na i and eb = stop b nb j in
      let sa = skip a ea i and sb = skip b eb j in
      let la = ea - sa and lb = eb - sb in
      if la <> lb then Int.compare la lb
      else
        let da = String.sub a sa la and db = String.sub b sb lb in
        let c = String.compare da db in
        if c <> 0 then c else non_digits ea eb
  in
  non_digits 0 0

let latest ~name directories =
  let prefix = name ^ "." in
  let versions =
    List.filter_map (fun d -> strip_prefix ~prefix d) directories
  in
  match versions with
  | [] -> None
  | first :: rest ->
      let newest =
        List.fold_left
          (fun best v -> if compare_versions v best > 0 then v else best)
          first rest
      in
      Some (prefix ^ newest)
