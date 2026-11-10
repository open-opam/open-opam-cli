(** What the registry holds of a repository's packages, and what is waiting. *)

type package = {
  name : string;
  versions : (string * Revocation.state) list;  (** oldest first *)
  owner : string option;
      (** the repository the name belongs to here, when it is another *)
}

type t = {
  packages : package list;
  waiting : (string * string) list;
      (** each open pull request's title and URL, publishing or revoking *)
}

val of_repository :
  _ Eio.Process.mgr ->
  registry:string ->
  repository:string ->
  (t, [> Tools.error ]) result
(** The packages are the [*.opam] files of the repository's default branch, and
    everything is read through GitHub. *)
