module A = Open_opam.Allowed_files
module S = Open_opam.Standard
module R = Open_opam.Records
module Report = Open_opam.Report

let codes_of problem_code problems = List.map problem_code problems
let strings = Alcotest.(list string)
let added path = A.Added { path; kind = File }

let opam name version =
  Printf.sprintf "packages/%s/%s.%s/opam" name name version

let owner name = Printf.sprintf ".open-opam/owners/%s.json" name

let allowed ?(existing = []) name expected changes =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.check strings name expected
        (codes_of A.problem_code (A.check ~existing changes)))

let allowed_files =
  [
    allowed "a first release" []
      [ added (opam "foo" "1.2.3"); added (owner "foo") ];
    allowed "a later release" [] [ added (opam "foo" "1.2.4") ];
    allowed "a monorepo at one version" []
      [
        added (opam "foo" "1.2.3");
        added (opam "foo-bar" "1.2.3");
        added (owner "foo-bar");
      ];
    allowed "nothing" [ "nothing_added" ] [];
    allowed "only an owners record"
      [ "owner_without_a_package"; "nothing_added" ]
      [ added (owner "foo") ];
    allowed "someone else's owners record"
      [ "owner_without_a_package" ]
      [ added (opam "foo" "1.2.3"); added (owner "bar") ];
    allowed "two versions"
      [ "more_than_one_version" ]
      [ added (opam "foo" "1.2.3"); added (opam "bar" "1.2.4") ];
    allowed "a changed version" [ "changes_what_exists" ]
      [ A.Changed (opam "foo" "1.2.3"); added (opam "foo" "1.2.4") ];
    allowed "a deleted version"
      [ "deletes_what_exists"; "nothing_added" ]
      [ A.Deleted (opam "foo" "1.2.3") ];
    allowed "a symlink" [ "not_a_regular_file" ]
      [
        A.Added { path = opam "bar" "1.2.3"; kind = Symlink };
        added (opam "foo" "1.2.3");
      ];
    allowed "a submodule" [ "not_a_regular_file" ]
      [
        A.Added { path = "vendor"; kind = Submodule };
        added (opam "foo" "1.2.3");
      ];
    allowed "the validator"
      [ "outside_the_publication_paths" ]
      [ added "cli/src/standard.ml"; added (opam "foo" "1.2.3") ];
    allowed "a workflow"
      [ "outside_the_publication_paths" ]
      [ added ".github/workflows/x.yml"; added (opam "foo" "1.2.3") ];
    allowed "a companion file"
      [ "outside_the_publication_paths" ]
      [ added "packages/foo/foo.1.2.3/files/x"; added (opam "foo" "1.2.3") ];
    allowed "a directory for another name"
      [ "outside_the_publication_paths"; "nothing_added" ]
      [ added "packages/foo/bar.1.2.3/opam" ];
    allowed "a path that climbs out"
      [ "outside_the_publication_paths"; "nothing_added" ]
      [ added "packages/../foo.1.2.3/opam" ];
    allowed "a name differing by case"
      ~existing:[ "packages/foo/foo.1.0.0/opam" ]
      [ "differs_only_by_case" ]
      [ added "packages/foo/foo.1.0.0/opam" ];
    allowed "a block, which is the maintainer's"
      [ "outside_the_publication_paths" ]
      [ added ".open-opam/blocked/42.json"; added (opam "foo" "1.2.3") ];
  ]

let block_paths =
  let module L = Open_opam.Layout in
  let reads path expected =
    Alcotest.test_case path `Quick (fun () ->
        Alcotest.(check (option int))
          path expected
          (match L.of_path path with
          | Some (Block account) -> Some account
          | Some (Opam _ | Owner _ | Record _) | None -> None))
  in
  [
    reads ".open-opam/blocked/42.json" (Some 42);
    reads ".open-opam/blocked/042.json" None;
    reads ".open-opam/blocked/0x2a.json" None;
    reads ".open-opam/blocked/4_2.json" None;
    reads ".open-opam/blocked/-42.json" None;
    reads ".open-opam/blocked/o.json" None;
  ]

let diff_reading =
  let read name raw expected =
    Alcotest.test_case name `Quick (fun () ->
        match A.of_raw_diff raw with
        | Error reason -> Alcotest.fail reason
        | Ok changes ->
            Alcotest.check strings name expected
              (codes_of A.problem_code (A.check ~existing:[] changes)))
  in
  [
    read "an added file"
      (":000000 100644 0000 abcd A\000" ^ opam "foo" "1.0" ^ "\000")
      [];
    read "an added symlink" ":000000 120000 0000 abcd A\000x\000"
      [ "not_a_regular_file"; "nothing_added" ];
    read "a modified file" ":100644 100644 abcd dcba M\000x\000"
      [ "changes_what_exists"; "nothing_added" ];
    read "a file whose type changed" ":100644 120000 abcd dcba T\000x\000"
      [ "changes_what_exists"; "nothing_added" ];
    Alcotest.test_case "a status it does not know is an error" `Quick (fun () ->
        Alcotest.(check bool)
          "refused" true
          (Result.is_error (A.of_raw_diff ":100644 100644 a b X\000x\000")));
    Alcotest.test_case "a truncated entry is an error" `Quick (fun () ->
        Alcotest.(check bool)
          "refused" true
          (Result.is_error (A.of_raw_diff ":100644 100644 a b M")));
  ]

