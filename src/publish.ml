let ( let* ) = Result.bind

type pull_request = Opened of string | Already_open of string

type outcome =
  | Proposed of pull_request
  | Already_published
  | Published_differently of string

(* gh is the credential: the author is signed in there, and this holds none. *)
let push_args url branch =
  [
    "-c";
    "credential.helper=";
    "-c";
    "credential.helper=!gh auth git-credential";
    "push";
    "--quiet";
    (* The branch is this release's alone and is written from it, so another
       run's commit on it is replaced, never merged. *)
    "--force";
    url;
    "HEAD:refs/heads/" ^ branch;
  ]

let packages (found : Gates.found) =
  List.filter_map
    (fun (path, bytes) ->
      match Layout.of_path path with
      | Some (Owner _ | Record _) | None -> None
      | Some (Opam { name; _ }) ->
          let synopsis =
            match Opam_file.of_string bytes with
            | Ok opam -> Opam_file.string_field opam "synopsis"
            | Error _ -> None
          in
          Some (name, synopsis))
    found.generated.opam_files

let subject ~repository found =
  match packages found with
  | [ (name, _) ] -> name
  | [] | _ :: _ :: _ -> Filename.basename repository

let title ~repository (found : Gates.found) =
  Printf.sprintf "Publish %s %s" (subject ~repository found) found.version

(* A synopsis is the author's text, so it is kept to one line and one cell. *)
let cell text =
  String.concat "\\|"
    (String.split_on_char '|'
       (String.concat " " (String.split_on_char '\n' text)))

let body ~repository ~tag (found : Gates.found) =
  let name = subject ~repository found in
  let summary =
    match packages found with
    | [ (_, Some synopsis) ] ->
        [ Printf.sprintf "**%s %s**: %s" name found.version (cell synopsis) ]
    | [ (_, None) ] | [] -> [ Printf.sprintf "**%s %s**" name found.version ]
    | _ :: _ :: _ as packages ->
        Printf.sprintf "**%s %s**" name found.version
        :: "" :: "| Package | Synopsis |" :: "|---|---|"
        :: List.map
             (fun (package, synopsis) ->
               Printf.sprintf "| %s | %s |" package
                 (cell (Option.value synopsis ~default:"")))
             packages
  in
  let notes =
    match Option.map String.trim found.notes with
    | None | Some "" -> []
    | Some notes -> [ ""; notes ]
  in
  String.concat "\n"
    (summary @ notes
    @ [
        "";
        Printf.sprintf "Release: https://github.com/%s/releases/tag/%s"
          repository tag;
        Printf.sprintf "Commit: `%s`" found.commit;
        Printf.sprintf "Asset: `%s`" found.asset;
        Printf.sprintf "SHA-256: `%s`" found.sha256;
      ])

type held = All_held | Some_missing | Held_differently of string

let write ~dir (path, bytes) =
  let file = Eio.Path.(dir / path) in
  match
    Option.iter
      (fun (parent, _) -> Eio.Path.mkdirs ~exists_ok:true ~perm:0o755 parent)
      (Eio.Path.split file);
    Eio.Path.save ~create:(`Or_truncate 0o644) file bytes
  with
  | () -> Ok ()
  | exception (Eio.Io _ as e) ->
      Error
        (`Tool
           (Printf.sprintf "%s cannot be written in the registry's clone: %s."
              path (Tools.io_reason e)))

let rec write_all ~dir = function
  | [] -> Ok ()
  | file :: rest ->
      let* () = write ~dir file in
      write_all ~dir rest

let step observe step f =
  observe (Step.Started step);
  let* value = f () in
  observe (Step.Finished step);
  Ok value

let clone mgr ~observe ~registry ~work =
  let clone = Filename.concat work "registry" in
  let* _ =
    step observe (Registry registry) @@ fun () ->
    Tools.gh mgr
      (* Every commit and only the needed files: small as the registry grows,
         and a shallow clone's push can be refused. *)
      [
        "repo"; "clone"; registry; clone; "--"; "--quiet"; "--filter=blob:none";
      ]
  in
  Ok clone

(* One pull request from the author's fork, adding [files]: a branch has one
   pull request, so running it again finds the one already open. *)
let propose mgr ~fs ~observe ~registry ~clone ~branch ~title ~body ~files =
  let dir = Eio.Path.(fs / clone) in
  (* GitHub names the fork: someone who already forked another opam-repository
     gets another name. *)
  let* fork =
    step observe (Fork registry) @@ fun () ->
    Tools.gh mgr
      [
        "api";
        "-X";
        "POST";
        Printf.sprintf "repos/%s/forks" registry;
        "--jq";
        ".clone_url + \" \" + .owner.login + \" \" + .full_name";
      ]
  in
  let* url, owner, fork =
    match String.split_on_char ' ' (String.trim fork) with
    | [ url; owner; fork ] -> Ok (url, owner, fork)
    | _ -> Error (`Tool "GitHub did not say where the fork is.")
  in
  (* The branch is the step from here: a pull request already open means the
     branch is on the fork, and otherwise everything below goes to make it. *)
  let* branch_made =
    step observe (Branch { fork; branch }) @@ fun () ->
    let* open_ =
      Tools.gh mgr
        [
          "api";
          Printf.sprintf "repos/%s/pulls?head=%s:%s&state=open" registry owner
            branch;
        ]
    in
    let* open_ =
      Github.decode
        (Wiretype.list Github.pull_request_json)
        ~what:"the open pull requests" open_
    in
    match open_ with
    | (pull_request : Github.pull_request) :: _ ->
        Ok (`Open pull_request.html_url)
    | [] ->
        (* A fork behind the registry lacks its newer commits, and GitHub refuses
         a push that brings a workflow change without the token's workflow
         scope, which an author should never need. So the branch starts from
         the newest commit both hold and only adds files, which is the pull
         request's diff either way. *)
        let* shared =
          match
            Tools.git mgr ~registry:dir [ "fetch"; "--quiet"; url; "main" ]
          with
          | Ok _ ->
              Tools.git mgr ~registry:dir [ "merge-base"; "HEAD"; "FETCH_HEAD" ]
          | Error _ -> Ok "HEAD"
        in
        let* _ =
          Tools.git mgr ~registry:dir
            [ "checkout"; "--quiet"; "--detach"; String.trim shared ]
        in
        let* () = write_all ~dir files in
        let* _ =
          Tools.git mgr ~registry:dir ("add" :: "--" :: List.map fst files)
        in
        let* _ =
          Tools.git mgr ~registry:dir [ "commit"; "--quiet"; "-m"; title ]
        in
        let* _ = Tools.git mgr ~registry:dir (push_args url branch) in
        Ok `Pushed
  in
  match branch_made with
  | `Open url -> Ok (Already_open url)
  | `Pushed ->
      let* opened =
        step observe (Pull_request registry) @@ fun () ->
        Tools.gh mgr
          [
            "pr";
            "create";
            "-R";
            registry;
            "--head";
            owner ^ ":" ^ branch;
            "--base";
            "main";
            "--title";
            title;
            "--body";
            body;
          ]
      in
      Ok (Opened (String.trim opened))

let open_pull_request mgr ~fs ~observe ~registry ~repository ~tag
    ~(found : Gates.found) =
  Tools.with_temporary_directory mgr ~fs @@ fun work ->
  let* clone = clone mgr ~observe ~registry ~work in
  let dir = Eio.Path.(fs / clone) in
  let in_registry path = Tools.show mgr ~registry:dir ~at:"HEAD" path in
  let rec compare_all state = function
    | [] -> Ok state
    | (path, bytes) :: rest -> (
        let* existing = in_registry path in
        match existing with
        | None -> compare_all Some_missing rest
        | Some held when String.equal held bytes -> compare_all state rest
        | Some _ -> Ok (Held_differently path))
  in
  let* state = compare_all All_held found.generated.opam_files in
  match state with
  | Held_differently path -> Ok (Published_differently path)
  | All_held -> Ok Already_published
  | Some_missing ->
      let rec fresh_owners kept = function
        | [] -> Ok (List.rev kept)
        | ((path, _) as record) :: rest -> (
            let* existing = in_registry path in
            match existing with
            | Some _ -> fresh_owners kept rest
            | None -> fresh_owners (record :: kept) rest)
      in
      let* owners = fresh_owners [] found.generated.owner_records in
      let* proposed =
        propose mgr ~fs ~observe ~registry ~clone
          ~branch:
            (Printf.sprintf "publish/%s-%s" (Filename.basename repository) tag)
          ~title:(title ~repository found)
          ~body:(body ~repository ~tag found)
          ~files:(found.generated.opam_files @ owners)
      in
      Ok (Proposed proposed)

let encode description what value =
  match Wiretype.encode description value with
  | Ok json -> Ok (json ^ "\n")
  | Error e ->
      Error
        (`Tool
           (Printf.sprintf "%s could not be written: %s" what
              (Wiretype.Unwritable.to_string e)))

let revoke mgr ~fs ~observe ~registry ~repository ~tag ~undo ~now =
  let release_name = Printf.sprintf "%s %s" repository tag in
  (* With no release the step is never finished: the refusal that follows
     says why. *)
  observe (Step.Started (Release_files { tag; repository }));
  let* release =
    Tools.gh_if_found mgr
      [ "api"; Printf.sprintf "repos/%s/releases/tags/%s" repository tag ]
  in
  match release with
  | None -> Ok (Error (Revocation.No_release release_name))
  | Some release -> (
      let* (release : Github.release) =
        Github.decode Github.release_json ~what:"the release" release
      in
      let* listing =
        Tools.gh mgr
          [ "api"; Printf.sprintf "repos/%s/contents?ref=%s" repository tag ]
      in
      let* entries =
        Github.decode
          (Wiretype.list Github.directory_entry_json)
          ~what:"the release's files" listing
      in
      observe (Step.Finished (Release_files { tag; repository }));
      let names =
        List.filter_map
          (fun (e : Github.directory_entry) ->
            if Filename.check_suffix e.name ".opam" then
              Some (Filename.chop_suffix e.name ".opam")
            else None)
          entries
      in
      let version = Release.version_of_tag tag in
      Tools.with_temporary_directory mgr ~fs @@ fun work ->
      let* clone = clone mgr ~observe ~registry ~work in
      let dir = Eio.Path.(fs / clone) in
      let in_registry path = Tools.show mgr ~registry:dir ~at:"HEAD" path in
      let rec states found = function
        | [] -> Ok (List.rev found)
        | name :: rest -> (
            let* opam = in_registry (Layout.path (Opam { name; version })) in
            match opam with
            | None -> states found rest
            | Some _ ->
                let path =
                  Layout.path (Record { record = Revocation; name; version })
                in
                let* revocation = in_registry path in
                let* revocation =
                  match revocation with
                  | None -> Ok None
                  | Some text ->
                      let* r =
                        Records.decode Records.revocation_json ~path text
                      in
                      Ok (Some r)
                in
                let* restored =
                  in_registry
                    (Layout.path
                       (Record { record = Restoration; name; version }))
                in
                let state =
                  Revocation.state revocation
                    ~restored:(Option.is_some restored)
                in
                states ((name, state) :: found) rest)
      in
      let* published = states [] names in
      let label name = Printf.sprintf "%s.%s" name version in
      let chosen, refusal =
        match undo with
        | false -> (
            let live =
              List.filter
                (fun (_, (state : Revocation.state)) ->
                  match state with
                  | Live -> true
                  | Revoked _ | Restored -> false)
                published
            in
            let before =
              List.find_map
                (fun (name, (state : Revocation.state)) ->
                  match state with
                  | Restored -> Some (Revocation.Revoked_before (label name))
                  | Live | Revoked _ -> None)
                published
            in
            (live, match live with [] -> before | _ :: _ -> None))
        | true ->
            let by_registry =
              List.find_map
                (fun (name, (state : Revocation.state)) ->
                  match state with
                  | Revoked
                      ((Security | Legal | Upstream_gone | Official_conflict) as
                       reason) ->
                      Some
                        (Revocation.Revoked_by_the_registry
                           { package = label name; reason })
                  | Revoked Author_request | Live | Restored -> None)
                published
            in
            ( List.filter
                (fun (_, (state : Revocation.state)) ->
                  match state with
                  | Revoked Author_request -> true
                  | Revoked _ | Live | Restored -> false)
                published,
              by_registry )
      in
      match (published, refusal, chosen) with
      | [], _, _ -> Ok (Error (Revocation.Not_published release_name))
      | _ :: _, Some refusal, _ -> Ok (Error refusal)
      | _ :: _, None, [] ->
          Ok
            (Error
               (if undo then Revocation.Not_revoked release_name
                else Revocation.Already_revoked release_name))
      | _ :: _, None, (_ :: _ as chosen) ->
          let wanted =
            if undo then Revocation.without_mark release.body
            else Revocation.with_mark release.body
          in
          let current = String.trim (Option.value release.body ~default:"") in
          let* () =
            step observe
              (if undo then Unmark { tag; repository }
               else Mark { tag; repository })
            @@ fun () ->
            if String.equal current wanted then Ok ()
            else
              let* _ =
                Tools.gh mgr
                  [
                    "release"; "edit"; tag; "-R"; repository; "--notes"; wanted;
                  ]
              in
              Ok ()
          in
          let rec records found = function
            | [] -> Ok (List.rev found)
            | (name, _) :: rest ->
                let* record =
                  if undo then
                    encode Records.restoration_json "The restoration"
                      (Revocation.author_restoration ~repository ~tag ~now)
                  else
                    encode Records.revocation_json "The revocation"
                      (Revocation.author_revocation ~repository ~tag ~now)
                in
                let path =
                  if undo then
                    Layout.path (Record { record = Restoration; name; version })
                  else
                    Layout.path (Record { record = Revocation; name; version })
                in
                records ((path, record) :: found) rest
          in
          let* files = records [] chosen in
          let verb = if undo then "Restore" else "Revoke" in
          let subject =
            match chosen with
            | [ (name, _) ] -> name
            | [] | _ :: _ :: _ -> Filename.basename repository
          in
          let* outcome =
            propose mgr ~fs ~observe ~registry ~clone
              ~branch:
                (Printf.sprintf "%s/%s-%s"
                   (String.lowercase_ascii verb)
                   (Filename.basename repository)
                   tag)
              ~title:(Printf.sprintf "%s %s %s" verb subject version)
              ~body:
                (Printf.sprintf "%s %s.\n\nRelease: %s\n\nIts notes %s %S." verb
                   release_name
                   (Revocation.release_url ~repository ~tag)
                   (if undo then "no longer say" else "say")
                   Revocation.mark)
              ~files
          in
          Ok (Ok outcome))
