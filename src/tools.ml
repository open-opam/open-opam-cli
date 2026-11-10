type error = [ `Tool of string ]

let error_to_string (`Tool message) = message
let ( let* ) = Result.bind

let find_from s ~sub =
  let n = String.length sub in
  let rec at i =
    if i + n > String.length s then None
    else if String.equal (String.sub s i n) sub then Some i
    else at (i + 1)
  in
  at

let contains s sub = Option.is_some (find_from s ~sub 0)

let replace ~this ~by s =
  let n = String.length this in
  let b = Buffer.create (String.length s) in
  let rec walk from =
    match find_from s ~sub:this from with
    | None -> Buffer.add_string b (String.sub s from (String.length s - from))
    | Some i ->
        Buffer.add_string b (String.sub s from (i - from));
        Buffer.add_string b by;
        walk (i + n)
  in
  walk 0;
  Buffer.contents b

let io_reason = function
  | Eio.Io (Eio.Fs.E (Permission_denied _), _) -> "permission denied"
  | Eio.Io (Eio.Fs.E (Not_found _), _) -> "not found"
  | Eio.Io (Eio.Fs.E (Already_exists _), _) -> "it already exists"
  | e -> (
      (* Eio's own text runs over lines, and the reason is on the first. *)
      match String.split_on_char '\n' (Printexc.to_string e) with
      | first :: _ -> String.trim first
      | [] -> "")

(* A program that cannot be run is the run failing; a program's non-zero exit is
   reported by [Exit_non_zero] so a caller decides what it means. *)
type ran = Exit_zero of string | Exit_non_zero of string

let run mgr ?cwd ?stdin args =
  let out = Buffer.create 1024 and err = Buffer.create 256 in
  let stdin = Option.map Eio.Flow.string_source stdin in
  match
    Eio.Process.run mgr ?cwd ?stdin ~stdout:(Eio.Flow.buffer_sink out)
      ~stderr:(Eio.Flow.buffer_sink err) args
  with
  | () -> Ok (Exit_zero (Buffer.contents out))
  | exception Eio.Io (Eio.Process.E (Child_error _), _) ->
      Ok
        (Exit_non_zero (String.trim (Buffer.contents err ^ Buffer.contents out)))
  | exception Eio.Io (Eio.Process.E (Executable_not_found program), _) ->
      Error (`Tool (Printf.sprintf "%s is not installed." program))
  | exception Eio.Io (Eio.Process.E (Permission_denied program), _) ->
      Error
        (`Tool (Printf.sprintf "%s cannot be run: permission denied." program))
  | exception (Eio.Io _ as e) ->
      let program = match args with program :: _ -> program | [] -> "" in
      Error
        (`Tool (Printf.sprintf "%s cannot be run: %s." program (io_reason e)))

(* The caller says which step failed, so the program's own words follow its
   name once, without the arguments, git's advice on what to type next, or the
   JSON body gh api repeats its message in. A failure nothing here expected is
   most often GitHub's or the network's, and passes. *)
let refused args reason =
  let program = match args with program :: _ -> program | [] -> "a tool" in
  let said =
    List.filter_map
      (fun line ->
        let line = String.trim line in
        if
          String.equal line ""
          || String.starts_with ~prefix:"hint:" line
          || String.starts_with ~prefix:"{" line
          || String.starts_with ~prefix:"[" line
        then None
        else
          let own = program ^ ": " in
          Some
            (if String.starts_with ~prefix:own line then
               String.sub line (String.length own)
                 (String.length line - String.length own)
             else line))
      (String.split_on_char '\n' reason)
  in
  let next =
    match program with
    | "gh" ->
        "\n\
         Try again in a minute. If it still fails, sign in again with gh auth \
         login."
    | _ -> ""
  in
  `Tool (Printf.sprintf "%s: %s%s" program (String.concat "\n" said) next)

let answer mgr ?cwd args =
  let* ran = run mgr ?cwd args in
  match ran with
  | Exit_zero out -> Ok out
  | Exit_non_zero reason -> Error (refused args reason)

let read_archive mgr archive =
  (* tar reads gzip and bzip2 alike, so a .tar.gz and a .tbz are read the same. *)
  let* listing = answer mgr [ "tar"; "-tf"; archive ] in
  let entries =
    List.filter
      (fun line ->
        (not (String.equal line "")) && not (String.ends_with ~suffix:"/" line))
      (String.split_on_char '\n' listing)
  in
  (* Git writes a pax header as a file of that name, which is no part of the
     source. *)
  let entries =
    List.filter (fun e -> not (String.equal e "pax_global_header")) entries
  in
  let relative entry =
    match String.index_opt entry '/' with
    | Some i -> String.sub entry (i + 1) (String.length entry - i - 1)
    | None -> entry
  in
  let rec read source = function
    | [] -> Ok (List.rev source)
    | entry :: rest ->
        let path = relative entry in
        let* contents =
          if Standard.reads path then
            answer mgr [ "tar"; "-xOf"; archive; entry ]
          else Ok ""
        in
        read ((path, contents) :: source) rest
  in
  read [] entries

let native registry = Eio.Path.native_exn registry

let git mgr ~registry args =
  answer mgr ("git" :: "-C" :: native registry :: args)

let diff mgr ~registry ~base ~head =
  let* raw =
    git mgr ~registry
      [
        "diff";
        "--raw";
        "--no-renames";
        "--no-abbrev";
        "-z";
        base ^ "..." ^ head;
      ]
  in
  match Allowed_files.of_raw_diff raw with
  | Ok changes -> Ok changes
  | Error reason -> Error (`Tool reason)

let paths mgr ~registry ~at =
  let* listing =
    git mgr ~registry [ "ls-tree"; "-r"; "--name-only"; "-z"; at ]
  in
  Ok
    (List.filter
       (fun p -> not (String.equal p ""))
       (String.split_on_char '\000' listing))

let gh mgr args = answer mgr ("gh" :: args)

let gh_if_found mgr args =
  let* ran = run mgr ("gh" :: args) in
  match ran with
  | Exit_zero out -> Ok (Some out)
  | Exit_non_zero reason ->
      if contains reason "HTTP 404" then Ok None
      else Error (refused ("gh" :: args) reason)

type answer = Answered of string | Refused of string

let gh_or_refusal mgr ~refusals args =
  let* ran = run mgr ("gh" :: args) in
  match ran with
  | Exit_zero out -> Ok (Answered out)
  | Exit_non_zero reason ->
      if List.exists (fun prefix -> String.starts_with ~prefix reason) refusals
      then Ok (Refused reason)
      else Error (refused ("gh" :: args) reason)

let run_git mgr args = answer mgr ("git" :: args)

(* git show fails alike for a path the ref lacks and for a repository it cannot
   read, so the path is looked for first: listing nothing is the only absence. *)
let show mgr ~registry ~at path =
  let* listed =
    git mgr ~registry [ "ls-tree"; "--name-only"; at; "--"; path ]
  in
  if String.equal listed "" then Ok None
  else
    let* bytes = git mgr ~registry [ "cat-file"; "blob"; at ^ ":" ^ path ] in
    Ok (Some bytes)

let with_temporary_directory mgr ~fs f =
  let* made = answer mgr [ "mktemp"; "-d" ] in
  let dir = String.trim made in
  (* A cancelled fiber can do no I/O, so the removal is protected from the
     cancellation it may be running for; that cancellation then goes on. What
     is left of a failed removal is the system's to clear, not the run's
     failure. *)
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () ->
          match Eio.Path.rmtree ~missing_ok:true Eio.Path.(fs / dir) with
          | () -> ()
          | exception Eio.Io _ -> ()))
    (fun () -> f dir)

let first_line text =
  match String.split_on_char '\n' text with line :: _ -> line | [] -> text

let archive_differs_from_tag mgr ~fs ~repository ~tag ~archive ~work =
  let clone = Filename.concat work "clone" in
  let from_archive = Filename.concat work "archive" in
  let* _ =
    answer mgr
      [
        "gh";
        "repo";
        "clone";
        repository;
        clone;
        "--";
        "--quiet";
        "--depth";
        "1";
        "--branch";
        tag;
      ]
  in
  let* _ = answer mgr [ "mkdir"; "-p"; from_archive ] in
  let* _ = answer mgr [ "tar"; "-xf"; archive; "-C"; from_archive ] in
  let* listed = answer mgr [ "ls"; "-A"; from_archive ] in
  match
    List.filter
      (fun line -> not (String.equal line ""))
      (String.split_on_char '\n' listed)
  with
  | [] | _ :: _ :: _ -> Ok (Some "it does not hold one top directory")
  | [ top ] -> (
      (* The tag's files, under the archive's own top directory, so that the
         name the author gave it is no difference. *)
      let differs_from ~into =
        let tarred = Filename.concat work (into ^ ".tar") in
        let into = Filename.concat work into in
        let* _ =
          answer mgr
            [
              "git";
              "-C";
              clone;
              "archive";
              "--format=tar";
              "--prefix=" ^ top ^ "/";
              "--output";
              tarred;
              "HEAD";
            ]
        in
        let* _ = answer mgr [ "mkdir"; "-p"; into ] in
        let* _ = answer mgr [ "tar"; "-xf"; tarred; "-C"; into ] in
        let* ran =
          run mgr [ "diff"; "-rq"; "--no-dereference"; into; from_archive ]
        in
        match ran with
        | Exit_zero _ -> Ok None
        | Exit_non_zero difference ->
            (* Paths below the temporary directory mean nothing to a reader. *)
            Ok
              (Some (replace ~this:(work ^ "/") ~by:"" (first_line difference)))
      in
      let* plain = differs_from ~into:"tag" in
      match plain with
      | None -> Ok None
      | Some difference
        when not
               (Eio.Path.is_file
                  Eio.Path.(fs / Filename.concat clone "dune-project")) ->
          Ok (Some difference)
      | Some difference -> (
          (* dune-release archives the tag after dune subst has written its
             version into the files, so that tree is the tag's too. *)
          let* subst = run mgr ~cwd:Eio.Path.(fs / clone) [ "dune"; "subst" ] in
          match subst with
          | Exit_non_zero _ -> Ok (Some difference)
          | Exit_zero _ ->
              let* _ =
                answer mgr
                  [
                    "git";
                    "-C";
                    clone;
                    "-c";
                    "user.name=open-opam";
                    "-c";
                    "user.email=open-opam@invalid";
                    "-c";
                    "commit.gpgsign=false";
                    "commit";
                    "--quiet";
                    "--allow-empty";
                    "-am";
                    "dune subst";
                  ]
              in
              (* What is left once dune subst has had its say is the
                 difference that matters. *)
              differs_from ~into:"substituted"))

let lint mgr ~file contents =
  let* ran = run mgr ~stdin:contents [ "opam"; "lint"; "-" ] in
  match ran with
  | Exit_zero _ -> Ok None
  | Exit_non_zero reason ->
      Ok
        (Some
           ({
              code = "opam_lint";
              message = Printf.sprintf "%s: opam lint failed: %s" file reason;
            }
             : Report.problem))
