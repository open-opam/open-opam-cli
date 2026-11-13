let mark = "Revoked on open-opam."

let lines notes =
  String.split_on_char '\n' (Option.value notes ~default:"")
  |> List.map String.trim

let marked notes = List.exists (String.equal mark) (lines notes)

let without_mark notes =
  String.split_on_char '\n' (Option.value notes ~default:"")
  |> List.filter (fun line -> not (String.equal (String.trim line) mark))
  |> String.concat "\n" |> String.trim

let with_mark notes =
  match without_mark notes with "" -> mark | kept -> kept ^ "\n\n" ^ mark

type state = Live | Revoked of Records.reason | Restored

let state (revocation : Records.revocation option) ~restored =
  match (revocation, restored) with
  | None, _ -> Live
  | Some _, true -> Restored
  | Some r, false -> Revoked r.reason

let release_url ~repository ~tag =
  Printf.sprintf "https://github.com/%s/releases/tag/%s" repository tag

(* The registry writes one checksum, as a string (Release.opam_file). The rest
   of the file is the author's text, which may say sha256= anywhere. *)
let sha256_of contents =
  match Opam_file.of_string contents with
  | Error _ -> None
  | Ok opam ->
      Option.bind
        (Opam_file.section_string_field opam ~section:"url" "checksum")
        (fun checksum ->
          let prefix = "sha256=" in
          if String.starts_with ~prefix checksum then
            let n = String.length prefix in
            Some (String.sub checksum n (String.length checksum - n))
          else None)

let intact (release : Github.release) ~opam =
  match sha256_of opam with
  | None -> false
  | Some sha256 ->
      List.exists
        (fun (a : Github.asset) ->
          match a.digest with
          | Some digest -> String.equal digest ("sha256:" ^ sha256)
          | None -> false)
        release.assets

type problem =
  | Not_published of string
  | No_release of string
  | Not_the_owner of string
  | Not_marked of string
  | Still_marked of string
  | Asset_changed of string
  | Revoked_before of string
  | Not_revoked of string
  | Already_revoked of string
  | Revoked_by_the_registry of { package : string; reason : Records.reason }
  | Record_differs of { path : string; expected : string }

let problem_code = function
  | Not_published _ -> "not_published"
  | No_release _ -> "no_release"
  | Not_the_owner _ -> "not_the_owner"
  | Not_marked _ -> "not_marked"
  | Still_marked _ -> "still_marked"
  | Asset_changed _ -> "asset_changed"
  | Revoked_before _ -> "revoked_before"
  | Not_revoked _ -> "not_revoked"
  | Already_revoked _ -> "already_revoked"
  | Revoked_by_the_registry _ -> "revoked_by_the_registry"
  | Record_differs _ -> "record_differs"

let reason_to_string : Records.reason -> string = function
  | Security -> "security"
  | Legal -> "legal"
  | Author_request -> "author-request"
  | Gone -> "gone"
  | Malicious -> "malicious"
  | Official_conflict -> "official-conflict"

let problem_to_string = function
  | Not_published package ->
      Printf.sprintf "%s is not published on open-opam." package
  | No_release release -> Printf.sprintf "%s has no release." release
  | Not_the_owner package ->
      Printf.sprintf "%s belongs to another repository here." package
  | Not_marked release ->
      Printf.sprintf
        "The notes of %s do not say %S, so this is not its author's request."
        release mark
  | Still_marked release ->
      Printf.sprintf "The notes of %s still say %S." release mark
  | Asset_changed package ->
      Printf.sprintf
        "%s cannot be restored: its release's archive is not the one published."
        package
  | Revoked_before package ->
      Printf.sprintf
        "%s was revoked and restored before. Only the registry's maintainer \
         can revoke it again."
        package
  | Not_revoked package -> Printf.sprintf "%s is not revoked." package
  | Already_revoked package -> Printf.sprintf "%s is already revoked." package
  | Revoked_by_the_registry { package; reason } ->
      Printf.sprintf
        "%s was revoked by the registry (%s), and only its maintainer can \
         restore it."
        package (reason_to_string reason)
  | Record_differs { path; expected } -> Printf.sprintf "%s: %s" path expected

let author_revocation ~repository ~tag ~now : Records.revocation =
  {
    reason = Author_request;
    actor = repository;
    evidence = release_url ~repository ~tag;
    revoked_at = now;
  }

let author_restoration ~repository ~tag ~now : Records.restoration =
  {
    actor = repository;
    evidence = release_url ~repository ~tag;
    restored_at = now;
  }

let differs path expected = [ Record_differs { path; expected } ]

let check_revocation ~path ~repository ~tag text =
  match Wiretype.decode Records.revocation_json text with
  | Error _ -> differs path "not a revocation record"
  | Ok r -> (
      let evidence = release_url ~repository ~tag in
      match r.reason with
      | Security | Legal | Gone | Malicious | Official_conflict ->
          differs path "an author's revocation has the reason author-request"
      | Author_request ->
          if not (String.equal r.actor repository) then
            differs path ("its actor must be " ^ repository)
          else if not (String.equal r.evidence evidence) then
            differs path ("its evidence must be " ^ evidence)
          else [])

let check_restoration ~path ~repository ~tag text =
  match Wiretype.decode Records.restoration_json text with
  | Error _ -> differs path "not a restoration record"
  | Ok r ->
      let evidence = release_url ~repository ~tag in
      if not (String.equal r.actor repository) then
        differs path ("its actor must be " ^ repository)
      else if not (String.equal r.evidence evidence) then
        differs path ("its evidence must be " ^ evidence)
      else []
