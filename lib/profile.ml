type stage =
  | Session_load
  | Session_save
  | Initial_flow
  | Module_fetch
  | Html_parse
  | Page_check
  | Selection_check
  | Timetable_parse
  | Json_output
  | Text_output

type module_ = string

let module_of_slug = function
  | ( "spring-a" | "spring-b" | "spring-c" | "summer" | "autumn-a" | "autumn-b"
    | "autumn-c" | "spring-break" ) as slug ->
      Some slug
  | _ -> None

let stage_name = function
  | Session_load -> "session_load"
  | Session_save -> "session_save"
  | Initial_flow -> "initial_flow"
  | Module_fetch -> "module_fetch"
  | Html_parse -> "html_parse"
  | Page_check -> "page_check"
  | Selection_check -> "selection_check"
  | Timetable_parse -> "timetable_parse"
  | Json_output -> "json_output"
  | Text_output -> "text_output"

type stamp = { wall : float; cpu : float }

let now () = { wall = Unix.gettimeofday (); cpu = Sys.time () }

let milliseconds start finish =
  let elapsed = (finish -. start) *. 1000. in
  if Float.is_finite elapsed then Float.max 0. elapsed else 0.

let durations start finish =
  [
    ("wallMs", `Float (milliseconds start.wall finish.wall));
    ("cpuMs", `Float (milliseconds start.cpu finish.cpu));
  ]

let module_fields = function
  | None -> []
  | Some slug -> [ ("module", `String slug) ]

let outcome success =
  ("outcome", `String (if success then "success" else "failure"))

type state = {
  started : stamp;
  mutable context : (stage * module_ option) option;
  mutable stages : Yojson.Safe.t list;
  mutable http : Yojson.Safe.t list;
  mutable hops : int;
  mutable initial : Yojson.Safe.t option;
  mutable connections : int option;
}

let active = ref None
let enabled () = !active <> None

let reuse_connections () =
  Option.iter (fun state -> state.connections <- Some 0) !active

let connection_created () =
  Option.iter
    (fun state ->
      state.connections <- Option.map (fun count -> count + 1) state.connections)
    !active

let report state success =
  `Assoc
    [
      ( "profile",
        `Assoc
          ([
             ("version", `Int 1);
             ("operation", `String "timetable");
             outcome success;
           ]
          @ durations state.started (now ())
          @ [
              ( "transport",
                `String
                  (if state.connections = None then "default" else "reuse") );
              ( "connectionsCreated",
                match state.connections with
                | None -> `Null
                | Some count -> `Int count );
            ]
          @ [
              ("stages", `List (List.rev state.stages));
              ("http", `List (List.rev state.http));
            ]
          @
          match state.initial with
          | None -> []
          | Some facts -> [ ("initialFlow", facts) ]) );
    ]

let run ~enabled ~emit operation =
  if not enabled then operation ()
  else
    let previous = !active in
    let state =
      {
        started = now ();
        context = None;
        stages = [];
        http = [];
        hops = 0;
        initial = None;
        connections = None;
      }
    in
    active := Some state;
    match operation () with
    | result ->
        active := previous;
        emit (report state true);
        result
    | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        active := previous;
        emit (report state false);
        Printexc.raise_with_backtrace exn backtrace

let measure ?module_ stage operation =
  match !active with
  | None -> operation ()
  | Some state -> (
      let started = now () in
      let module_ =
        match (module_, state.context) with
        | None, Some (_, inherited) -> inherited
        | explicit, _ -> explicit
      in
      let record success =
        state.stages <-
          `Assoc
            ([ ("stage", `String (stage_name stage)); outcome success ]
            @ module_fields module_
            @ durations started (now ()))
          :: state.stages
      in
      match operation () with
      | result ->
          record true;
          result
      | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          record false;
          Printexc.raise_with_backtrace exn backtrace)

let scope ?module_ stage operation =
  match !active with
  | None -> operation ()
  | Some state ->
      let previous = state.context in
      state.context <- Some (stage, module_);
      Fun.protect
        ~finally:(fun () -> state.context <- previous)
        (fun () -> measure ?module_ stage operation)

let initial_flow ~timetable_recognized ~selected_module =
  Option.iter
    (fun state ->
      state.initial <-
        Some
          (`Assoc
             [
               ("timetableRecognized", `Bool timetable_recognized);
               ( "selectedModule",
                 match selected_module with
                 | None -> `Null
                 | Some slug -> `String slug );
             ]))
    !active

type hop = {
  state : state;
  index : int;
  context : (stage * module_ option) option;
  started : stamp;
  mutable headers : (stamp * int) option;
  mutable finished : bool;
}

let start_http () =
  Option.map
    (fun state ->
      state.hops <- state.hops + 1;
      {
        state;
        index = state.hops;
        context = state.context;
        started = now ();
        headers = None;
        finished = false;
      })
    !active

let http_headers hop ~status =
  Option.iter (fun hop -> hop.headers <- Some (now (), status)) hop

let finish_http hop success bytes wire_bytes =
  Option.iter
    (fun hop ->
      if not hop.finished then (
        hop.finished <- true;
        let finished = now () in
        let headers_time, status, body_time =
          match hop.headers with
          | None -> (finished, `Null, `Null)
          | Some (stamp, status) ->
              ( stamp,
                `Int status,
                `Float (milliseconds stamp.wall finished.wall) )
        in
        let context =
          match hop.context with
          | None -> []
          | Some (stage, module_) ->
              ("stage", `String (stage_name stage)) :: module_fields module_
        in
        hop.state.http <-
          `Assoc
            ([
               ("index", `Int hop.index);
               ("status", status);
               ( "bytes",
                 match bytes with
                 | None -> `Null
                 | Some bytes -> `Int (max 0 bytes) );
               ( "wireBytes",
                 match wire_bytes with
                 | None -> `Null
                 | Some bytes -> `Int (max 0 bytes) );
               ( "headersMs",
                 `Float (milliseconds hop.started.wall headers_time.wall) );
               ("bodyMs", body_time);
               outcome success;
             ]
            @ context)
          :: hop.state.http))
    hop

let http_complete hop ~bytes ~wire_bytes =
  finish_http hop true (Some bytes) (Some wire_bytes)

let http_failed hop = finish_http hop false None None
