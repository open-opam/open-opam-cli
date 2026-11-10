let ( let* ) = Result.bind

type package = {
  name : string;
  versions : (string * Revocation.state) list;
  owner : string option;
}

type t = { packages : package list; waiting : (string * string) list }

(* A pull request merges by itself once the registry's checks pass, so few are
   open at once; this many, newest first, is every one of them. *)
let open_pull_requests_read = 200

let raw mgr ~registry path =
  Tools.gh_if_found mgr
    [
      "api";
      "-H";
      "Accept: application/vnd.github.raw+json";
      Printf.sprintf "repos/%s/contents/%s" registry path;
    ]

let entries mgr path =
  let* listing = Tools.gh_if_found mgr [ "api"; path ] in
  match listing with
  | None -> Ok []
  | Some listing ->
      let* entries =
        Github.decode
          (Wiretype.list Github.directory_entry_json)
          ~what:path listing
      in
      Ok (List.map (fun (e : Github.directory_entry) -> e.name) entries)

let package mgr ~registry ~(repo : Github.repository) name =
  let path = Layout.path (Owner name) in
  let* owner = raw mgr ~registry path in
  match owner with
  | None -> Ok { name; versions = []; owner = None }
  | Some text ->
      let* (owner : Records.owner) =
        Records.decode Records.owner_json ~path text
      in
      if owner.github_repository_id <> repo.id then
        Ok { name; versions = []; owner = Some owner.repository }
      else
        let* directories =
          entries mgr
            (Printf.sprintf "repos/%s/contents/packages/%s" registry name)
        in
        let prefix = name ^ "." in
        let versions =
          List.filter_map
            (fun d ->
              if String.starts_with ~prefix d then
                let n = String.length prefix in
                Some (String.sub d n (String.length d - n))
              else None)
            directories
          |> List.sort Official.compare_versions
        in
        let rec each found = function
          | [] -> Ok (List.rev found)
          | version :: rest ->
              let path =
                Layout.path (Record { record = Revocation; name; version })
              in
              let* revocation = raw mgr ~registry path in
              let* revocation =
                match revocation with
                | None -> Ok None
                | Some text ->
                    let* record =
                      Records.decode Records.revocation_json ~path text
                    in
                    Ok (Some record)
              in
              let* restored =
                raw mgr ~registry
                  (Layout.path (Record { record = Restoration; name; version }))
              in
              let state =
                Revocation.state revocation ~restored:(Option.is_some restored)
              in
              each ((version, state) :: found) rest
        in
        let* versions = each [] versions in
        Ok { name; versions; owner = None }

let of_repository mgr ~registry ~repository =
  let* repo = Tools.gh mgr [ "api"; Printf.sprintf "repos/%s" repository ] in
  let* repo =
    Github.decode Github.repository_json ~what:"the repository" repo
  in
  let* files = entries mgr (Printf.sprintf "repos/%s/contents" repository) in
  let names =
    List.filter_map
      (fun file ->
        if Filename.check_suffix file ".opam" then
          Some (Filename.chop_suffix file ".opam")
        else None)
      files
  in
  let rec each found = function
    | [] -> Ok (List.rev found)
    | name :: rest ->
        let* p = package mgr ~registry ~repo name in
        each (p :: found) rest
  in
  let* packages = each [] names in
  let* pulls =
    Tools.gh mgr
      [
        "pr";
        "list";
        "-R";
        registry;
        "--state";
        "open";
        "--limit";
        string_of_int open_pull_requests_read;
        "--json";
        "title,url,body";
      ]
  in
  let* pulls =
    Github.decode
      (Wiretype.list Github.open_pull_request_json)
      ~what:"the open pull requests" pulls
  in
  (* publish and revoke write the release on a line of the body, while a branch
     name is shared by every repository of the same name. *)
  let release_line =
    String.lowercase_ascii
      (Printf.sprintf "Release: https://github.com/%s/releases/tag/" repository)
  in
  let ours (p : Github.open_pull_request) =
    List.exists
      (fun line ->
        String.starts_with ~prefix:release_line (String.lowercase_ascii line))
      (String.split_on_char '\n' p.body)
  in
  let waiting =
    List.filter_map
      (fun (p : Github.open_pull_request) ->
        if ours p then Some (p.title, p.url) else None)
      pulls
  in
  Ok { packages; waiting }
