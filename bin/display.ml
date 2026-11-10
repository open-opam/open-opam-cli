(* What a person sees while a command runs. A step that is running has a
   spinner, drawn on standard error and only on a terminal; a step that is done
   is a line on standard output, so a pipe or CI reads the same lines one at a
   time, without the spinner and without colour. *)

module O = Open_opam

(* The display keeps one line, the running step's, for the whole run: progress
   moves the cursor by a display's line count less one, which a display with no
   line makes a move of -1. *)
type t = {
  display : ((string -> unit) -> unit, unit) Progress.Display.t;
  step : string -> unit;  (** what the line says *)
  mutable lines : bool;  (** JSON is one document, written once the run ends *)
  mutable running : O.Step.t option;
}

(* no-color.org: NO_COLOR with any value turns colour off. *)
let colour () =
  Option.is_none (Sys.getenv_opt "NO_COLOR")
  &&
  match Sys.getenv_opt "TERM" with
  | Some "dumb" -> false
  | Some _ | None -> true

let frame = Mtime.Span.(80 * ms)

(* A reader that stops reading, as [head] does, has all it wanted, so the
   lines it no longer reads are not an error. *)
let print t pp =
  if t.lines then
    Progress.interject_with (fun () ->
        match Fmt.pr "%t@." pp with
        | () -> ()
        | exception Sys_error _ -> t.lines <- false)

let tick : unit Fmt.t = Fmt.styled `Green (Fmt.any "\u{2713}")
let cross : unit Fmt.t = Fmt.styled `Red (Fmt.any "\u{2717}")

let finish t =
  t.running <- None;
  t.step ""

let start t step =
  t.running <- Some step;
  t.step (O.Step.to_string step)

let observe t = function
  | O.Step.Started step -> start t step
  | Finished step ->
      finish t;
      print t (fun ppf -> Fmt.pf ppf "%a %s" tick () (O.Step.to_string step))
  | Judged (outcome : O.Report.outcome) ->
      finish t;
      print t (fun ppf ->
          Fmt.pf ppf "%a %a"
            (if outcome.passed then tick else cross)
            ()
            Fmt.(styled `Bold string)
            (O.Report.gate_to_string outcome.gate);
          List.iter
            (fun problem ->
              Fmt.pf ppf "@\n  %a"
                Fmt.(styled `Faint string)
                (O.Report.problem_to_string problem))
            outcome.problems)

(* The run could not finish: the step it stopped in is the one that failed.
   Whether there was one says if a reason can sit beneath it. *)
let fail t =
  match t.running with
  | None -> `No_step
  | Some step ->
      finish t;
      print t (fun ppf -> Fmt.pf ppf "%a %s" cross () (O.Step.to_string step));
      `Failed_step

(* How every command ends: what is done, what failed, a detail beneath either,
   such as an address, and what the author does next, with the command to run
   in bold so it can be copied at a glance. *)
let passed t text = print t (fun ppf -> Fmt.pf ppf "%a %s" tick () text)
let refused t text = print t (fun ppf -> Fmt.pf ppf "%a %s" cross () text)

(* The end of a run that left the author nothing to do. *)
let finished t text =
  print t (fun ppf ->
      Fmt.pf ppf "\u{1F389} %a %s" Fmt.(styled `Bold string) "Done!" text)

let detail t text =
  print t (fun ppf ->
      Fmt.list ~sep:Fmt.cut
        (fun ppf line -> Fmt.pf ppf "  %a" Fmt.(styled `Faint string) line)
        ppf
        (String.split_on_char '\n' (String.trim text)))

let arrow : unit Fmt.t = Fmt.styled `Cyan (Fmt.any "\u{2192}")

let next t ?command text =
  print t (fun ppf ->
      match command with
      | None -> Fmt.pf ppf "%a %s" arrow () text
      | Some command ->
          Fmt.pf ppf "%a %s: %a" arrow () text Fmt.(styled `Bold string) command)

let run ~clock ~format f =
  let colour = colour () in
  Fmt.set_style_renderer Fmt.stdout
    (if colour && Unix.isatty Unix.stdout then `Ansi_tty else `None);
  let line =
    Progress.Line.(
      list
        [
          spinner
            ?color:(if colour then Some (Progress.Color.ansi `cyan) else None)
            ();
          string;
        ])
  in
  let display =
    Progress.Display.start
      ~config:(Progress.Config.v ~persistent:false ())
      (Progress.Multi.line line)
  in
  let Progress.Reporter.[ step ] = Progress.Display.reporters display in
  let t =
    {
      display;
      step;
      lines = (match format with `Text -> true | `Json -> false);
      running = None;
    }
  in
  let result =
    Eio.Fiber.first
      (fun () -> f t)
      (fun () ->
        let rec spin () =
          Eio.Time.Mono.sleep_span clock frame;
          Progress.Display.tick t.display;
          spin ()
        in
        spin ())
  in
  Progress.Display.finalise t.display;
  result
