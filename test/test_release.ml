module R = Open_opam.Release
module G = Open_opam.Github

let strings = Alcotest.(list string)

let instant =
  match Ptime.of_date (2026, 11, 6) with Some t -> t | None -> Ptime.epoch

let repository : G.repository =
  {
    id = 42;
    full_name = "o/foo";
    owner = { id = 420; login = "o" };
    created_at = instant;
    parent = None;
  }

let release ?(draft = false) ?(immutable = true) ?(digest = Some "sha256:abc")
    () : G.release =
  {
    tag_name = "1.0.0";
    draft;
    immutable;
    published_at = Some instant;
    body = None;
    assets =
      [ { name = "foo-1.0.0.tar.gz"; digest; browser_download_url = "x" } ];
  }

let verification ?(id = "42") ?(commit = "c0") ?(sha256 = "abc") () :
    G.verification =
  {
    verification_result =
      {
        statement =
          {
            subject =
              [
                { digest = { sha1 = Some commit; sha256 = None } };
                { digest = { sha1 = None; sha256 = Some sha256 } };
              ];
            predicate = { repository_id = id };
          };
      };
  }

let facts ?(tag_object = Some "c0") ?(release = release ())
    ?(verification = Some (verification ())) ?(asset_verified = true)
    ?(archive_sha256 = Some "abc") () : R.facts =
  {
    repository;
    tag = "1.0.0";
    commit = "c0";
    tag_object;
    release;
    verification;
    asset_verified;
    archive_sha256;
  }

let proof name expected f =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.check strings name expected
        (List.map R.proof_problem_code (R.check_proof f)))

