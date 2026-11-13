let ( let* ) = Result.bind

type generated = {
  opam_files : (string * string) list;
  owner_records : (string * string) list;
}

type found = {
  version : string;
  commit : string;
  asset : string;
  sha256 : string;
  notes : string option;
  generated : generated;
}

type checked = { outcomes : Report.outcome list; found : found option }

type change = {
  registry : Eio.Fs.dir_ty Eio.Path.t;
  base : string;
  head : string;
}

let reported code message problems : Report.problem list =
  List.map
    (fun p : Report.problem -> { code = code p; message = message p })
    problems

let judged observe outcome =
  observe (Step.Judged outcome);
  outcome

let gate observe gate f =
  observe (Step.Started (Gate gate));
  let* outcome = f () in
  Ok (judged observe outcome)

let proof problems =
  Report.outcome Release_proof
    (reported Release.proof_problem_code Release.proof_problem_to_string
       problems)

let standard mgr source =
  let problems =
    reported Standard.problem_code Standard.problem_to_string
      (Standard.check source)
  in
  let rec lint found = function
    | [] -> Ok (List.rev found)
    | (file, contents) :: rest -> (
        let* problem = Tools.lint mgr ~file contents in
        match problem with
        | Some p -> lint (p :: found) rest
        | None -> lint found rest)
  in
  let* linted = lint [] (Standard.opam_files source) in
  Ok (Report.outcome Metadata_and_standard (problems @ linted))

let standard_of_archive mgr ~observe archive =
  gate observe Metadata_and_standard @@ fun () ->
  let* source = Tools.read_archive mgr archive in
  standard mgr source

let allowed_files mgr ~observe ~registry ~base ~head =
  gate observe Allowed_files @@ fun () ->
  let* existing = Tools.paths mgr ~registry ~at:base in
  let* changes = Tools.diff mgr ~registry ~base ~head in
  Ok
    (Report.outcome Allowed_files
       (reported Allowed_files.problem_code Allowed_files.problem_to_string
          (Allowed_files.check ~existing changes)))

let hex_sha256 ~fs path =
  match Eio.Path.load Eio.Path.(fs / path) with
  | bytes -> Ok (Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes))
  | exception Eio.Io _ -> Error (`Tool (Printf.sprintf "Cannot read %s." path))

let ci_problems mgr ~repository ~commit =
  (* GitHub answers 422 for a commit it does not have: one made and not yet
     pushed. *)
  let* answer =
    Tools.gh_or_refusal mgr
      ~refusals:[ "gh: No commit found for SHA" ]
      [
        "api";
        "--paginate";
        "--slurp";
        Printf.sprintf "repos/%s/commits/%s/check-runs?per_page=100" repository
          commit;
      ]
  in
  match answer with
  | Refused _ -> Ok [ Release.Not_pushed ]
  | Answered pages ->
      let* pages =
        Github.decode
          (Wiretype.list Github.check_runs_json)
          ~what:"the commit's checks" pages
      in
      let* status =
        Tools.gh mgr
          [
            "api"; Printf.sprintf "repos/%s/commits/%s/status" repository commit;
          ]
      in
      let* status =
        Github.decode Github.combined_status_json ~what:"the commit's status"
          status
      in
      let runs =
        List.concat_map (fun (p : Github.check_runs) -> p.check_runs) pages
      in
      Ok (Release.check_ci runs status.statuses)

type ci_wait = Judge_now | Wait_while_running of Eio.Time.Mono.ty Eio.Std.r

(* GitHub starts a pushed commit's checks within seconds, so a commit with none
   after a minute has no CI to wait for. *)
let checks_start_within = Mtime.Span.(1 * min)
let ask_again_after = Mtime.Span.(5 * s)

(* What the checks are still doing, if the verdict is not in yet. *)
let pending ~starting problems =
  let running =
    List.filter_map
      (function
        | Release.Still_running name -> Some name
        | No_checks | Failed _ | Nothing_succeeded | Not_pushed -> None)
      problems
  in
  match (problems, running) with
  | [], _ -> None
  | [ (No_checks | Not_pushed) ], _ when starting -> Some "its checks to start"
  | _, (_ :: _ as names) when List.length names = List.length problems ->
      Some (String.concat ", " names)
  | _ :: _, _ -> None

let ci mgr ~observe ~wait ~repository ~commit =
  let judged problems =
    Report.outcome Author_ci
      (reported Release.ci_problem_code Release.ci_problem_to_string problems)
  in
  match wait with
  | Judge_now ->
      let* problems = ci_problems mgr ~repository ~commit in
      Ok (judged problems)
  | Wait_while_running clock ->
      let started = Eio.Time.Mono.now clock in
      let rec ask () =
        let* problems = ci_problems mgr ~repository ~commit in
        let starting =
          Mtime.Span.compare
            (Mtime.span started (Eio.Time.Mono.now clock))
            checks_start_within
          < 0
        in
        match pending ~starting problems with
        | None -> Ok (judged problems)
        | Some what ->
            observe (Step.Started (Waiting_for what));
            Eio.Time.Mono.sleep_span clock ask_again_after;
            ask ()
      in
      ask ()

let generate ~(repository : Github.repository) ~version ~commit ~url ~sha256
    ~claimed_at source =
  let names_and_sources =
    List.map
      (fun (file, contents) -> (Filename.chop_suffix file ".opam", contents))
      (Standard.opam_files source)
  in
  let opam_files =
    List.map
      (fun (name, contents) ->
        ( Layout.path (Opam { name; version }),
          Release.opam_file ~source:contents ~commit ~url ~sha256 ))
      names_and_sources
  in
  let rec owners records = function
    | [] -> Ok (List.rev records)
    | (name, _) :: rest -> (
        match Release.owner_record ~repository ~claimed_at with
        | Ok bytes -> owners ((Layout.path (Owner name), bytes) :: records) rest
        | Error reason -> Error (`Tool reason))
  in
  let* owner_records = owners [] names_and_sources in
  Ok { opam_files; owner_records }