let good_opam =
  {|opam-version: "2.0"
synopsis: "A package"
maintainer: "x@example.com"
license: "MIT"
dev-repo: "git+https://github.com/o/r.git"
|}

let good =
  [
    ("foo.opam", good_opam);
    ("dune-project", "");
    ("README.md", "# foo\n");
    ("src/foo.mli", "");
    ("test/dune", "(test (name t))\n");
  ]

let without path source =
  List.filter (fun (p, _) -> not (String.equal p path)) source

let replace path text source = (path, text) :: without path source

let standard name expected source =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.check strings name expected
        (codes_of S.problem_code (S.check source)))

let standard_tests =
  [
    standard "a project that meets it" [] good;
    standard "no opam file" [ "no_opam_file" ] (without "foo.opam" good);
    standard "an opam file only below the root" [ "no_opam_file" ]
      (("sub/foo.opam", good_opam) :: without "foo.opam" good);
    standard "an opam file that is not one" [ "unreadable_opam_file" ]
      (replace "foo.opam" "this is (not" good);
    standard "no synopsis" [ "missing_field" ]
      (replace "foo.opam"
         {|opam-version: "2.0"
maintainer: "x"
license: "MIT"
dev-repo: "git+https://github.com/o/r.git"
|}
         good);
    standard "pin-depends" [ "refused_field" ]
      (replace "foo.opam" (good_opam ^ "pin-depends: []\n") good);
    standard "patches" [ "refused_field" ]
      (replace "foo.opam" (good_opam ^ "patches: []\n") good);
    standard "extra-source" [ "refused_field" ]
      (replace "foo.opam"
         (good_opam ^ "extra-source \"a\" { src: \"https://example.com/a\" }\n")
         good);
    standard "no dune-project" [ "no_dune_project" ]
      (without "dune-project" good);
    standard "no README" [ "no_readme" ] (without "README.md" good);
    standard "a README below the root" [ "no_readme" ]
      (("docs/README.md", "x") :: without "README.md" good);
    standard "an empty README" [ "empty_readme" ]
      (replace "README.md" " \n" good);
    standard "any README spelling" []
      (("readme", "x") :: without "README.md" good);
    standard "no .mli" [ "no_interface" ] (without "src/foo.mli" good);
    standard "no test" [ "no_test" ] (without "test/dune" good);
    standard "tests" [] (replace "test/dune" "(tests (names a b))" good);
    standard "a cram stanza" [] (replace "test/dune" "(cram (deps x))" good);
    standard "a runtest rule" []
      (replace "test/dune" "(rule (alias runtest) (action (run ./x)))" good);
    standard "a cram file" [] (("test/x.t", "") :: without "test/dune" good);
    standard "a cram directory" []
      (("test/x.t/run.t", "") :: without "test/dune" good);
    standard "a library's dune is no test" [ "no_test" ]
      (replace "test/dune" "(library (name foo))" good);
    standard "the word in a comment is no test" [ "no_test" ]
      (replace "test/dune" "; (test (name t))\n(library (name foo))" good);
    standard "the word in a string is no test" [ "no_test" ]
      (replace "test/dune" {|(library (name "(test (name t))"))|} good);
    standard "a test-named field below a stanza is no test" [ "no_test" ]
      (replace "test/dune" "(library (name foo) (test x))" good);
    Alcotest.test_case "reads only what it needs" `Quick (fun () ->
        Alcotest.(check bool) "dune" true (S.reads "a/b/dune");
        Alcotest.(check bool) "opam at root" true (S.reads "foo.opam");
        Alcotest.(check bool) "opam below root" false (S.reads "a/foo.opam");
        Alcotest.(check bool) "readme" true (S.reads "README.md");
        Alcotest.(check bool) "source" false (S.reads "src/foo.ml"));
  ]

let record_tests =
  [
    Alcotest.test_case "an owners record as the registry holds it" `Quick
      (fun () ->
        let document =
          {|{"github_repository_id": 1405551708, "repository": "owner/name", "official": false, "status": "active", "claimed_at": "2026-11-06T00:00:00Z"}|}
        in
        match Wiretype.decode R.owner_json document with
        | Error problems ->
            Alcotest.fail
              (String.concat "; "
                 (List.map Wiretype.Problem.to_string problems))
        | Ok owner ->
            Alcotest.(check int) "id" 1405551708 owner.github_repository_id;
            Alcotest.(check bool)
              "active" true
              (match owner.status with Active -> true | Disputed -> false));
    Alcotest.test_case "an owners record needs its identity" `Quick (fun () ->
        Alcotest.(check bool)
          "refused" true
          (Result.is_error
             (Wiretype.decode R.owner_json
                {|{"repository": "o/r", "official": false, "status": "active", "claimed_at": "2026-11-06T00:00:00Z"}|})));
    Alcotest.test_case "a revocation's reasons use their words" `Quick
      (fun () ->
        Alcotest.(check bool)
          "read" true
          (Result.is_ok
             (Wiretype.decode R.revocation_json
                {|{"reason": "official-conflict", "actor": "sync", "evidence": "https://example.com", "revoked_at": "2026-11-06T00:00:00Z"}|})));
  ]

