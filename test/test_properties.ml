(* What each round trip must give back, for any input rather than the few a
   test names. *)

module G = QCheck2.Gen
module V = Open_opam.Revocation
module R = Open_opam.Records
module Release = Open_opam.Release

let property ?(count = 500) name gen print law =
  QCheck_alcotest.to_alcotest (QCheck2.Test.make ~name ~count ~print gen law)

let of_chars chars = G.string_size ~gen:(G.oneof_list chars) (G.int_range 1 12)
let lower = String.to_seq "abcdefghijklmnopqrstuvwxyz" |> List.of_seq
let alnum = lower @ (String.to_seq "ABCXYZ0123456789" |> List.of_seq)

(* Release notes as authors write them: words, blank lines, Windows line
   endings, stray spaces, and the mark itself, alone or among them. *)
let notes =
  let line =
    G.oneof
      [
        G.map (String.concat " ")
          (G.list_size (G.int_range 0 4) (of_chars lower));
        G.pure "";
        G.pure V.mark;
        G.pure ("  " ^ V.mark ^ "\r");
        G.map (fun w -> w ^ "\r") (of_chars lower);
      ]
  in
  G.option (G.map (String.concat "\n") (G.list_size (G.int_range 0 6) line))

let print_notes = function None -> "None" | Some n -> Printf.sprintf "%S" n

let mark_tests =
  [
    property "marked notes say the mark" notes print_notes (fun n ->
        V.marked (Some (V.with_mark n)));
    property "unmarked notes do not" notes print_notes (fun n ->
        not (V.marked (Some (V.without_mark n))));
    property "revoking then restoring gives back the author's text" notes
      print_notes (fun n ->
        String.equal (V.without_mark (Some (V.with_mark n))) (V.without_mark n));
  ]

