module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd
module Term = Cmdliner.Term
module O = Open_opam

let ( let* ) = Result.bind

(* A release that fails a gate, and a run that could not finish, exit
   differently, so CI never reads a broken run as a refused release. *)
let exit_refused = 1
let exit_could_not_run = 2

let format_arg =
  Arg.(
    value
    & opt (enum [ ("text", `Text); ("json", `Json) ]) `Text
    & info [ "format" ] ~docv:"FORMAT" ~doc:"$(b,text) or $(b,json).")

let repository_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "repo" ] ~docv:"OWNER/NAME"
        ~doc:"The release's repository. The default is this checkout's origin.")

(* The display has written each gate's line as it was judged, so only JSON is
   left to write. *)
let write_report format (report : O.Report.t) =
  let code = if report.passed then 0 else exit_refused in
  match format with
  | `Text -> code
  | `Json -> (
      match Wiretype.encode O.Report.json report with
      | Ok json ->
          print_endline json;
          code
      | Error e ->
          prerr_endline (Wiretype.Unwritable.to_string e);
          exit_could_not_run)

let could_not_run (`Tool _ as e) =
  prerr_endline (O.Tools.error_to_string e);
  exit_could_not_run

(* The reason sits beneath the step that failed, as a gate's problems do. *)
let stopped display e =
  let indent =
    match Display.fail display with `Failed_step -> "  " | `No_step -> ""
  in
  List.iter
    (fun line -> prerr_endline (indent ^ line))
    (String.split_on_char '\n' (O.Tools.error_to_string e));
  exit_could_not_run

let origin_repository mgr ~cwd =
  let* url = O.Tools.git mgr ~registry:cwd [ "remote"; "get-url"; "origin" ] in
  let url = String.trim url in
  let after prefix =
    if String.starts_with ~prefix url then
      let n = String.length prefix in
      Some (String.sub url n (String.length url - n))
    else None
  in
  match
    List.find_map after
      [ "git@github.com:"; "https://github.com/"; "ssh://git@github.com/" ]
  with
  | Some path ->
      Ok
        (if Filename.check_suffix path ".git" then
           Filename.chop_suffix path ".git"
         else path)
  | None -> Error (`Tool "origin is not a GitHub repository: give --repo.")

let registry_arg =
  Arg.(
    value
    & opt string "open-opam/opam-repository"
    & info [ "registry" ] ~docv:"OWNER/NAME"
        ~doc:
          "The registry on GitHub: whose names and records apply, and where a \
           pull request is opened.")

(* Dune writes the release's version into an installed binary, and git's in a
   checkout; a source tree with neither has none to give. *)
let version =
  match Build_info.V1.version () with
  | Some version -> Build_info.V1.Version.to_string version
  | None -> "unknown"

(* A tag or a repository that reaches gh's and git's arguments is refused
   before anything runs, as Gates.release refuses it. *)
let refused_names ~repository ~tag =
  match
    (if O.Release.valid_repository repository then []
     else [ O.Release.Invalid_repository repository ])
    @ if O.Release.valid_tag tag then [] else [ Invalid_tag tag ]
  with
  | [] -> None
  | problems ->
      Some
        (O.Report.outcome Release_proof
           (List.map
              (fun problem : O.Report.problem ->
                {
                  code = O.Release.proof_problem_code problem;
                  message = O.Release.proof_problem_to_string problem;
                })
              problems))

(* The commit about to be tagged, and its archive as a release of [tag] holds
   it: named for the version, the tag without its v. *)
let commit_and_archive mgr ~observe ~work ~repository ~tag =
  let* status = O.Tools.run_git mgr [ "status"; "--porcelain" ] in
  if not (String.equal (String.trim status) "") then
    Error
      (`Tool
         "Your changes are not committed: commit or remove them, then run this \
          again.")
  else
    let* commit = O.Tools.run_git mgr [ "rev-parse"; "HEAD" ] in
    let commit = String.trim commit in
    let top =
      Printf.sprintf "%s-%s"
        (Filename.basename repository)
        (O.Release.version_of_tag tag)
    in
    let archive = Filename.concat work (top ^ ".tar.gz") in
    let step = O.Step.Archive (Filename.basename archive) in
    observe (O.Step.Started step);
    let* (_ : string) =
      O.Tools.run_git mgr
        [
          "archive";
          "--format=tar.gz";
          "--prefix=" ^ top ^ "/";
          "--output";
          archive;
          "HEAD";
        ]
    in
    observe (Finished step);
    Ok (commit, archive)

(* A release cannot be fixed once it is published, so a commit can be held to
   every gate that needs no release before it is tagged. *)
let before_tagging mgr ~fs ~observe ~registry ~repository ~tag =
  match refused_names ~repository ~tag with
  | Some refused ->
      observe (O.Step.Judged refused);
      Ok [ refused ]
  | None ->
      O.Tools.with_temporary_directory mgr ~fs @@ fun work ->
      let* commit, archive =
        commit_and_archive mgr ~observe ~work ~repository ~tag
      in
      O.Gates.before_release mgr ~observe ~registry ~repository
        ~version:(O.Release.version_of_tag tag)
        ~commit ~archive ~ci_wait:Judge_now

let check format archive checkout base head registry repository tag version =
  Eio_main.run @@ fun env ->
  Display.run ~clock:(Eio.Stdenv.mono_clock env) ~format @@ fun display ->
  let observe = Display.observe display in
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  let fs = Eio.Stdenv.fs env in
  let change =
    Option.map
      (fun checkout : O.Gates.change ->
        { registry = Eio.Path.(fs / checkout); base; head })
      checkout
  in
  let run =
    (* A change with no tag is a pull request, judged as the registry's CI
       judges it; with a tag, it is held to what that release generates. *)
    let* allowed =
      match (change, tag) with
      | None, _ -> Ok []
      | Some c, None -> O.Gates.change mgr ~fs ~observe ~registry ~change:c
      | Some (c : O.Gates.change), Some _ ->
          let* outcome =
            O.Gates.allowed_files mgr ~observe ~registry:c.registry ~base:c.base
              ~head:c.head
          in
          Ok [ outcome ]
    in
    let repository () =
      match repository with
      | Some repository -> Ok repository
      | None -> origin_repository mgr ~cwd
    in
    let* released =
      match tag with
      | None -> Ok []
      | Some tag ->
          let* repository = repository () in
          let* checked =
            O.Gates.release mgr ~fs ~observe ~registry ~repository ~tag ~change
          in
          Ok checked.outcomes
    in
    let* before =
      match version with
      | None -> Ok []
      | Some version ->
          let* repository = repository () in
          before_tagging mgr ~fs ~observe ~registry ~repository ~tag:version
    in
    let* archive =
      match archive with
      | None -> Ok []
      | Some archive ->
          let* outcome = O.Gates.standard_of_archive mgr ~observe archive in
          Ok [ outcome ]
    in
    Ok (allowed @ released @ before @ archive)
  in
  match run with
  | Error e -> stopped display e
  | Ok [] ->
      prerr_endline "Give a version, --tag, --archive or --checkout.";
      exit_could_not_run
  | Ok outcomes -> write_report format (O.Report.of_outcomes outcomes)

let check_cmd =
  let archive =
    Arg.(
      value
      & opt (some file) None
      & info [ "archive" ] ~docv:"FILE"
          ~doc:
            "A source archive, to hold to the release standard before tagging.")
  in
  let checkout =
    Arg.(
      value
      & opt (some dir) None
      & info [ "checkout" ] ~docv:"DIR"
          ~doc:
            "A checkout of the registry, to check a pull request's change \
             there as the registry's CI does, or with $(b,--tag) that it holds \
             what that release generates.")
  in
  let base =
    Arg.(
      value & opt string "main"
      & info [ "base" ] ~docv:"REF" ~doc:"What the change is made against.")
  in
  let head =
    Arg.(
      value & opt string "HEAD" & info [ "head" ] ~docv:"REF" ~doc:"The change.")
  in
  let tag =
    Arg.(
      value
      & opt (some string) None
      & info [ "tag" ] ~docv:"TAG" ~doc:"The release to check.")
  in
  let version =
    Arg.(
      value
      & pos 0 (some string) None
      & info [] ~docv:"VERSION"
          ~doc:
            "Check this commit as if it were released as $(docv): every gate \
             that needs no release, before the tag exists.")
  in
  Cmd.v
    (Cmd.info "check"
       ~doc:"Check a release against the gates that can run here.")
    Term.(
      const check $ format_arg $ archive $ checkout $ base $ head $ registry_arg
      $ repository_arg $ tag $ version)

(* The commit is held to every gate that can run before it is tagged, and only
   then tagged and released, from the very archive the gates read. *)
let release format repository tag registry =
  Eio_main.run @@ fun env ->
  Display.run ~clock:(Eio.Stdenv.mono_clock env) ~format @@ fun display ->
  let observe = Display.observe display in
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  let fs = Eio.Stdenv.fs env in
  let run =
    let* repository =
      match repository with
      | Some repository -> Ok repository
      | None -> origin_repository mgr ~cwd
    in
    match refused_names ~repository ~tag with
    | Some refused ->
        observe (O.Step.Judged refused);
        Ok (O.Report.of_outcomes [ refused ], None)
    | None ->
        O.Tools.with_temporary_directory mgr ~fs @@ fun work ->
        let* commit, archive =
          commit_and_archive mgr ~observe ~work ~repository ~tag
        in
        (* The author's CI runs on GitHub, so the commit goes there first, and
           the gates wait for its checks rather than send the author away. *)
        let push = O.Step.Push "origin" in
        observe (Started push);
        let* (_ : string) =
          match O.Tools.run_git mgr [ "push"; "--quiet"; "origin"; "HEAD" ] with
          | Ok pushed -> Ok pushed
          | Error (`Tool reason) -> Error (`Push_refused reason)
        in
        observe (Finished push);
        let* outcomes =
          O.Gates.before_release mgr ~observe ~registry ~repository
            ~version:(O.Release.version_of_tag tag)
            ~commit ~archive
            ~ci_wait:
              (Wait_while_running
                 (Eio.Stdenv.mono_clock env :> Eio.Time.Mono.ty Eio.Std.r))
        in
        let report = O.Report.of_outcomes outcomes in
        if not report.passed then Ok (report, None)
        else
          let* made =
            O.Releasing.make mgr ~observe ~repository ~tag ~commit ~archive
          in
          Ok (report, Some made)
  in
  match run with
  | Error (`Tool _ as e) -> stopped display e
  | Error (`Push_refused reason) ->
      let code = stopped display (`Tool reason) in
      Display.next display "Once the push works"
        ~command:("open-opam release " ^ tag);
      code
  | Ok (report, made) ->
      let code = write_report format report in
      (match made with
      | None -> ()
      | Some (Released page) ->
          Display.detail display page;
          Display.next display "Publish it" ~command:("open-opam publish " ^ tag)
      | Some (Already_released page) ->
          Display.passed display (tag ^ " is already released");
          Display.detail display page;
          Display.next display "Publish it" ~command:("open-opam publish " ^ tag));
      code

let release_cmd =
  let tag =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"VERSION" ~doc:"The tag to make, such as 1.2.3.")
  in
  Cmd.v
    (Cmd.info "release"
       ~doc:
         "Check this commit against every gate that can run before it is \
          tagged, then tag it and make its release: immutable, with the one \
          archive the gates checked.")
    Term.(const release $ format_arg $ repository_arg $ tag $ registry_arg)

(* Publishing starts from a release, made by release or by the author's own
   process, and only ever reads it. *)
let publish format repository version registry dry_run =
  Eio_main.run @@ fun env ->
  Display.run ~clock:(Eio.Stdenv.mono_clock env) ~format @@ fun display ->
  let observe = Display.observe display in
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  let fs = Eio.Stdenv.fs env in
  let run =
    let* repository =
      match repository with
      | Some repository -> Ok repository
      | None -> origin_repository mgr ~cwd
    in
    let* checked =
      O.Gates.release mgr ~fs ~observe ~registry ~repository ~tag:version
        ~change:None
    in
    let report = O.Report.of_outcomes checked.outcomes in
    match checked.found with
    | Some found when report.passed && not dry_run ->
        let* outcome =
          O.Publish.open_pull_request mgr ~fs ~observe ~registry ~repository
            ~tag:version ~found
        in
        Ok (report, Some outcome)
    | Some _ | None -> Ok (report, None)
  in
  match run with
  | Error e -> stopped display e
  | Ok (report, outcome) -> (
      let code = write_report format report in
      match outcome with
      | None -> code
      | Some (Proposed (Opened url)) ->
          Display.detail display url;
          Display.next display "The registry merges it once its checks pass";
          code
      | Some (Proposed (Already_open url)) ->
          Display.passed display "Its pull request is already open";
          Display.detail display url;
          Display.next display "The registry merges it once its checks pass";
          code
      | Some Already_published ->
          Display.passed display
            "This version is already published, with these bytes";
          code
      | Some (Published_differently path) ->
          Display.refused display ("Publish " ^ version);
          Display.detail display
            (path
           ^ " is already published with other bytes. A published version \
              never changes.");
          Display.next display "Release a new version"
            ~command:"open-opam release <version>";
          exit_refused)

let publish_cmd =
  let version =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"VERSION" ~doc:"The release's tag.")
  in
  let dry_run =
    Arg.(
      value & flag
      & info [ "dry-run" ] ~doc:"Show the checklist, and open nothing.")
  in
  Cmd.v
    (Cmd.info "publish"
       ~doc:
         "Check a release you have made against the registry's gates, and open \
          its one pull request.")
    Term.(
      const publish $ format_arg $ repository_arg $ version $ registry_arg
      $ dry_run)

let init yes repository =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  let planned =
    let* repository =
      match repository with
      | Some repository -> Ok repository
      | None -> origin_repository mgr ~cwd
    in
    let* tracked = O.Tools.run_git mgr [ "ls-files" ] in
    let files = String.split_on_char '\n' tracked in
    let opam_files =
      List.filter
        (fun f ->
          (not (String.contains f '/')) && Filename.check_suffix f ".opam")
        files
    in
    let lacking =
      List.filter
        (fun file ->
          match Eio.Path.load Eio.Path.(cwd / file) with
          | contents -> (
              match O.Opam_file.of_string contents with
              | Ok opam -> (
                  match O.Opam_file.bool_field opam "x-open-opam" with
                  | Some true -> false
                  | Some false | None -> true)
              | Error _ -> false)
          | exception Eio.Io _ -> false)
        opam_files
    in
    let* immutability =
      O.Tools.gh mgr
        [ "api"; Printf.sprintf "repos/%s/immutable-releases" repository ]
    in
    let immutable =
      match Wiretype.decode O.Github.immutability_json immutability with
      | Ok (v : O.Github.immutability) -> v.enabled
      | Error _ -> false
    in
    Ok (repository, immutable, lacking, List.mem "dune-project" files)
  in
  match planned with
  | Error e -> could_not_run e
  | Ok (repository, true, [], _) ->
      Display.run ~clock:(Eio.Stdenv.mono_clock env) ~format:`Text
      @@ fun display ->
      Display.passed display (repository ^ " is set up to publish");
      Display.next display "Release a commit"
        ~command:"open-opam release <version>";
      0
  | Ok (repository, immutable, lacking, uses_dune) -> (
      print_endline "This will:";
      if not immutable then
        print_endline ("  - turn on immutable releases for " ^ repository);
      List.iter
        (fun f ->
          print_endline ("  - offer " ^ f ^ " here, with x-open-opam: true"))
        lacking;
      let agreed =
        yes
        ||
        (print_string "Go ahead? [y/N] ";
         flush stdout;
         match In_channel.input_line In_channel.stdin with
         | Some ("y" | "Y" | "yes") -> true
         | Some _ | None -> false)
      in
      if not agreed then (
        Display.run ~clock:(Eio.Stdenv.mono_clock env) ~format:`Text
        @@ fun display ->
        Display.refused display "Nothing changed";
        Display.next display "To set up later" ~command:"open-opam init";
        0)
      else
        Display.run ~clock:(Eio.Stdenv.mono_clock env) ~format:`Text
        @@ fun display ->
        let observe = Display.observe display in
        let step step f =
          observe (O.Step.Started step);
          let* () = f () in
          observe (Finished step);
          Ok ()
        in
        let append file =
          let path = Eio.Path.(cwd / file) in
          let existing =
            match Eio.Path.load path with
            | text -> text
            | exception Eio.Io _ -> ""
          in
          let separated =
            if
              String.equal existing "" || String.ends_with ~suffix:"\n" existing
            then existing
            else existing ^ "\n"
          in
          match
            Eio.Path.save ~create:(`Or_truncate 0o644) path
              (separated ^ "x-open-opam: true\n")
          with
          | () -> Ok ()
          | exception (Eio.Io _ as e) ->
              Error
                (`Tool
                   (Printf.sprintf "%s cannot be written: %s." file
                      (O.Tools.io_reason e)))
        in
        let subject = "Offer releases to open-opam" in
        let run =
          let* () =
            if immutable then Ok ()
            else
              step (Immutable_releases repository) @@ fun () ->
              let* (_ : string) =
                O.Tools.gh mgr
                  [
                    "api";
                    "-X";
                    "PUT";
                    Printf.sprintf "repos/%s/immutable-releases" repository;
                  ]
              in
              Ok ()
          in
          let rec offer = function
            | [] -> Ok ()
            | file :: rest ->
                let* () =
                  step (Offer file) @@ fun () ->
                  let* () = append file in
                  (* dune writes the opam file from dune-project and this
                     template, so without it the next build would drop the
                     line. *)
                  if uses_dune then append (file ^ ".template") else Ok ()
                in
                offer rest
          in
          let* () = offer lacking in
          match lacking with
          | [] -> Ok `Turned_on
          | _ :: _ ->
              let templates =
                if uses_dune then List.map (fun f -> f ^ ".template") lacking
                else []
              in
              let* () =
                step (Commit subject) @@ fun () ->
                let* (_ : string) =
                  O.Tools.run_git mgr ("add" :: (lacking @ templates))
                in
                let* (_ : string) =
                  O.Tools.run_git mgr [ "commit"; "--quiet"; "-m"; subject ]
                in
                Ok ()
              in
              Ok `Committed
        in
        match run with
        | Error e -> stopped display e
        | Ok `Committed ->
            Display.next display "Release it"
              ~command:"open-opam release <version>";
            0
        | Ok `Turned_on ->
            Display.next display "Release a commit"
              ~command:"open-opam release <version>";
            0)

let init_cmd =
  let yes =
    Arg.(value & flag & info [ "yes" ] ~doc:"Do not ask before making changes.")
  in
  Cmd.v
    (Cmd.info "init"
       ~doc:
         "Set this repository up to publish: turn on immutable releases, and \
          offer its opam files here.")
    Term.(const init $ yes $ repository_arg)

let revoke format repository version undo registry =
  Eio_main.run @@ fun env ->
  Display.run ~clock:(Eio.Stdenv.mono_clock env) ~format @@ fun display ->
  let observe = Display.observe display in
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  let fs = Eio.Stdenv.fs env in
  let run =
    let* repository =
      match repository with
      | Some repository -> Ok repository
      | None -> origin_repository mgr ~cwd
    in
    if not (O.Release.valid_tag version) then
      Error (`Tool (O.Release.proof_problem_to_string (Invalid_tag version)))
    else
      O.Publish.revoke mgr ~fs ~observe ~registry ~repository ~tag:version ~undo
        ~now:(Ptime_clock.now ())
  in
  match run with
  | Error e -> stopped display e
  | Ok (Error problem) ->
      Display.refused display
        ((if undo then "Restore " else "Revoke ") ^ version);
      Display.detail display (O.Revocation.problem_to_string problem);
      exit_refused
  | Ok (Ok (Opened url)) ->
      Display.detail display url;
      Display.next display "The registry merges it once its checks pass";
      0
  | Ok (Ok (Already_open url)) ->
      Display.passed display "Its pull request is already open";
      Display.detail display url;
      Display.next display "The registry merges it once its checks pass";
      0

let revoke_cmd =
  let version =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"VERSION" ~doc:"The release's tag.")
  in
  let undo =
    Arg.(value & flag & info [ "undo" ] ~doc:"Restore a release you revoked.")
  in
  Cmd.v
    (Cmd.info "revoke"
       ~doc:
         "Revoke a release you published: opam stops installing it, and it \
          stays listed. Its notes on GitHub say so, which is how the registry \
          knows the request is yours, and one pull request adds its record.")
    Term.(
      const revoke $ format_arg $ repository_arg $ version $ undo $ registry_arg)

let status repository registry =
  Eio_main.run @@ fun env ->
  let mgr = Eio.Stdenv.process_mgr env in
  let cwd = Eio.Stdenv.cwd env in
  let run =
    let* repository =
      match repository with
      | Some repository -> Ok repository
      | None -> origin_repository mgr ~cwd
    in
    O.Status.of_repository mgr ~registry ~repository
  in
  match run with
  | Error e -> could_not_run e
  | Ok (status : O.Status.t) ->
      List.iter
        (fun (p : O.Status.package) ->
          match (p.owner, p.versions) with
          | Some owner, _ ->
              Printf.printf "%s  belongs to %s here\n" p.name owner
          | None, [] -> Printf.printf "%s  not published\n" p.name
          | None, versions ->
              print_endline p.name;
              List.iter
                (fun (version, (state : O.Revocation.state)) ->
                  match state with
                  | Live | Restored -> Printf.printf "  %s  published\n" version
                  | Revoked reason ->
                      Printf.printf "  %s  revoked (%s)\n" version
                        (match reason with
                        | Author_request -> "by you"
                        | Security -> "security"
                        | Legal -> "legal"
                        | Upstream_gone -> "release gone"
                        | Official_conflict -> "official opam holds the name"))
                versions)
        status.packages;
      (match status.waiting with
      | [] -> ()
      | waiting ->
          print_endline "Waiting";
          List.iter
            (fun (title, url) -> Printf.printf "  %s  %s\n" title url)
            waiting);
      0

let status_cmd =
  Cmd.v
    (Cmd.info "status"
       ~doc:
         "Show what the registry holds of this repository's packages, and what \
          is waiting to be published or revoked.")
    Term.(const status $ repository_arg $ registry_arg)

let () =
  exit
    (Cmd.eval'
       (Cmd.group
          (Cmd.info "open-opam" ~version
             ~doc:"Publish a GitHub release to the open-opam registry.")
          [
            init_cmd;
            check_cmd;
            release_cmd;
            publish_cmd;
            revoke_cmd;
            status_cmd;
          ]))
