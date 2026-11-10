(** The programs it calls: [gh] and [git], which act as the author; [tar],
    [diff] and [opam]; [dune], for [dune subst] in a clone of the tag; and
    [mktemp], [mkdir] and [ls]. *)

type error = [ `Tool of string ]
(** Why a tool could not give an answer. This is the run failing, never a
    release being refused. *)

val error_to_string : error -> string

val io_reason : exn -> string
(** Why an [Eio.Io] failed, in a few words on one line, for a message that says
    what could not be done. *)

val read_archive :
  _ Eio.Process.mgr -> string -> (Standard.source, [> error ]) result
(** A gzipped or bzipped tar's paths, relative to its one top directory, with
    the contents of those {!Standard.reads} asks for. It is listed and read and
    never extracted, so no path in it can reach outside. *)

val diff :
  _ Eio.Process.mgr ->
  registry:_ Eio.Path.t ->
  base:string ->
  head:string ->
  (Allowed_files.change list, [> error ]) result
(** What [head] changes since it left [base]. *)

val paths :
  _ Eio.Process.mgr ->
  registry:_ Eio.Path.t ->
  at:string ->
  (string list, [> error ]) result
(** Every path in the registry at [at]. *)

val gh : _ Eio.Process.mgr -> string list -> (string, [> error ]) result

val gh_if_found :
  _ Eio.Process.mgr -> string list -> (string option, [> error ]) result
(** As {!gh}, with [None] for GitHub's 404. *)

type answer = Answered of string | Refused of string  (** in [gh]'s words *)

val gh_or_refusal :
  _ Eio.Process.mgr ->
  refusals:string list ->
  string list ->
  (answer, [> error ]) result
(** As {!gh}, for a command whose refusal is an answer, such as
    [gh release verify]: [Refused] when what [gh] says begins with one of
    [refusals]. Any other failure is an error, since [gh] exits alike when it
    refuses and when it cannot reach GitHub. *)

val run_git : _ Eio.Process.mgr -> string list -> (string, [> error ]) result
(** Runs [git] in the current directory. *)

val git :
  _ Eio.Process.mgr ->
  registry:_ Eio.Path.t ->
  string list ->
  (string, [> error ]) result
(** Runs [git] in a directory. *)

val show :
  _ Eio.Process.mgr ->
  registry:_ Eio.Path.t ->
  at:string ->
  string ->
  (string option, [> error ]) result
(** A file's bytes at a ref, or [None] if it has none. A ref or an object git
    cannot read is an error. *)

val with_temporary_directory :
  _ Eio.Process.mgr ->
  fs:_ Eio.Path.t ->
  (string -> ('a, ([> error ] as 'e)) result) ->
  ('a, 'e) result
(** Removed afterwards, whatever the function returned. *)

val archive_differs_from_tag :
  _ Eio.Process.mgr ->
  fs:_ Eio.Path.t ->
  repository:string ->
  tag:string ->
  archive:string ->
  work:string ->
  (string option, [> error ]) result
(** Gate 3: the first difference between an archive's one top directory and the
    tag's files, or [None] when they are the same. For a dune project the tag's
    files after [dune subst], as dune-release archives them, are the same too.
    Both are unpacked below [work]. *)

val lint :
  _ Eio.Process.mgr ->
  file:string ->
  string ->
  (Report.problem option, [> error ]) result
(** Runs [opam lint] on one opam file's contents: the file's problem, if lint
    fails it. *)