let proof_tests =
  [
    proof "a good release" [] (facts ());
    proof "a draft" [ "draft" ] (facts ~release:(release ~draft:true ()) ());
    proof "not immutable" [ "not_immutable" ]
      (facts ~release:(release ~immutable:false ()) ());
    proof "no such asset" [ "no_asset" ]
      (facts ~release:{ (release ()) with assets = [] } ~archive_sha256:None ());
    proof "another asset only" [ "no_asset" ]
      (facts
         ~release:
           {
             (release ()) with
             assets =
               [
                 {
                   name = "other.tar.gz";
                   digest = None;
                   browser_download_url = "x";
                 };
               ];
           }
         ~archive_sha256:None ());
    proof "verify refused" [ "not_verified" ] (facts ~verification:None ());
    proof "verify-asset refused" [ "asset_not_verified" ]
      (facts ~asset_verified:false ());
    proof "another repository" [ "attested_repository" ]
      (facts ~verification:(Some (verification ~id:"7" ())) ());
    proof "another commit" [ "attested_commit" ]
      (facts ~verification:(Some (verification ~commit:"c1" ())) ());
    proof "an annotated tag, attested by its object" []
      (facts ~tag_object:(Some "t0")
         ~verification:(Some (verification ~commit:"t0" ()))
         ());
    proof "an annotated tag, attested by its commit" [ "attested_commit" ]
      (facts ~tag_object:(Some "t0") ());
    proof "a tag that does not lead to the commit" [ "attested_commit" ]
      (facts ~tag_object:None ());
    proof "the asset's digest differs" [ "asset_digest_differs" ]
      (facts ~release:(release ~digest:(Some "sha256:zzz") ()) ());
    proof "the asset has no digest" [ "asset_digest_differs" ]
      (facts ~release:(release ~digest:None ()) ());
    proof "the attestation's digest differs"
      [ "attested_digest_differs" ]
      (facts ~verification:(Some (verification ~sha256:"zzz" ())) ());
    Alcotest.test_case "tags" `Quick (fun () ->
        let valid t = R.valid_tag t in
        Alcotest.(check bool) "plain" true (valid "1.2.3");
        Alcotest.(check bool) "v" true (valid "v1.2.3");
        Alcotest.(check bool) "empty" false (valid "");
        Alcotest.(check bool) "a flag" false (valid "--upload-pack=x");
        Alcotest.(check bool) "a path" false (valid "../1.0");
        Alcotest.(check bool) "a space" false (valid "1 0");
        Alcotest.(check string) "v goes" "1.2.3" (R.version_of_tag "v1.2.3");
        Alcotest.(check string) "one only" "v1" (R.version_of_tag "vv1"));
  ]

let opam_file extra =
  {|opam-version: "2.0"
dev-repo: "git+https://github.com/o/foo.git"
x-open-opam: true
|}
  ^ extra

let definitions name ?(version = "1.0.0") expected contents =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.check strings name expected
        (List.map R.definition_problem_code
           (R.check_definitions ~repository:"o/foo" ~version
              [ ("foo.opam", contents) ])))

let definition_tests =
  [
    definitions "a good file" [] (opam_file "");
    definitions "states the version" [] (opam_file {|version: "1.0.0"|});
    definitions "states another" [ "other_version" ]
      (opam_file {|version: "2.0.0"|});
    definitions "no consent" [ "no_consent" ]
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/o/foo.git"
|};
    definitions "consent refused" [ "no_consent" ]
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/o/foo.git"
x-open-opam: false
|};
    definitions "consent as a string is none" [ "no_consent" ]
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/o/foo.git"
x-open-opam: "true"
|};
    definitions "another repository" [ "other_repository" ]
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/attacker/foo.git"
x-open-opam: true
|};
    definitions "not github" [ "other_repository" ]
      {|opam-version: "2.0"
dev-repo: "git+https://gitlab.com/o/foo.git"
x-open-opam: true
|};
    definitions "another case is the same repository" []
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/O/Foo.git"
x-open-opam: true
|};
    definitions "its own url" [ "own_url" ]
      (opam_file {|url { src: "https://example.com/x" }|});
    definitions "its own commit" [ "own_commit_hash" ]
      (opam_file {|x-commit-hash: "c0"|});
    definitions "not an opam file" [ "unreadable_opam_file" ] "this is (not";
  ]

let generation_tests =
  let generated source =
    R.opam_file ~source ~commit:"c0" ~url:"https://x/a.tar.gz" ~sha256:"abc"
  in
  [
    Alcotest.test_case "dune's header goes, the rest stays" `Quick (fun () ->
        Alcotest.(check string)
          "file"
          "opam-version: \"2.0\"\n\
           x-commit-hash: \"c0\"\n\
           url {\n\
          \  src: \"https://x/a.tar.gz\"\n\
          \  checksum: \"sha256=abc\"\n\
           }\n"
          (generated
             "# This file is generated by dune, edit dune-project instead\n\
              opam-version: \"2.0\"\n"));
    Alcotest.test_case "a source with no last newline" `Quick (fun () ->
        Alcotest.(check bool)
          "still separate lines" true
          (String.starts_with ~prefix:"opam-version: \"2.0\"\nx-commit-hash"
             (generated "opam-version: \"2.0\"")));
    Alcotest.test_case "the same release writes the same bytes" `Quick
      (fun () ->
        let record () = R.owner_record ~repository ~claimed_at:instant in
        Alcotest.(check (result string string)) "owner" (record ()) (record ()));
    Alcotest.test_case "a generated owners record reads back" `Quick (fun () ->
        match R.owner_record ~repository ~claimed_at:instant with
        | Error reason -> Alcotest.fail reason
        | Ok json -> (
            match Wiretype.decode Open_opam.Records.owner_json json with
            | Error _ -> Alcotest.fail "did not read back"
            | Ok owner ->
                Alcotest.(check int) "id" 42 owner.github_repository_id));
    Alcotest.test_case "compare: same, differing, missing, extra" `Quick
      (fun () ->
        let actual = function
          | "same" -> Some "a\nb\n"
          | "other" -> Some "a\nX\n"
          | "extra" -> Some "a\nb\n"
          | _ -> None
        in
        Alcotest.check strings "problems"
          [
            "other: differs from what the release generates, first at line 2.";
            "gone: the release generates it, and the change lacks it.";
            "extra: the release does not generate it.";
          ]
          (List.map R.definition_problem_to_string
             (R.compare_generated
                ~expected:
                  [
                    ("same", "a\nb\n"); ("other", "a\nb\n"); ("gone", "a\nb\n");
                  ]
                ~added:[ "same"; "other"; "extra" ]
                ~actual)));
    Alcotest.test_case "compare: nothing generated, something added" `Quick
      (fun () ->
        Alcotest.check strings "problems"
          [ "extra: the release does not generate it." ]
          (List.map R.definition_problem_to_string
             (R.compare_generated ~expected:[] ~added:[ "extra" ]
                ~actual:(fun _ -> None))));
  ]

(* Built from GitHub's JSON, so the words are read as they are in a run. *)
let decoded description json =
  match Wiretype.decode description json with
  | Ok value -> value
  | Error problems ->
      Alcotest.failf "%s: %s" json
        (String.concat "; " (List.map Wiretype.Problem.to_string problems))

let run ?(conclusion = {|"success"|}) ?(status = "completed") name : G.check_run
    =
  let runs : G.check_runs =
    decoded G.check_runs_json
      (Printf.sprintf
         {|{"check_runs":[{"name":"%s","status":"%s","conclusion":%s}]}|} name
         status conclusion)
  in
  match runs.check_runs with
  | [ run ] -> run
  | [] | _ :: _ :: _ -> Alcotest.fail "one run"

let state context state : G.commit_status =
  let status : G.combined_status =
    decoded G.combined_status_json
      (Printf.sprintf {|{"statuses":[{"context":"%s","state":"%s"}]}|} context
         state)
  in
  match status.statuses with
  | [ status ] -> status
  | [] | _ :: _ :: _ -> Alcotest.fail "one status"

let ci name expected runs statuses =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.check strings name expected
        (List.map R.ci_problem_code (R.check_ci runs statuses)))

(* A word GitHub has not documented yet is no success, and is said as is. *)
let ci_says name expected runs statuses =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.check strings name expected
        (List.map R.ci_problem_to_string (R.check_ci runs statuses)))

let ci_tests =
  [
    ci_says "a conclusion GitHub adds later"
      [ "test finished as stale." ]
      [ run ~conclusion:{|"stale"|} "test" ]
      [];
    ci_says "a status GitHub adds later"
      [ "test is still running: run this again once it has finished." ]
      [ run ~status:"waiting" ~conclusion:"null" "test" ]
      [];
    ci_says "a state GitHub adds later"
      [ "ci finished as error." ]
      [ run "test" ]
      [ state "ci" "error" ];
    ci "green" [] [ run "test" ] [];
    ci "nothing at all" [ "no_checks" ] [] [];
    ci "a failure" [ "failed" ] [ run ~conclusion:{|"failure"|} "test" ] [];
    ci "one red among green" [ "failed" ]
      [ run "test"; run ~conclusion:{|"failure"|} "deploy" ]
      [];
    ci "cancelled is not success" [ "failed" ]
      [ run ~conclusion:{|"cancelled"|} "test" ]
      [];
    ci "timed out is not success" [ "failed" ]
      [ run ~conclusion:{|"timed_out"|} "test" ]
      [];
    ci "still running" [ "still_running" ]
      [ run ~status:"in_progress" ~conclusion:"null" "test" ]
      [];
    ci "queued" [ "still_running" ]
      [ run ~status:"queued" ~conclusion:"null" "test" ]
      [];
    ci "only skipped is not a success" [ "nothing_succeeded" ]
      [ run ~conclusion:{|"skipped"|} "test" ]
      [];
    ci "skipped beside a success" []
      [ run ~conclusion:{|"skipped"|} "deploy"; run "test" ]
      [];
    ci "a commit status counts" [] [] [ state "ci" "success" ];
    ci "a failed status" [ "failed" ] [ run "test" ] [ state "ci" "failure" ];
    ci "a pending status" [ "still_running" ]
      [ run "test" ]
      [ state "ci" "pending" ];
  ]

module O = Open_opam.Official

let order name smaller larger =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.(check bool)
        "smaller" true
        (O.compare_versions smaller larger < 0);
      Alcotest.(check bool) "larger" true (O.compare_versions larger smaller > 0);
      Alcotest.(check int) "same" 0 (O.compare_versions larger larger))

let version_tests =
  [
    order "numbers count as numbers" "1.9" "1.10";
    order "a patch is newer" "1.0" "1.0.1";
    order "a tilde is older" "1.0~beta" "1.0";
    order "a plus is newer" "1.0" "1.0+x";
    order "a letter sorts before a dot" "1.0a" "1.0.0";
    order "leading zeros do not count" "1.2" "1.03";
    Alcotest.test_case "the latest of several" `Quick (fun () ->
        Alcotest.(check (option string))
          "latest" (Some "foo.1.10.0")
          (O.latest ~name:"foo"
             [ "foo.1.9.0"; "foo.1.10.0"; "foo.1.10.0~rc1"; "bar.9.0"; "foo" ]));
  ]

