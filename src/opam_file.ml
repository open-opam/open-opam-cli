module P = OpamParserTypes.FullPos

type t = P.opamfile

let of_string contents =
  (* The parser's own exceptions, for text that is not an opam file. *)
  match OpamParser.FullPos.string contents "opam" with
  | exception OpamLexer.Error reason -> Error reason
  | exception Parsing.Parse_error -> Error "it is not an opam file"
  | file -> Ok file

let fields (t : t) =
  List.map
    (fun (item : P.opamfile_item) ->
      match item.pelem with
      | Variable (name, _) -> name.pelem
      | Section section -> section.section_kind.pelem)
    t.file_contents

let value (t : t) field =
  List.find_map
    (fun (item : P.opamfile_item) ->
      match item.pelem with
      | Variable (name, value) when String.equal name.pelem field -> Some value
      | Variable _ | Section _ -> None)
    t.file_contents

let string_field t field =
  match value t field with
  | Some { pelem = String s; _ } -> Some s
  | Some _ | None -> None

let bool_field t field =
  match value t field with
  | Some { pelem = Bool b; _ } -> Some b
  | Some _ | None -> None

let section_string_field (t : t) ~section field =
  List.find_map
    (fun (item : P.opamfile_item) ->
      match item.pelem with
      | Section s when String.equal s.section_kind.pelem section ->
          List.find_map
            (fun (inner : P.opamfile_item) ->
              match inner.pelem with
              | Variable (name, { pelem = String value; _ })
                when String.equal name.pelem field ->
                  Some value
              | Variable _ | Section _ -> None)
            s.section_items.pelem
      | Variable _ | Section _ -> None)
    t.file_contents