(* Whole seconds, as a record's instant is written. *)
let instant =
  G.map
    (fun s ->
      match Ptime.of_float_s (float_of_int s) with
      | Some t -> t
      | None -> Ptime.epoch)
    (G.int_range 0 4_102_444_800)

let text = G.string_size ~gen:G.printable (G.int_range 0 20)

let read_back description equal value =
  match Wiretype.encode description value with
  | Error _ -> false
  | Ok json -> (
      match Wiretype.decode description json with
      | Ok read -> equal value read
      | Error _ -> false)

let record_tests =
  let owner =
    G.map
      (fun (id, repository, disputed, claimed_at) : R.owner ->
        {
          github_repository_id = id;
          repository;
          status = (if disputed then Disputed else Active);
          claimed_at;
        })
      (G.quad G.nat text G.bool instant)
  in
  let reason =
    G.oneof_list
      R.[ Security; Legal; Author_request; Gone; Malicious; Official_conflict ]
  in
  let revocation =
    G.map
      (fun (reason, actor, evidence, revoked_at) : R.revocation ->
        { reason; actor; evidence; revoked_at })
      (G.quad reason text text instant)
  in
  let restoration =
    G.map
      (fun (actor, evidence, restored_at) : R.restoration ->
        { actor; evidence; restored_at })
      (G.triple text text instant)
  in
  let block =
    G.map
      (fun (account, actor, evidence, blocked_at) : R.block ->
        { account; actor; evidence; blocked_at })
      (G.quad text text text instant)
  in
  let same_status (a : R.status) (b : R.status) =
    match (a, b) with
    | Active, Active | Disputed, Disputed -> true
    | (Active | Disputed), (Active | Disputed) -> false
  in
  let same_reason (a : R.reason) (b : R.reason) =
    match (a, b) with
    | Security, Security
    | Legal, Legal
    | Author_request, Author_request
    | Gone, Gone
    | Malicious, Malicious
    | Official_conflict, Official_conflict ->
        true
    | ( ( Security | Legal | Author_request | Gone | Malicious
        | Official_conflict ),
        _ ) ->
        false
  in
  [
    property "an owners record reads back as written" owner
      (fun (o : R.owner) -> o.repository)
      (read_back R.owner_json (fun (a : R.owner) (b : R.owner) ->
           a.github_repository_id = b.github_repository_id
           && String.equal a.repository b.repository
           && same_status a.status b.status
           && Ptime.equal a.claimed_at b.claimed_at));
    property "a revocation reads back as written" revocation
      (fun (r : R.revocation) -> r.actor)
      (read_back R.revocation_json (fun (a : R.revocation) (b : R.revocation) ->
           same_reason a.reason b.reason
           && String.equal a.actor b.actor
           && String.equal a.evidence b.evidence
           && Ptime.equal a.revoked_at b.revoked_at));
    property "a restoration reads back as written" restoration
      (fun (r : R.restoration) -> r.actor)
      (read_back R.restoration_json
         (fun (a : R.restoration) (b : R.restoration) ->
           String.equal a.actor b.actor
           && String.equal a.evidence b.evidence
           && Ptime.equal a.restored_at b.restored_at));
    property "a block reads back as written" block
      (fun (b : R.block) -> b.account)
      (read_back R.block_json (fun (a : R.block) (b : R.block) ->
           String.equal a.account b.account
           && String.equal a.actor b.actor
           && String.equal a.evidence b.evidence
           && Ptime.equal a.blocked_at b.blocked_at));
  ]

(* A release as GitHub names one: an owner and a name, a tag that can name a
   version, and its archive. *)
let release =
  let tag = of_chars (alnum @ [ '.'; '-'; '_'; '+'; '~' ]) in
  G.map
    (fun (owner, name, tag, prefix) ->
      (owner ^ "/" ^ name, tag, Printf.sprintf "%s-%s.tar.gz" prefix tag))
    (G.quad (of_chars alnum) (of_chars alnum) tag (of_chars lower))

let opam_file_tests =
  [
    property "the registry's opam file names the release it was written for"
      release
      (fun (repository, tag, asset) ->
        String.concat " " [ repository; tag; asset ])
      (fun (repository, tag, asset) ->
        QCheck2.assume (Release.valid_tag tag);
        let url =
          Printf.sprintf "https://github.com/%s/releases/download/%s/%s"
            repository tag asset
        in
        let opam =
          Release.opam_file
            ~source:
              "# This file is generated by dune, edit dune-project instead\n\
               opam-version: \"2.0\"\n\
               synopsis: \"A package\"\n"
            ~commit:"c0" ~url ~sha256:(String.make 64 'a')
        in
        match Release.release_of_opam_file opam with
        | Some (r, t) -> String.equal r repository && String.equal t tag
        | None -> false);
  ]

(* Names and versions in the characters opam allows, so a version may hold
   dots, and the path holds more dots than the one between them. *)
let layout_tests =
  let module L = Open_opam.Layout in
  let name_chars = alnum @ [ '-'; '_'; '+' ] in
  let name = of_chars name_chars in
  let version = of_chars (name_chars @ [ '.'; '~' ]) in
  let file =
    G.oneof
      [
        G.map2 (fun name version -> L.Opam { name; version }) name version;
        G.map (fun name -> L.Owner name) name;
        G.map3
          (fun revoked name version ->
            L.Record
              {
                record = (if revoked then Revocation else Restoration);
                name;
                version;
              })
          G.bool name version;
        G.map (fun account -> L.Block account) G.nat;
      ]
  in
  [
    property "every path reads back as the file it was written for" file L.path
      (fun file ->
        match L.of_path (L.path file) with
        | Some read -> String.equal (L.path read) (L.path file)
        | None -> false);
  ]

let () =
  Alcotest.run "properties"
    [
      ("the revocation mark", mark_tests);
      ("the registry's records", record_tests);
      ("the registry's opam file", opam_file_tests);
      ("the registry's paths", layout_tests);
    ]
