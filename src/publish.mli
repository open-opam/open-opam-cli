(** Opens the one pull request a release is published or revoked through. It
    holds no credential of its own: [gh] and [git] act as the author. *)

type pull_request =
  | Opened of string  (** the pull request's URL *)
  | Already_open of string
      (** the URL of this release's pull request, opened by an earlier run *)

type outcome =
  | Proposed of pull_request
  | Already_published
  | Published_differently of string
      (** a path the registry already holds with other bytes *)

val open_pull_request :
  _ Eio.Process.mgr ->
  fs:_ Eio.Path.t ->
  observe:(Step.event -> unit) ->
  registry:string ->
  repository:string ->
  tag:string ->
  found:Gates.found ->
  (outcome, [> Tools.error ]) result
(** [registry] is [owner/name], the repository the pull request is opened on. A
    change is never made to what is already published, and a release has one
    pull request: running it again finds the one already open. *)

val revoke :
  _ Eio.Process.mgr ->
  fs:_ Eio.Path.t ->
  observe:(Step.event -> unit) ->
  registry:string ->
  repository:string ->
  tag:string ->
  undo:bool ->
  now:Ptime.t ->
  ((pull_request, Revocation.problem) result, [> Tools.error ]) result
(** Revokes every package of the release that is published and not revoked, or
    with [undo] restores every one its author revoked: marks the release's notes
    as the author, then opens one pull request that adds their records. What the
    registry would refuse is refused here first. *)

val title : repository:string -> Gates.found -> string
(** [Publish <package> <version>], or the repository's name for several. *)

val body : repository:string -> tag:string -> Gates.found -> string
(** What the release is, from its opam files and its notes, then where it came
    from, for a reviewer to check. *)