let report_tests =
  [
    Alcotest.test_case "one failed gate fails the report" `Quick (fun () ->
        let report =
          Report.of_outcomes
            [
              Report.outcome Allowed_files [];
              Report.outcome Metadata_and_standard
                [ { code = "no_test"; message = "no test" } ];
            ]
        in
        Alcotest.(check bool) "failed" false report.passed);
    Alcotest.test_case "the JSON says what failed" `Quick (fun () ->
        let report =
          Report.of_outcomes
            [
              Report.outcome Metadata_and_standard
                [ { code = "no_test"; message = "no test" } ];
            ]
        in
        match Wiretype.encode Report.json report with
        | Error e -> Alcotest.fail (Wiretype.Unwritable.to_string e)
        | Ok json ->
            Alcotest.(check bool)
              "round trip" true
              (Result.is_ok (Wiretype.decode Report.json json)));
  ]

let temporary_directory_tests =
  [
    Alcotest.test_case "a cancelled run leaves nothing behind" `Quick (fun () ->
        Eio_main.run @@ fun env ->
        let mgr = Eio.Stdenv.process_mgr env in
        let fs = Eio.Stdenv.fs env in
        let made, set = Eio.Promise.create () in
        let cancelled =
          match
            Eio.Fiber.first
              (fun () ->
                match
                  Open_opam.Tools.with_temporary_directory mgr ~fs (fun dir ->
                      Eio.Promise.resolve set dir;
                      Eio.Fiber.await_cancel ())
                with
                | Ok () | Error (`Tool _) -> false)
              (fun () ->
                let (_ : string) = Eio.Promise.await made in
                true)
          with
          | cancelled -> cancelled
          | exception Fun.Finally_raised _ -> false
        in
        Alcotest.(check bool) "cancelled as itself" true cancelled;
        Alcotest.(check bool)
          "removed" false
          (Sys.file_exists (Eio.Promise.await made)));
  ]

let ownership_tests =
  let module N = Open_opam.Name_ownership in
  let owner id : R.owner =
    {
      github_repository_id = id;
      repository = "o/foo";
      status = Active;
      claimed_at = Ptime.epoch;
    }
  in
  let fork names = N.Fork_of { original = "up/foo"; names } in
  let check ?owner fork =
    N.check ~official:Not_official ~owner ~fork ~repository:"me/foo"
      ~repository_id:42 ~name:"foo"
  in
  let says name expected ?owner fork =
    Alcotest.test_case name `Quick (fun () ->
        Alcotest.check strings name expected
          (codes_of N.problem_code (check ?owner fork)))
  in
  [
    says "a fork takes its original's name" [ "fork_of_the_original" ]
      (fork [ "foo"; "foo-cli" ]);
    says "a fork under a name of its own" [] (fork [ "bar" ]);
    says "a repository that is no fork" [] Not_a_fork;
    says "a fork the registry gave the name to" [] ~owner:(owner 42)
      (fork [ "foo" ]);
    says "a fork's name another owns" [ "owned_by_another" ] ~owner:(owner 7)
      (fork [ "foo" ]);
    Alcotest.test_case "the refusal names a name of its own" `Quick (fun () ->
        Alcotest.check strings "message"
          [
            "foo: this repository is a fork of up/foo, which publishes foo. A \
             fork publishes under its own name, such as foo-me.";
          ]
          (List.map N.problem_to_string (check (fork [ "foo" ]))));
  ]

let () =
  Alcotest.run "open-opam"
    [
      ("name ownership", ownership_tests);
      ("allowed files", allowed_files);
      ("a block's path", block_paths);
      ("reading a diff", diff_reading);
      ("the standard", standard_tests);
      ("records", record_tests);
      ("the report", report_tests);
      ("the temporary directory", temporary_directory_tests);
    ]
