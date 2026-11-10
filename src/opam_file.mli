(** An opam file's fields, read with opam's own grammar. *)

type t

val of_string : string -> (t, string) result
(** [Error] says why the text is no opam file. *)

val fields : t -> string list
(** The name of every field and section, in the file's order. *)

val string_field : t -> string -> string option
val bool_field : t -> string -> bool option

val section_string_field : t -> section:string -> string -> string option
(** A string field inside a section, as [src] inside [url]. *)
