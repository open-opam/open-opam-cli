let version_of_tag tag =
  match String.starts_with ~prefix:"v" tag with
  | true -> String.sub tag 1 (String.length tag - 1)
  | false -> tag

let valid_tag tag =
  (not (String.equal tag ""))
  && (not (String.starts_with ~prefix:"-" tag))
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '-' | '_' | '+' | '~' ->
             true
         | _ -> false)
       tag

(* GitHub's own rules: an owner is letters, digits and dashes, not first; a
   name adds dots and underscores, and is never . or .. *)
let valid_repository repository =
  let part ~more s =
    (not (String.equal s ""))
    && (not (String.starts_with ~prefix:"-" s))
    && String.for_all
         (function
           | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' -> true | c -> more c)
         s
  in
  match String.split_on_char '/' repository with
  | [ owner; name ] ->
      part ~more:(fun _ -> false) owner
      && part ~more:(function '.' | '_' -> true | _ -> false) name
      && (not (String.equal name "."))
      && not (String.equal name "..")
  | _ -> false

(* dune-release names the archive for the project and compresses it with
   bzip2; a release workflow of the author's own may name it for the
   repository. Either is the author's, so the name says only which asset. *)
let archive_suffixes = [ ".tar.gz"; ".tbz" ]

let is_archive ~version name =
  List.exists
    (fun suffix ->
      let ending = "-" ^ version ^ suffix in
      String.length name > String.length ending
      && String.ends_with ~suffix:ending name)
    archive_suffixes

let archives ~version (assets : Github.asset list) =
  List.filter (fun (a : Github.asset) -> is_archive ~version a.name) assets

type facts = {
  repository : Github.repository;
  tag : string;
  commit : string;
  tag_object : string option;
  release : Github.release;
  verification : Github.verification option;
  asset_verified : bool;
  archive_sha256 : string option;
}

type proof_problem =
  | Not_found of string
  | No_release of string
  | Invalid_tag of string
  | Invalid_repository of string
  | Draft
  | Not_immutable
  | Immutability_off
  | No_asset of string
  | Several_archives of string list
  | Not_verified
  | Asset_not_verified
  | Attested_repository of { attested : string; actual : int }
  | Attested_commit of string
  | Asset_digest_differs
  | Attested_digest_differs

let proof_problem_code = function
  | Not_found _ -> "not_found"
  | No_release _ -> "no_release"
  | Invalid_tag _ -> "invalid_tag"
  | Invalid_repository _ -> "invalid_repository"
  | Draft -> "draft"
  | Not_immutable -> "not_immutable"
  | Immutability_off -> "immutability_off"
  | No_asset _ -> "no_asset"
  | Several_archives _ -> "several_archives"
  | Not_verified -> "not_verified"
  | Asset_not_verified -> "asset_not_verified"
  | Attested_repository _ -> "attested_repository"
  | Attested_commit _ -> "attested_commit"
  | Asset_digest_differs -> "asset_digest_differs"
  | Attested_digest_differs -> "attested_digest_differs"

let proof_problem_to_string = function
  | Not_found what -> Printf.sprintf "%s was not found on GitHub." what
  | No_release tag ->
      Printf.sprintf
        "There is no release %s on GitHub: make it with open-opam release %s."
        tag tag
  | Invalid_tag tag -> Printf.sprintf "%s cannot name a version." tag
  | Invalid_repository repository ->
      Printf.sprintf "%s cannot name a GitHub repository." repository
  | Draft -> "The release is still a draft: publish it."
  | Not_immutable ->
      "The release is not immutable: turn on immutable releases, then make a \
       new release with its archive attached before it is published."
  | Immutability_off ->
      "Immutable releases are off for this repository: run open-opam init."
  | No_asset version ->
      Printf.sprintf
        "The release has no archive named <name>-%s.tar.gz or <name>-%s.tbz: \
         attach it while the release is a draft."
        version version
  | Several_archives names ->
      Printf.sprintf
        "The release has several archives, %s: it needs one, so that one is \
         what is published."
        (String.concat ", " names)
  | Not_verified -> "gh release verify refused the release."
  | Asset_not_verified -> "gh release verify-asset refused the archive."
  | Attested_repository { attested; actual } ->
      Printf.sprintf "The attestation names repository %s, and this is %d."
        attested actual
  | Attested_commit commit ->
      Printf.sprintf "The attestation does not name the tag's commit %s." commit
  | Asset_digest_differs ->
      "The asset's digest on GitHub is not the digest of its bytes."
  | Attested_digest_differs ->
      "The attestation does not name the digest of the archive's bytes."

let check_proof (f : facts) =
  let version = version_of_tag f.tag in
  let asset, asset_problems =
    match archives ~version f.release.assets with
    | [ asset ] -> (Some asset, [])
    | [] -> (None, [ No_asset version ])
    | several ->
        ( None,
          [
            Several_archives
              (List.map (fun (a : Github.asset) -> a.name) several);
          ] )
  in
  let statement =
    Option.map
      (fun (v : Github.verification) -> v.verification_result.statement)
      f.verification
  in
  let attested (select : Github.digests -> string option) wanted =
    match statement with
    | None -> false
    | Some (s : Github.statement) ->
        List.exists
          (fun (subject : Github.subject) ->
            match select subject.digest with
            | Some found -> String.equal found wanted
            | None -> false)
          s.subject
  in
  List.concat
    [
      (if f.release.draft then [ Draft ] else []);
      (if f.release.immutable then [] else [ Not_immutable ]);
      asset_problems;
      (match statement with
      | None -> [ Not_verified ]
      | Some s -> (
          let actual = f.repository.id in
          let attested_id = s.predicate.repository_id in
          (if String.equal attested_id (string_of_int actual) then []
           else [ Attested_repository { attested = attested_id; actual } ])
          @
          match f.tag_object with
          | Some named when attested (fun d -> d.sha1) named -> []
          | Some _ | None -> [ Attested_commit f.commit ]));
      (match (asset, f.archive_sha256) with
      | Some a, Some sha256 ->
          (if f.asset_verified then [] else [ Asset_not_verified ])
          @ (match a.digest with
            | Some digest when String.equal digest ("sha256:" ^ sha256) -> []
            | Some _ | None -> [ Asset_digest_differs ])
          @
          (* With no attestation, Not_verified has already said so. *)
          if Option.is_none statement || attested (fun d -> d.sha256) sha256
          then []
          else [ Attested_digest_differs ]
      | Some _, None | None, (Some _ | None) -> []);
    ]

type definition_problem =
  | Unreadable of { file : string; reason : string }
  | No_consent of string
  | Other_version of { file : string; stated : string; version : string }
  | Other_repository of { file : string; stated : string }
  | Own_url of string
  | Own_commit_hash of string
  | Not_generated of { path : string; line : int }
  | Missing_from_the_change of string

let definition_problem_code = function
  | Unreadable _ -> "unreadable_opam_file"
  | No_consent _ -> "no_consent"
  | Other_version _ -> "other_version"
  | Other_repository _ -> "other_repository"
  | Own_url _ -> "own_url"
  | Own_commit_hash _ -> "own_commit_hash"
  | Not_generated _ -> "not_generated"
  | Missing_from_the_change _ -> "missing_from_the_change"

let definition_problem_to_string = function
  | Unreadable { file; reason } ->
      Printf.sprintf "%s: cannot be read: %s." file reason
  | No_consent file ->
      Printf.sprintf
        "%s: needs x-open-opam: true, which is how a repository offers a \
         release here: run open-opam init."
        file
  | Other_version { file; stated; version } ->
      Printf.sprintf "%s: states version %s, and the tag is %s." file stated
        version
  | Other_repository { file; stated } ->
      Printf.sprintf "%s: its dev-repo is %s, not this repository." file stated
  | Own_url file ->
      Printf.sprintf "%s: has its own url, which the registry writes." file
  | Own_commit_hash file ->
      Printf.sprintf "%s: has its own x-commit-hash, which the registry writes."
        file
  | Not_generated { path; line } ->
      Printf.sprintf
        "%s: differs from what the release generates, first at line %d." path
        line
  | Missing_from_the_change path ->
      Printf.sprintf "%s: the release generates it, and the change lacks it."
        path

let same_repository a b =
  String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)

let check_definitions ~repository ~version files =
  List.concat_map
    (fun (file, contents) ->
      match Opam_file.of_string contents with
      | Error reason -> [ Unreadable { file; reason } ]
      | Ok opam ->
          let fields = Opam_file.fields opam in
          List.concat
            [
              (match Opam_file.bool_field opam "x-open-opam" with
              | Some true -> []
              | Some false | None -> [ No_consent file ]);
              (match Opam_file.string_field opam "version" with
              | Some stated when not (String.equal stated version) ->
                  [ Other_version { file; stated; version } ]
              | Some _ | None -> []);
              (match Opam_file.string_field opam "dev-repo" with
              | None -> []
              | Some stated -> (
                  match Official.github_repository stated with
                  | Some found when same_repository found repository -> []
                  | Some _ | None -> [ Other_repository { file; stated } ]));
              (if List.mem "url" fields then [ Own_url file ] else []);
              (if List.mem "x-commit-hash" fields then [ Own_commit_hash file ]
               else []);
            ])
    files

let dune_header = "# This file is generated by dune, edit dune-project instead"

let opam_file ~source ~commit ~url ~sha256 =
  let lines =
    List.filter
      (fun line -> not (String.equal line dune_header))
      (String.split_on_char '\n' source)
  in
  let body = String.concat "\n" lines in
  let body = if String.ends_with ~suffix:"\n" body then body else body ^ "\n" in
  Printf.sprintf "%sx-commit-hash: %S\nurl {\n  src: %S\n  checksum: %S\n}\n"
    body commit url ("sha256=" ^ sha256)

let owner_record ~(repository : Github.repository) ~claimed_at =
  let record : Records.owner =
    {
      github_repository_id = repository.id;
      repository = repository.full_name;
      status = Active;
      claimed_at;
    }
  in
  match Wiretype.encode Records.owner_json record with
  | Ok json -> Ok (json ^ "\n")
  | Error e -> Error (Wiretype.Unwritable.to_string e)

let first_different_line a b =
  let rec walk n = function
    | x :: xs, y :: ys when String.equal x y -> walk (n + 1) (xs, ys)
    | _ -> n
  in
  walk 1 (String.split_on_char '\n' a, String.split_on_char '\n' b)

let compare_generated ~expected ~actual =
  List.filter_map
    (fun (path, bytes) ->
      match actual path with
      | None -> Some (Missing_from_the_change path)
      | Some found when String.equal found bytes -> None
      | Some found ->
          Some (Not_generated { path; line = first_different_line bytes found }))
    expected

type ci_problem =
  | No_checks
  | Still_running of string
  | Failed of { name : string; conclusion : string }
  | Nothing_succeeded
  | Not_pushed

let ci_problem_code = function
  | No_checks -> "no_checks"
  | Still_running _ -> "still_running"
  | Failed _ -> "failed"
  | Nothing_succeeded -> "nothing_succeeded"
  | Not_pushed -> "not_pushed"

let ci_problem_to_string = function
  | No_checks ->
      "This commit has no CI result: run CI on pushes to the branch you \
       release from."
  | Still_running name ->
      Printf.sprintf "%s is still running: run this again once it has finished."
        name
  | Failed { name; conclusion } ->
      Printf.sprintf "%s finished as %s." name conclusion
  | Nothing_succeeded -> "No check on this commit succeeded."
  | Not_pushed ->
      "This commit is not on GitHub yet: push it, wait for its CI to pass, \
       then run this again."

let check_ci (runs : Github.check_run list)
    (statuses : Github.commit_status list) =
  let of_run (run : Github.check_run) =
    match (run.status, run.conclusion) with
    | Completed, Some (Success | Neutral | Skipped) -> []
    | Completed, Some (Other_conclusion conclusion) ->
        [ Failed { name = run.name; conclusion } ]
    | Completed, None -> [ Failed { name = run.name; conclusion = "nothing" } ]
    | Not_completed _, _ -> [ Still_running run.name ]
  in
  let of_status (s : Github.commit_status) =
    match s.state with
    | Success -> []
    | Pending -> [ Still_running s.context ]
    | Other_state state -> [ Failed { name = s.context; conclusion = state } ]
  in
  let succeeded =
    List.exists
      (fun (run : Github.check_run) ->
        match run.conclusion with
        | Some Success -> true
        | Some (Neutral | Skipped | Other_conclusion _) | None -> false)
      runs
    || List.exists
         (fun (s : Github.commit_status) ->
           match s.state with
           | Success -> true
           | Pending | Other_state _ -> false)
         statuses
  in
  match (runs, statuses) with
  | [], [] -> [ No_checks ]
  | _ ->
      let found =
        List.concat_map of_run runs @ List.concat_map of_status statuses
      in
      if (match found with [] -> true | _ :: _ -> false) && not succeeded then
        [ Nothing_succeeded ]
      else found

let release_of_opam_file contents =
  match Opam_file.of_string contents with
  | Error _ -> None
  | Ok opam -> (
      match Opam_file.section_string_field opam ~section:"url" "src" with
      | None -> None
      | Some src -> (
          match String.split_on_char '/' src with
          | [
           "https:";
           "";
           "github.com";
           owner;
           name;
           "releases";
           "download";
           tag;
           _;
          ]
            when valid_tag tag && valid_repository (owner ^ "/" ^ name) ->
              Some (owner ^ "/" ^ name, tag)
          | _ -> None))
