(** Gate 5: a name belongs to one repository, by its numeric ID.

    A repository's number is saved the first time it publishes a name, and every
    later publication must carry it. An address can be registered again by
    someone else; the number cannot. A name official opam holds may first be
    published only from the repository official opam names, and a GitHub fork
    may never first publish a name its original publishes. *)

type official =
  | Not_official
  | Official_repository of { id : int; repository : string }
  | Official_refused of string  (** why no repository can publish it here *)

type fork =
  | Not_a_fork
  | Fork_of of { original : string; names : string list }
      (** the repository GitHub says it was forked from, [owner/name], and the
          names of the [*.opam] files at that one's root *)

type problem =
  | Official_elsewhere of { name : string; repository : string }
  | Official_unresolved of { name : string; reason : string }
  | Owned_by_another of { name : string; repository : string }
  | Disputed of string
  | Fork_of_the_original of {
      name : string;
      original : string;
      instead : string;
    }

val problem_code : problem -> string
val problem_to_string : problem -> string

val check :
  official:official ->
  owner:Records.owner option ->
  fork:fork ->
  repository:string ->
  repository_id:int ->
  name:string ->
  problem list
(** [repository] is [owner/name], from which a fork's own name is suggested. A
    name the registry already gave this repository passes the fork's rule: that
    is how its maintainer lets a fork have it. *)
