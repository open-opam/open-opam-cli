type source = (string * string) list

type problem =
  | No_opam_file
  | Unreadable_opam_file of { file : string; reason : string }
  | Missing_field of { file : string; field : string }
  | Refused_field of { file : string; field : string }
  | No_dune_project
  | No_readme
  | Empty_readme of string
  | No_interface
  | No_test

let problem_code = function
  | No_opam_file -> "no_opam_file"
  | Unreadable_opam_file _ -> "unreadable_opam_file"
  | Missing_field _ -> "missing_field"
  | Refused_field _ -> "refused_field"
  | No_dune_project -> "no_dune_project"
  | No_readme -> "no_readme"
  | Empty_readme _ -> "empty_readme"
  | No_interface -> "no_interface"
  | No_test -> "no_test"

let problem_to_string = function
  | No_opam_file -> "There is no *.opam file at the project's root."
  | Unreadable_opam_file { file; reason } ->
      Printf.sprintf "%s: cannot be read: %s." file reason
  | Missing_field { file; field } -> Printf.sprintf "%s: needs %s." file field
  | Refused_field { file; field } ->
      Printf.sprintf
        "%s: %s is not allowed, since a release is its archive and nothing \
         else."
        file field
  | No_dune_project ->
      "There is no dune-project at the root: a release is built with dune."
  | No_readme -> "There is no README at the root."
  | Empty_readme file -> Printf.sprintf "%s is empty." file
  | No_interface -> "There is no .mli: a release states its public interface."
  | No_test ->
      "There is no test: no dune test, tests or cram stanza, no *.t and no \
       runtest rule."

let at_root path = not (String.contains path '/')

let is_readme path =
  at_root path
  &&
  match String.lowercase_ascii (Filename.remove_extension path) with
  | "readme" -> true
  | _ -> false

let is_dune_file path = String.equal (Filename.basename path) "dune"

let reads path =
  is_dune_file path || is_readme path
  || (at_root path && Filename.check_suffix path ".opam")

let opam_files source =
  List.filter
    (fun (path, _) -> at_root path && Filename.check_suffix path ".opam")
    source

let required = [ "synopsis"; "maintainer"; "license"; "dev-repo" ]
let refused = [ "pin-depends"; "patches"; "extra-files"; "extra-source" ]

let check_opam_file (file, contents) =
  match Opam_file.of_string contents with
  | Error reason -> [ Unreadable_opam_file { file; reason } ]
  | Ok opam ->
      let present = Opam_file.fields opam in
      List.filter_map
        (fun field ->
          if List.mem field present then None
          else Some (Missing_field { file; field }))
        required
      @ List.filter_map
          (fun field ->
            if List.mem field present then Some (Refused_field { file; field })
            else None)
          refused

(* Reads a dune file's atoms by depth, so that a stanza is told from a word in a
   comment or a string. A stanza is an atom right after a top-level paren, and
   [runtest] counts wherever it is, since it names the alias a rule attaches
   to. *)
let declares_a_test contents =
  let n = String.length contents in
  let is_atom = function
    | ' ' | '\t' | '\n' | '\r' | '(' | ')' | '"' | ';' -> false
    | _ -> true
  in
  let rec atom_end i =
    if i < n && is_atom contents.[i] then atom_end (i + 1) else i
  in
  let rec string_end i =
    if i >= n then n
    else
      match contents.[i] with
      | '"' -> i + 1
      | '\\' -> string_end (i + 2)
      | _ -> string_end (i + 1)
  in
  let rec line_end i =
    if i >= n || contents.[i] = '\n' then i else line_end (i + 1)
  in
  let rec walk i ~depth ~after_paren =
    if i >= n then false
    else
      match contents.[i] with
      | '(' -> walk (i + 1) ~depth:(depth + 1) ~after_paren:true
      | ')' -> walk (i + 1) ~depth:(depth - 1) ~after_paren:false
      | ' ' | '\t' | '\n' | '\r' -> walk (i + 1) ~depth ~after_paren
      | ';' -> walk (line_end i) ~depth ~after_paren
      | '"' -> walk (string_end (i + 1)) ~depth ~after_paren:false
      | _ -> (
          let stop = atom_end i in
          match String.sub contents i (stop - i) with
          | "runtest" -> true
          | ("test" | "tests" | "cram") when depth = 1 && after_paren -> true
          | _ -> walk stop ~depth ~after_paren:false)
  in
  walk 0 ~depth:0 ~after_paren:false

let is_cram_test path =
  Filename.check_suffix path ".t"
  || String.equal (Filename.basename path) "run.t"
     && Filename.check_suffix (Filename.dirname path) ".t"

let check source =
  let paths = List.map fst source in
  let opam = opam_files source in
  let readmes = List.filter (fun (path, _) -> is_readme path) source in
  let some_non_empty =
    List.exists
      (fun (_, text) -> not (String.equal (String.trim text) ""))
      readmes
  in
  List.concat
    [
      (match opam with
      | [] -> [ No_opam_file ]
      | files -> List.concat_map check_opam_file files);
      (if List.mem "dune-project" paths then [] else [ No_dune_project ]);
      (match readmes with
      | [] -> [ No_readme ]
      | (first, _) :: _ -> if some_non_empty then [] else [ Empty_readme first ]);
      (if List.exists (fun p -> Filename.check_suffix p ".mli") paths then []
       else [ No_interface ]);
      (if
         List.exists is_cram_test paths
         || List.exists
              (fun (path, text) -> is_dune_file path && declares_a_test text)
              source
       then []
       else [ No_test ]);
    ]
