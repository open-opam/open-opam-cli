let ( let* ) = Result.bind

type outcome = Released of string | Already_released of string

let step observe step f =
  observe (Step.Started step);
  let* value = f () in
  observe (Step.Finished step);
  Ok value

(* What GitHub holds for the tag; gh says "release not found" for none. *)
type found = Not_released | Draft | Published

let look_up mgr ~repository ~tag =
  let* answer =
    Tools.gh_or_refusal mgr ~refusals:[ "release not found" ]
      [ "release"; "view"; tag; "-R"; repository; "--json"; "isDraft" ]
  in
  match answer with
  | Refused _ -> Ok Not_released
  | Answered json ->
      let* (view : Github.release_view) =
        Github.decode Github.release_view_json ~what:"the release" json
      in
      Ok (if view.is_draft then Draft else Published)

let tag_commit mgr ~repository ~tag ~commit =
  let* listed = Tools.run_git mgr [ "tag"; "--list"; tag ] in
  let* () =
    if String.equal (String.trim listed) "" then
      let* (_ : string) = Tools.run_git mgr [ "tag"; tag; commit ] in
      Ok ()
    else
      let* named = Tools.run_git mgr [ "rev-parse"; tag ^ "^{commit}" ] in
      let named = String.trim named in
      if String.equal named commit then Ok ()
      else
        Error
          (`Tool
             (Printf.sprintf
                "The tag %s already names %s, not this commit: a published tag \
                 is never moved."
                tag named))
  in
  (* gh is the credential, as for a publication's branch: the author is signed
     in there, and this holds none. *)
  let* (_ : string) =
    Tools.run_git mgr
      [
        "-c";
        "credential.helper=";
        "-c";
        "credential.helper=!gh auth git-credential";
        "push";
        "--quiet";
        Printf.sprintf "https://github.com/%s.git" repository;
        "refs/tags/" ^ tag;
      ]
  in
  Ok ()

(* An immutable release takes no asset once it is published, so the archive,
   and any file the author attaches, is given to a draft, and the draft is then
   published. *)
let publish_with mgr ~repository ~tag ~archive ~attached ~draft =
  let* () =
    if draft then Ok ()
    else
      let* (_ : string) =
        Tools.gh mgr
          [
            "release";
            "create";
            tag;
            "--draft";
            "--verify-tag";
            "--title";
            tag;
            "--notes";
            "";
            "-R";
            repository;
          ]
      in
      Ok ()
  in
  let* (_ : string) =
    Tools.gh mgr
      (("release" :: "upload" :: tag :: archive :: attached)
      @ [ "--clobber"; "-R"; repository ])
  in
  let* (_ : string) =
    Tools.gh mgr [ "release"; "edit"; tag; "-R"; repository; "--draft=false" ]
  in
  Ok ()

let make mgr ~observe ~repository ~tag ~commit ~archive ~attached =
  let page = Revocation.release_url ~repository ~tag in
  let* release = look_up mgr ~repository ~tag in
  let made ~draft =
    let* () =
      step observe (Tag { tag; repository }) @@ fun () ->
      tag_commit mgr ~repository ~tag ~commit
    in
    let* () =
      step observe (Release { tag; repository }) @@ fun () ->
      publish_with mgr ~repository ~tag ~archive ~attached ~draft
    in
    Ok (Released page)
  in
  match release with
  | Published -> Ok (Already_released page)
  | Draft -> made ~draft:true
  | Not_released -> made ~draft:false