let compare_with_change mgr (change : change) generated =
  (* A name that already has its record keeps it, untouched. *)
  let rec fresh kept = function
    | [] -> Ok (List.rev kept)
    | ((path, _) as record) :: rest -> (
        let* existing =
          Tools.show mgr ~registry:change.registry ~at:change.base path
        in
        match existing with
        | Some _ -> fresh kept rest
        | None -> fresh (record :: kept) rest)
  in
  let* owners = fresh [] generated.owner_records in
  let expected = generated.opam_files @ owners in
  let rec read pairs = function
    | [] -> Ok (List.rev pairs)
    | (path, _) :: rest ->
        let* bytes =
          Tools.show mgr ~registry:change.registry ~at:change.head path
        in
        read ((path, bytes) :: pairs) rest
  in
  let* actual = read [] expected in
  let* changes =
    Tools.diff mgr ~registry:change.registry ~base:change.base ~head:change.head
  in
  let added =
    List.filter_map
      (function
        | Allowed_files.Added { path; kind = File } -> (
            match Layout.of_path path with
            | Some (Opam _ | Owner _) -> Some path
            | Some (Record _ | Block _) | None -> None)
        | Allowed_files.Added _ | Changed _ | Deleted _ -> None)
      changes
  in
  Ok
    (Release.compare_generated ~expected ~added ~actual:(fun path ->
         Option.join (List.assoc_opt path actual)))