let resolve name expected contents =
  Alcotest.test_case name `Quick (fun () ->
      let got =
        match O.resolve contents with
        | Repository r -> "repository " ^ r
        | Refused _ -> "refused"
      in
      Alcotest.(check string) name expected got)

let resolve_tests =
  [
    resolve "a GitHub dev-repo" "repository o/foo"
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/o/foo.git"
|};
    resolve "no dev-repo, a GitHub release asset" "repository o/foo"
      {|opam-version: "2.0"
url { src: "https://github.com/o/foo/releases/download/1.0/foo-1.0.tar.gz" }
|};
    resolve "dev-repo wins when both name the same" "repository o/foo"
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/o/foo.git"
url { src: "https://github.com/o/foo/releases/download/1.0/foo-1.0.tar.gz" }
|};
    resolve "two repositories are refused" "refused"
      {|opam-version: "2.0"
dev-repo: "git+https://github.com/o/foo.git"
url { src: "https://github.com/a/foo/releases/download/1.0/foo-1.0.tar.gz" }
|};
    resolve "a generated archive is no signal" "refused"
      {|opam-version: "2.0"
url { src: "https://github.com/o/foo/archive/1.0.tar.gz" }
|};
    resolve "a non-GitHub dev-repo is refused" "refused"
      {|opam-version: "2.0"
dev-repo: "git+https://gitlab.com/o/foo.git"
|};
    resolve "only a homepage is refused" "refused"
      {|opam-version: "2.0"
homepage: "https://github.com/o/foo"
|};
    resolve "not an opam file is refused" "refused" "this is (not";
  ]

let change_tests =
  [
    Alcotest.test_case "the release a registry file names" `Quick (fun () ->
        Alcotest.(check (option (pair string string)))
          "named"
          (Some ("o/foo", "1.0.0"))
          (R.release_of_opam_file
             {|opam-version: "2.0"
url { src: "https://github.com/o/foo/releases/download/1.0.0/foo-1.0.0.tar.gz" }
|}));
    Alcotest.test_case "anything else names none" `Quick (fun () ->
        List.iter
          (fun text ->
            Alcotest.(check (option (pair string string)))
              text None
              (R.release_of_opam_file text))
          [
            {|opam-version: "2.0"|};
            {|opam-version: "2.0"
url { src: "https://github.com/o/foo/archive/1.0.0.tar.gz" }
|};
            {|opam-version: "2.0"
url { src: "https://github.com/o/foo/releases/download/--evil/a.tar.gz" }
|};
            {|opam-version: "2.0"
url { src: "https://github.com/-R/foo/releases/download/1.0.0/a.tar.gz" }
|};
            {|opam-version: "2.0"
url { src: "https://github.com/o/../releases/download/1.0.0/a.tar.gz" }
|};
            {|opam-version: "2.0"
url { src: "https://github.com/o/foo?x/releases/download/1.0.0/a.tar.gz" }
|};
            {|opam-version: "2.0"
url { src: "https://example.com/o/foo/releases/download/1.0/a.tar.gz" }
|};
          ]);
  ]

let layout_tests =
  let module L = Open_opam.Layout in
  let read path =
    match L.of_path path with Some file -> L.path file | None -> "none"
  in
  [
    Alcotest.test_case "every file is read back from its path" `Quick (fun () ->
        List.iter
          (fun file ->
            let path = L.path file in
            Alcotest.(check string) path path (read path))
          [
            L.Opam { name = "foo-bar"; version = "1.0~beta+2" };
            L.Owner "foo_bar";
            L.Record { record = Revocation; name = "foo"; version = "1.2.3" };
            L.Record { record = Restoration; name = "foo"; version = "1.2.3" };
          ]);
    Alcotest.test_case "the paths it writes" `Quick (fun () ->
        Alcotest.check strings "paths"
          [
            "packages/foo/foo.1.0/opam";
            ".open-opam/owners/foo.json";
            ".open-opam/revocations/foo.1.0.json";
            ".open-opam/restorations/foo.1.0.json";
          ]
          (List.map L.path
             [
               L.Opam { name = "foo"; version = "1.0" };
               L.Owner "foo";
               L.Record { record = Revocation; name = "foo"; version = "1.0" };
               L.Record { record = Restoration; name = "foo"; version = "1.0" };
             ]));
    Alcotest.test_case "anything else is no file of the registry" `Quick
      (fun () ->
        List.iter
          (fun path -> Alcotest.(check string) path "none" (read path))
          [
            "packages/foo/bar.1.0/opam";
            "packages/foo/foo./opam";
            "packages/Fo!o/Fo!o.1.0/opam";
            ".open-opam/owners/fo o.json";
            ".open-opam/revocations/Fo!o.1.0.json";
            ".open-opam/revocations/foo.json";
            ".open-opam/revocations/foo.1 0.json";
            ".open-opam/owners/foo.txt";
            "README.md";
          ]);
  ]

