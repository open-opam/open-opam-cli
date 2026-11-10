(** What a run is doing, for a caller that shows it as it happens. The library
    prints nothing: it says what it starts, and what each gate finds. *)

type t =
  | Gate of Report.gate
  | Archive of string  (** the archive of the commit about to be tagged *)
  | Tag of { tag : string; repository : string }
      (** the commit tagged, and the tag pushed *)
  | Release of { tag : string; repository : string }
      (** a draft given its archive, then published *)
  | Registry of string  (** a clone of the registry, [owner/name] *)
  | Fork of string  (** the author's fork of the registry, [owner/name] *)
  | Branch of { fork : string; branch : string }
  | Pull_request of string  (** on the registry, [owner/name] *)
  | Immutable_releases of string
      (** turned on for a repository, [owner/name], by init *)
  | Offer of string  (** an opam file given [x-open-opam: true], by init *)
  | Commit of string  (** the commit init makes, by its subject *)
  | Push of string  (** the commit about to be released, pushed to [remote] *)
  | Waiting_for of string  (** the author's CI, for what it still runs *)

type event =
  | Started of t
  | Finished of t
  | Judged of Report.outcome
      (** a gate's verdict, which finishes [Gate outcome.gate] *)

val to_string : t -> string
(** A name that reads the same while the step runs and once it is done. *)