(* What the registry holds now: a change is judged against its base, and an
   author's machine asks GitHub. *)
let read_registry mgr ~registry ~change path =
  match change with
  | Some (c : change) -> Tools.show mgr ~registry:c.registry ~at:c.base path
  | None ->
      Tools.gh_if_found mgr
        [
          "api";
          "-H";
          "Accept: application/vnd.github.raw+json";
          Printf.sprintf "repos/%s/contents/%s" registry path;
        ]

let official_of mgr name =
  let raw path =
    Tools.gh_if_found mgr
      [
        "api";
        "-H";
        "Accept: application/vnd.github.raw+json";
        Printf.sprintf "repos/ocaml/opam-repository/contents/packages/%s" path;
      ]
  in
  let* listing =
    Tools.gh_if_found mgr
      [
        "api";
        Printf.sprintf "repos/ocaml/opam-repository/contents/packages/%s" name;
      ]
  in
  match listing with
  | None -> Ok Name_ownership.Not_official
  | Some listing -> (
      let* entries =
        Github.decode
          (Wiretype.list Github.directory_entry_json)
          ~what:"official opam's versions" listing
      in
      let directories =
        List.map (fun (e : Github.directory_entry) -> e.name) entries
      in
      match Official.latest ~name directories with
      | None ->
          Ok (Name_ownership.Official_refused "it lists no version to read")
      | Some latest -> (
          let* opam = raw (Printf.sprintf "%s/%s/opam" name latest) in
          match opam with
          | None ->
              Ok
                (Name_ownership.Official_refused
                   "its latest version is unreadable")
          | Some opam -> (
              match Official.resolve opam with
              | Refused reason -> Ok (Name_ownership.Official_refused reason)
              | Repository repository -> (
                  let* found =
                    Tools.gh_if_found mgr
                      [ "api"; Printf.sprintf "repos/%s" repository ]
                  in
                  match found with
                  | None ->
                      Ok
                        (Name_ownership.Official_refused
                           (Printf.sprintf
                              "the repository it names, %s, no longer exists"
                              repository))
                  | Some found ->
                      let* found =
                        Github.decode Github.repository_json
                          ~what:"official's repository" found
                      in
                      Ok
                        (Name_ownership.Official_repository
                           { id = found.id; repository })))))

(* A fork's original publishes the names of the opam files at its root, as a
   release does. One GitHub can no longer show names none. *)
let fork_of mgr (repo : Github.repository) =
  match repo.parent with
  | None -> Ok Name_ownership.Not_a_fork
  | Some { full_name = original } ->
      let* listing =
        Tools.gh_if_found mgr
          [ "api"; Printf.sprintf "repos/%s/contents" original ]
      in
      let* names =
        match listing with
        | None -> Ok []
        | Some listing ->
            let* entries =
              Github.decode
                (Wiretype.list Github.directory_entry_json)
                ~what:"the original's files" listing
            in
            Ok
              (List.filter_map
                 (fun (e : Github.directory_entry) ->
                   if Filename.check_suffix e.name ".opam" then
                     Some (Filename.chop_suffix e.name ".opam")
                   else None)
                 entries)
      in
      Ok (Name_ownership.Fork_of { original; names })

let name_ownership mgr ~registry ~change ~(repo : Github.repository) names =
  let* fork = fork_of mgr repo in
  let rec each problems = function
    | [] -> Ok (List.rev problems)
    | name :: rest ->
        let path = Layout.path (Owner name) in
        let* text = read_registry mgr ~registry ~change path in
        let* owner =
          match text with
          | None -> Ok None
          | Some text ->
              let* owner = Records.decode Records.owner_json ~path text in
              Ok (Some owner)
        in
        let* official = official_of mgr name in
        let found =
          Name_ownership.check ~official ~owner ~fork ~repository:repo.full_name
            ~repository_id:repo.id ~name
        in
        each (List.rev_append found problems) rest
  in
  let* problems = each [] names in
  let path = Layout.path (Block repo.owner.id) in
  let* block = read_registry mgr ~registry ~change path in
  let* blocked =
    match block with
    | None -> Ok []
    | Some text ->
        let* (_ : Records.block) =
          Records.decode Records.block_json ~path text
        in
        Ok [ Name_ownership.Blocked { account = repo.owner.login; registry } ]
  in
  let problems = blocked @ problems in
  Ok
    (Report.outcome Name_ownership
       (reported Name_ownership.problem_code Name_ownership.problem_to_string
          problems))

(* Gates are judged in the order they are reported, so each can be shown as
   soon as it is known. *)
let with_archive mgr ~fs ~observe ~registry ~repository ~tag ~repo ~commit
    ~version ~asset ~sha256 ~notes ~claimed_at ~archive ~work ~change
    ~proof_outcome ~author_ci =
  let* archive_outcome =
    gate observe Archive_equals_tag @@ fun () ->
    let* difference =
      Tools.archive_differs_from_tag mgr ~fs ~repository ~tag ~archive ~work
    in
    Ok
      (Report.outcome Archive_equals_tag
         (match difference with
         | None -> []
         | Some first ->
             [
               {
                 code = "archive_differs";
                 message =
                   Printf.sprintf "The archive's files are not the tag's: %s"
                     first;
               };
             ]))
  in
  observe (Step.Started (Gate Exact_match));
  let* source = Tools.read_archive mgr archive in
  let definitions =
    Release.check_definitions ~repository ~version (Standard.opam_files source)
  in
  let url =
    Printf.sprintf "https://github.com/%s/releases/download/%s/%s" repository
      tag asset
  in
  let* generated =
    generate ~repository:repo ~version ~commit ~url ~sha256 ~claimed_at source
  in
  let* compared =
    match change with
    | None -> Ok []
    | Some change -> compare_with_change mgr change generated
  in
  let exact_outcome =
    judged observe
      (Report.outcome Exact_match
         (reported Release.definition_problem_code
            Release.definition_problem_to_string (definitions @ compared)))
  in
  let names =
    List.map
      (fun (file, _) -> Filename.chop_suffix file ".opam")
      (Standard.opam_files source)
  in
  let* name_outcome =
    gate observe Name_ownership @@ fun () ->
    name_ownership mgr ~registry ~change ~repo names
  in
  let* standard_outcome =
    gate observe Metadata_and_standard @@ fun () -> standard mgr source
  in
  let* ci_outcome = author_ci () in
  Ok
    {
      outcomes =
        [
          proof_outcome;
          archive_outcome;
          exact_outcome;
          name_outcome;
          standard_outcome;
          ci_outcome;
        ];
      found = Some { version; commit; asset; sha256; notes; generated };
    }

(* The tag's ref names the commit itself, or an annotated tag's object, whose
   hash covers the commit it points at. What it names is what GitHub attests,
   and it is the tag's object only when it leads to [commit]. *)
let tag_object mgr ~repository ~tag ~commit =
  let read path what =
    let* text =
      Tools.gh mgr [ "api"; Printf.sprintf "repos/%s/%s" repository path ]
    in
    Github.decode Github.git_ref_json ~what text
  in
  let* (named : Github.git_ref) =
    read ("git/ref/tags/" ^ tag) "the tag's ref"
  in
  let* leads =
    match named.object_.type_ with
    | Commit -> Ok (String.equal named.object_.sha commit)
    | Tag ->
        let* (peeled : Github.git_ref) =
          read ("git/tags/" ^ named.object_.sha) "the annotated tag"
        in
        Ok
          (match peeled.object_.type_ with
          | Commit -> String.equal peeled.object_.sha commit
          | Tag | Other_object _ -> false)
    | Other_object _ -> Ok false
  in
  Ok (named.object_.sha, if leads then Some named.object_.sha else None)

(* What gh release verify and verify-asset say when an attestation exists and
   does not hold, in gh 2.102's words. Whatever else they say is gh failing. *)
let attestation_refusals =
  [
    "no attestations found for release";
    "duplicate attestations found";
    "error parsing attestations";
    "failed to verify attestation";
    "attestation for ";
  ]

type downloaded = {
  asset : string;
  archive : string;
  sha256 : string;
  verified : bool;  (** by [gh release verify-asset] *)
}

let release mgr ~fs ~observe ~registry ~repository ~tag ~change =
  let invalid =
    (if Release.valid_repository repository then []
     else [ Release.Invalid_repository repository ])
    @ if Release.valid_tag tag then [] else [ Invalid_tag tag ]
  in
  if not (List.is_empty invalid) then
    Ok { outcomes = [ judged observe (proof invalid) ]; found = None }
  else
    Tools.with_temporary_directory mgr ~fs @@ fun work ->
    observe (Step.Started (Gate Release_proof));
    let api path = Printf.sprintf "repos/%s%s" repository path in
    let* repo = Tools.gh_if_found mgr [ "api"; api "" ] in
    let* found_release =
      Tools.gh_if_found mgr [ "api"; api ("/releases/tags/" ^ tag) ]
    in
    (* GitHub answers 422, not 404, for a tag that names no commit, so the
       commit is asked for only once the release shows the tag exists. *)
    let* commit =
      match found_release with
      | None -> Ok None
      | Some _ -> Tools.gh_if_found mgr [ "api"; api ("/commits/" ^ tag) ]
    in
    match (repo, found_release, commit) with
    | None, _, _ ->
        Ok
          {
            outcomes = [ judged observe (proof [ Not_found repository ]) ];
            found = None;
          }
    | Some _, None, _ | Some _, Some _, None ->
        Ok
          {
            outcomes = [ judged observe (proof [ No_release tag ]) ];
            found = None;
          }
    | Some repo, Some found_release, Some commit -> (
        let* repo =
          Github.decode Github.repository_json ~what:"the repository" repo
        in
        let* found_release =
          Github.decode Github.release_json ~what:"the release" found_release
        in
        let* commit =
          Github.decode Github.commit_json ~what:"the tag's commit" commit
        in
        let commit = commit.sha in
        let* named, tag_object = tag_object mgr ~repository ~tag ~commit in
        let version = Release.version_of_tag tag in
        let asset =
          match Release.archives ~version found_release.assets with
          | [ (a : Github.asset) ] -> Some a.name
          | [] | _ :: _ :: _ -> None
        in
        (* gh says "no attestations for tag" whenever it could not list them,
           so whether there are any is asked of GitHub, where none is a 404. *)
        let* attested =
          Tools.gh_if_found mgr
            [
              "api";
              api
                (Printf.sprintf "/attestations/sha1:%s?predicate_type=release"
                   named);
            ]
        in
        let verify args =
          match attested with
          | None -> Ok None
          | Some _ -> (
              let* answer =
                Tools.gh_or_refusal mgr ~refusals:attestation_refusals args
              in
              match answer with
              | Answered out -> Ok (Some out)
              | Refused _ -> Ok None)
        in
        let* verified =
          verify
            [ "release"; "verify"; tag; "-R"; repository; "--format"; "json" ]
        in
        let* verification =
          match verified with
          | None -> Ok None
          | Some json ->
              let* v =
                Github.decode Github.verification_json ~what:"the attestation"
                  json
              in
              Ok (Some v)
        in
        let* downloaded =
          match asset with
          | None -> Ok None
          | Some asset ->
              let archive = Filename.concat work asset in
              let* _ =
                Tools.gh mgr
                  [
                    "release";
                    "download";
                    tag;
                    "-R";
                    repository;
                    "-p";
                    asset;
                    "-D";
                    work;
                  ]
              in
              let* sha256 = hex_sha256 ~fs archive in
              let* answer =
                verify
                  [ "release"; "verify-asset"; tag; archive; "-R"; repository ]
              in
              Ok
                (Some
                   { asset; archive; sha256; verified = Option.is_some answer })
        in
        let archive_sha256 =
          Option.map (fun (d : downloaded) -> d.sha256) downloaded
        in
        let asset_verified =
          match downloaded with Some d -> d.verified | None -> false
        in
        let proof_outcome =
          judged observe
          @@ proof
               (Release.check_proof
                  {
                    repository = repo;
                    tag;
                    commit;
                    tag_object;
                    release = found_release;
                    verification;
                    asset_verified;
                    archive_sha256;
                  })
        in
        let author_ci () =
          gate observe Author_ci @@ fun () ->
          ci mgr ~observe ~wait:Judge_now ~repository ~commit
        in
        match (downloaded, found_release.published_at) with
        | None, _ | Some _, None ->
            let* ci_outcome = author_ci () in
            Ok { outcomes = [ proof_outcome; ci_outcome ]; found = None }
        | Some { asset; archive; sha256; verified = _ }, Some claimed_at ->
            with_archive mgr ~fs ~observe ~registry ~repository ~tag ~repo
              ~commit ~version ~asset ~sha256 ~notes:found_release.body
              ~claimed_at ~archive ~work ~change ~proof_outcome ~author_ci)

(* Each record is judged against the registry at the change's base, and the
   release its version names, as GitHub has it now. *)
let request mgr ~observe ~(change : change) records =
  let show at path = Tools.show mgr ~registry:change.registry ~at path in
  let decode_opt description path text =
    match text with
    | None -> Ok None
    | Some text ->
        let* value = Records.decode description ~path text in
        Ok (Some value)
  in
  observe (Step.Started (Gate Release_proof));
  let rec each found = function
    | [] -> Ok (List.concat (List.rev found))
    | (record, name, version, path) :: rest -> (
        let package = Printf.sprintf "%s.%s" name version in
        let* opam = show change.base (Layout.path (Opam { name; version })) in
        match (opam, Option.bind opam Release.release_of_opam_file) with
        | None, _ | _, None ->
            each ([ Revocation.Not_published package ] :: found) rest
        | Some opam, Some (repository, tag) -> (
            let release_name = Printf.sprintf "%s %s" repository tag in
            let* repo =
              Tools.gh_if_found mgr
                [ "api"; Printf.sprintf "repos/%s" repository ]
            in
            let* release =
              Tools.gh_if_found mgr
                [
                  "api";
                  Printf.sprintf "repos/%s/releases/tags/%s" repository tag;
                ]
            in
            match (repo, release) with
            | None, _ | _, None ->
                each ([ Revocation.No_release release_name ] :: found) rest
            | Some repo, Some release ->
                let* (repo : Github.repository) =
                  Github.decode Github.repository_json ~what:"the repository"
                    repo
                in
                let* (release : Github.release) =
                  Github.decode Github.release_json ~what:"the release" release
                in
                let owner_path = Layout.path (Owner name) in
                let* owner =
                  let* text = show change.base owner_path in
                  decode_opt Records.owner_json owner_path text
                in
                let owned =
                  match (owner : Records.owner option) with
                  | Some o when o.github_repository_id = repo.id -> []
                  | Some _ | None -> [ Revocation.Not_the_owner package ]
                in
                let revocation_path =
                  Layout.path (Record { record = Revocation; name; version })
                in
                let* revocation =
                  let* text = show change.base revocation_path in
                  decode_opt Records.revocation_json revocation_path text
                in
                let* restoration =
                  show change.base
                    (Layout.path
                       (Record { record = Restoration; name; version }))
                in
                let* text = show change.head path in
                let text = Option.value text ~default:"" in
                let state =
                  Revocation.state revocation
                    ~restored:(Option.is_some restoration)
                in
                let marked = Revocation.marked release.body in
                let problems =
                  match record with
                  | Layout.Revocation ->
                      (match state with
                        | Restored -> [ Revocation.Revoked_before package ]
                        | Live | Revoked _ -> [])
                      @ (if marked then []
                         else [ Revocation.Not_marked release_name ])
                      @ Revocation.check_revocation ~path ~repository ~tag text
                  | Restoration ->
                      (match state with
                        | Revoked Author_request -> []
                        | Revoked
                            (( Security | Legal | Gone | Malicious
                             | Official_conflict ) as reason) ->
                            [
                              Revocation.Revoked_by_the_registry
                                { package; reason };
                            ]
                        | Live | Restored -> [ Revocation.Not_revoked package ])
                      @ (if marked then [ Revocation.Still_marked release_name ]
                         else [])
                      @ (if Revocation.intact release ~opam then []
                         else [ Revocation.Asset_changed package ])
                      @ Revocation.check_restoration ~path ~repository ~tag text
                in
                each ((owned @ problems) :: found) rest))
  in
  let* problems = each [] records in
  (* Each problem is reported under the gate that judges what it is about: the
     release, the records, or the name. *)
  let proof, records, owner =
    List.fold_right
      (fun (p : Revocation.problem) (proof, records, owner) ->
        match p with
        | Not_published _ | No_release _ | Not_marked _ | Still_marked _
        | Asset_changed _ ->
            (p :: proof, records, owner)
        | Revoked_before _ | Not_revoked _ | Already_revoked _
        | Revoked_by_the_registry _ | Record_differs _ ->
            (proof, p :: records, owner)
        | Not_the_owner _ -> (proof, records, p :: owner))
      problems ([], [], [])
  in
  let outcome gate problems =
    judged observe
      (Report.outcome gate
         (reported Revocation.problem_code Revocation.problem_to_string problems))
  in
  let proof = outcome Release_proof proof in
  let exact = outcome Exact_match records in
  let owner = outcome Name_ownership owner in
  Ok [ proof; exact; owner ]

let change mgr ~fs ~observe ~registry ~change =
  let* allowed =
    allowed_files mgr ~observe ~registry:change.registry ~base:change.base
      ~head:change.head
  in
  let* changes =
    Tools.diff mgr ~registry:change.registry ~base:change.base ~head:change.head
  in
  let records =
    List.filter_map
      (function
        | Allowed_files.Added { path; kind = File } -> (
            match Layout.of_path path with
            | Some (Record { record; name; version }) ->
                Some (record, name, version, path)
            | Some (Opam _ | Owner _ | Block _) | None -> None)
        | Allowed_files.Added _ | Changed _ | Deleted _ -> None)
      changes
  in
  if not (List.is_empty records) then
    let* outcomes = request mgr ~observe ~change records in
    Ok (allowed :: outcomes)
  else
    let added =
      List.filter
        (fun path ->
          match Layout.of_path path with
          | Some (Opam _) -> true
          | Some (Owner _ | Record _ | Block _) | None -> false)
        (List.filter_map
           (function
             | Allowed_files.Added { path; kind = File } -> Some path
             | Allowed_files.Added _ | Changed _ | Deleted _ -> None)
           changes)
    in
    let rec sources found = function
      | [] -> Ok (List.rev found)
      | path :: rest ->
          let* text =
            Tools.show mgr ~registry:change.registry ~at:change.head path
          in
          let source = Option.bind text Release.release_of_opam_file in
          sources (source :: found) rest
    in
    let* found = sources [] added in
    let unknown what = judged observe (proof [ Release.Not_found what ]) in
    match found with
    | [] -> Ok [ allowed ]
    | first :: rest -> (
        let same = function
          | Some (r1, t1), Some (r2, t2) ->
              String.equal r1 r2 && String.equal t1 t2
          | None, _ | _, None -> false
        in
        if not (List.for_all (fun other -> same (first, other)) rest) then
          Ok [ allowed; unknown "One release behind every added opam file" ]
        else
          match first with
          | None ->
              Ok [ allowed; unknown "The release named by an added opam file" ]
          | Some (repository, tag) ->
              let* checked =
                release mgr ~fs ~observe ~registry ~repository ~tag
                  ~change:(Some change)
              in
              Ok (allowed :: checked.outcomes))

let before_release mgr ~observe ~registry ~repository ~version ~commit ~archive
    ~ci_wait =
  observe (Step.Started (Gate Release_proof));
  let* found =
    Tools.gh_if_found mgr [ "api"; Printf.sprintf "repos/%s" repository ]
  in
  match found with
  | None -> Ok [ judged observe (proof [ Not_found repository ]) ]
  | Some repo ->
      let* repo =
        Github.decode Github.repository_json ~what:"the repository" repo
      in
      let* immutability =
        Tools.gh mgr
          [ "api"; Printf.sprintf "repos/%s/immutable-releases" repository ]
      in
      let* immutability =
        Github.decode Github.immutability_json ~what:"immutable releases"
          immutability
      in
      let setup =
        judged observe
          (proof (if immutability.enabled then [] else [ Immutability_off ]))
      in
      observe (Step.Started (Gate Exact_match));
      let* source = Tools.read_archive mgr archive in
      let definitions =
        judged observe
          (Report.outcome Exact_match
             (reported Release.definition_problem_code
                Release.definition_problem_to_string
                (Release.check_definitions ~repository ~version
                   (Standard.opam_files source))))
      in
      let names =
        List.map
          (fun (file, _) -> Filename.chop_suffix file ".opam")
          (Standard.opam_files source)
      in
      let* names =
        gate observe Name_ownership @@ fun () ->
        name_ownership mgr ~registry ~change:None ~repo names
      in
      let* standard =
        gate observe Metadata_and_standard @@ fun () -> standard mgr source
      in
      let* ci =
        gate observe Author_ci @@ fun () ->
        ci mgr ~observe ~wait:ci_wait ~repository ~commit
      in
      Ok [ setup; definitions; names; standard; ci ]
