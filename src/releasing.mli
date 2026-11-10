(** Makes the release the gates expect, from a commit they passed: its tag, then
    a draft given the archive they checked, published so that the release is
    immutable with its one archive. [gh] and [git] act as the author. *)

type outcome =
  | Released of string  (** the release's page *)
  | Already_released of string
      (** the page of the release an earlier run, or the author, made *)

val make :
  _ Eio.Process.mgr ->
  observe:(Step.event -> unit) ->
  repository:string ->
  tag:string ->
  commit:string ->
  archive:string ->
  (outcome, [> Tools.error ]) result
(** [commit] is tagged [tag] where the author works, unless the tag already
    names it, and the tag is pushed to [repository], [owner/name]. A tag that
    names another commit is an error, never moved. A draft an earlier run left
    is given the archive again and published; a published release is left as it
    is. *)