let found ?notes packages : Open_opam.Gates.found =
  {
    version = "1.0.0";
    commit = "c0";
    asset = "foo-1.0.0.tar.gz";
    sha256 = "abc";
    notes;
    generated =
      {
        opam_files =
          List.map
            (fun (name, synopsis) ->
              ( Open_opam.Layout.path (Opam { name; version = "1.0.0" }),
                Printf.sprintf "opam-version: \"2.0\"\nsynopsis: %S\n" synopsis
              ))
            packages;
        owner_records = [];
      };
  }

let pull_request_tests =
  let module P = Open_opam.Publish in
  let provenance =
    [
      "Release: https://github.com/o/foo/releases/tag/1.0.0";
      "Commit: `c0`";
      "Asset: `foo-1.0.0.tar.gz`";
      "SHA-256: `abc`";
    ]
  in
  let lines = String.split_on_char '\n' in
  [
    Alcotest.test_case "one package is named for itself" `Quick (fun () ->
        let found = found [ ("bar", "A bar") ] in
        Alcotest.(check string)
          "title" "Publish bar 1.0.0"
          (P.title ~repository:"o/foo" found);
        Alcotest.check strings "body"
          ("**bar 1.0.0**: A bar" :: "" :: provenance)
          (lines (P.body ~repository:"o/foo" ~tag:"1.0.0" found)));
    Alcotest.test_case "several are named for the repository, in a table" `Quick
      (fun () ->
        let found =
          found ~notes:"  Faster.\n"
            [ ("foo", "A | B"); ("foo-cli", "Its\ncommand") ]
        in
        Alcotest.(check string)
          "title" "Publish foo 1.0.0"
          (P.title ~repository:"o/foo" found);
        Alcotest.check strings "body"
          ([
             "**foo 1.0.0**";
             "";
             "| Package | Synopsis |";
             "|---|---|";
             "| foo | A \\| B |";
             "| foo-cli | Its command |";
             "";
             "Faster.";
             "";
           ]
          @ provenance)
          (lines (P.body ~repository:"o/foo" ~tag:"1.0.0" found)));
    Alcotest.test_case "empty notes are left out" `Quick (fun () ->
        let found = found ~notes:" \n" [ ("foo", "A foo") ] in
        Alcotest.check strings "body"
          ("**foo 1.0.0**: A foo" :: "" :: provenance)
          (lines (P.body ~repository:"o/foo" ~tag:"1.0.0" found)));
  ]

let intact_tests =
  let module V = Open_opam.Revocation in
  let real = String.make 64 'a' and decoy = String.make 64 'b' in
  (* The author writes the source, so its text may say sha256= too. *)
  let opam =
    R.opam_file
      ~source:
        (Printf.sprintf "opam-version: \"2.0\"\ndescription: \"sha256=%s\"\n"
           decoy)
      ~commit:"c0" ~url:"x" ~sha256:real
  in
  let intact sha256 =
    V.intact (release ~digest:(Some ("sha256:" ^ sha256)) ()) ~opam
  in
  [
    Alcotest.test_case "the asset the checksum names is intact" `Quick
      (fun () -> Alcotest.(check bool) "intact" true (intact real));
    Alcotest.test_case "the author's text names no asset" `Quick (fun () ->
        Alcotest.(check bool) "intact" false (intact decoy));
  ]

let () =
  Alcotest.run "release"
    [
      ("proof", proof_tests);
      ("definitions", definition_tests);
      ("generation", generation_tests);
      ("the author's CI", ci_tests);
      ("official versions", version_tests);
      ("official repositories", resolve_tests);
      ("what a change publishes", change_tests);
      ("the registry's layout", layout_tests);
      ("the pull request", pull_request_tests);
      ("a release still intact", intact_tests);
    ]
