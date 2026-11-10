(** Finds what the release gates judge, runs them, and says what the registry
    would hold for this release. *)

type generated = {
  opam_files : (string * string) list;  (** each path and its bytes *)
  owner_records : (string * string) list;  (** one per name, new or not *)
}

type found = {
  version : string;
  commit : string;
  asset : string;
  sha256 : string;
  notes : string option;  (** the release's notes, as its author wrote them *)
  generated : generated;
}

type checked = { outcomes : Report.outcome list; found : found option }

type change = {
  registry : Eio.Fs.dir_ty Eio.Path.t;
  base : string;
  head : string;
}

val release :
  _ Eio.Process.mgr ->
  fs:_ Eio.Path.t ->
  observe:(Step.event -> unit) ->
  registry:string ->
  repository:string ->
  tag:string ->
  change:change option ->
  (checked, [> Tools.error ]) result
(** Gates 2 to 7 on a published release. [registry] is [owner/name], read
    through GitHub unless [change] gives a checkout, which is read at its base.
    With [change], gate 4 also holds that change to what the release generates.
    Each gate is judged, and given to [observe], in the order of the report. *)

(** How the author's CI is judged: on what GitHub has now, or once its checks
    have finished, asking again every few seconds while they run and for a
    minute while none has started, as after a push. *)
type ci_wait = Judge_now | Wait_while_running of Eio.Time.Mono.ty Eio.Std.r

val before_release :
  _ Eio.Process.mgr ->
  observe:(Step.event -> unit) ->
  registry:string ->
  repository:string ->
  version:string ->
  commit:string ->
  archive:string ->
  ci_wait:ci_wait ->
  (Report.outcome list, [> Tools.error ]) result
(** Every gate that can run before a release exists, on an archive of the commit
    about to be tagged. A release cannot be fixed once it is published, so this
    is what keeps a mistake from costing a version number. *)

val official_of :
  _ Eio.Process.mgr ->
  string ->
  (Name_ownership.official, [> Tools.error ]) result
(** What official opam says of a name, read directly from it. *)

val change :
  _ Eio.Process.mgr ->
  fs:_ Eio.Path.t ->
  observe:(Step.event -> unit) ->
  registry:string ->
  change:change ->
  (Report.outcome list, [> Tools.error ]) result
(** Every gate that needs no package code, on a pull request's change to the
    registry, as its CI runs them. A publication's release is read from the opam
    files it adds. A revocation's or restoration's record is held to the release
    its version names: its notes, its archive, the name's owner, and what an
    author's record says. *)

val allowed_files :
  _ Eio.Process.mgr ->
  observe:(Step.event -> unit) ->
  registry:_ Eio.Path.t ->
  base:string ->
  head:string ->
  (Report.outcome, [> Tools.error ]) result

val standard_of_archive :
  _ Eio.Process.mgr ->
  observe:(Step.event -> unit) ->
  string ->
  (Report.outcome, [> Tools.error ]) result
