type record = Revocation | Restoration

type file =
  | Opam of { name : string; version : string }
  | Owner of string
  | Record of { record : record; name : string; version : string }
  | Block of int

let directory = function
  | Revocation -> "revocations"
  | Restoration -> "restorations"

let path = function
  | Opam { name; version } ->
      Printf.sprintf "packages/%s/%s.%s/opam" name name version
  | Owner name -> Printf.sprintf ".open-opam/owners/%s.json" name
  | Record { record; name; version } ->
      Printf.sprintf ".open-opam/%s/%s.%s.json" (directory record) name version
  | Block account -> Printf.sprintf ".open-opam/blocked/%d.json" account

(* The characters opam allows in a package name, and in a version. *)
let name_character = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '+' -> true
  | _ -> false

let version_character c = name_character c || c = '.' || c = '~'
let all_of predicate s = (not (String.equal s "")) && String.for_all predicate s

(* A name holds no dot, so the first dot is the only one that can end it. *)
let name_and_version stem =
  match String.index_opt stem '.' with
  | None -> None
  | Some i ->
      let name = String.sub stem 0 i in
      let version = String.sub stem (i + 1) (String.length stem - i - 1) in
      if all_of name_character name && all_of version_character version then
        Some (name, version)
      else None

let json_stem file =
  if Filename.check_suffix file ".json" then
    Some (Filename.chop_suffix file ".json")
  else None

let record_of record file =
  Option.map
    (fun (name, version) -> Record { record; name; version })
    (Option.bind (json_stem file) name_and_version)

let of_path path =
  match String.split_on_char '/' path with
  | [ "packages"; directory; stem; "opam" ] -> (
      match name_and_version stem with
      | Some (name, version) when String.equal name directory ->
          Some (Opam { name; version })
      | Some _ | None -> None)
  | [ ".open-opam"; "owners"; file ] -> (
      match json_stem file with
      | Some name when all_of name_character name -> Some (Owner name)
      | Some _ | None -> None)
  | [ ".open-opam"; "revocations"; file ] -> record_of Revocation file
  | [ ".open-opam"; "restorations"; file ] -> record_of Restoration file
  | [ ".open-opam"; "blocked"; file ] -> (
      match json_stem file with
      | None -> None
      | Some stem -> (
          (* One spelling per account: int_of_string also reads 0x2a and 4_2. *)
          match int_of_string_opt stem with
          | Some account
            when account >= 0 && String.equal (string_of_int account) stem ->
              Some (Block account)
          | Some _ | None -> None))
  | _ -> None
