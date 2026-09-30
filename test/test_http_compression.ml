let payload = "<html><body>時間割 &amp; fixture</body></html>"
let gzip_headers = Cohttp.Header.init_with "content-encoding" "gzip"

let uint32 value =
  let bytes = Bytes.create 4 in
  Bytes.set_int32_le bytes 0 value;
  Bytes.to_string bytes

let gzip source =
  let compressed = Buffer.create 128 in
  let position = ref 0 in
  Zlib.compress ~header:false
    (fun bytes ->
      let count = min (Bytes.length bytes) (String.length source - !position) in
      Bytes.blit_string source !position bytes 0 count;
      position := !position + count;
      count)
    (fun bytes count -> Buffer.add_subbytes compressed bytes 0 count);
  "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff" ^ Buffer.contents compressed
  ^ uint32 (Zlib.update_crc_string Int32.zero source 0 (String.length source))
  ^ uint32 (Int32.of_int (String.length source))

let changed source index value =
  let bytes = Bytes.of_string source in
  Bytes.set bytes index value;
  Bytes.to_string bytes

let expect_protocol operation =
  match Internal_error.protect operation with
  | Error (Error.Protocol_error message) ->
      Alcotest.(check bool)
        "diagnostic excludes content" false
        (String.contains message '<');
      message
  | _ -> Alcotest.fail "expected a sanitized protocol error"

let test_decode () =
  let large = String.concat "" (List.init 4000 (fun _ -> payload)) in
  List.iter
    (fun source ->
      Alcotest.(check string)
        "decoded output" source
        (Http_compression.decode gzip_headers (gzip source)))
    [ ""; payload; large ];
  Alcotest.(check string)
    "concatenated members" (payload ^ large)
    (Http_compression.decode gzip_headers (gzip payload ^ gzip large));
  Alcotest.(check string)
    "case insensitive encoding" payload
    (Http_compression.decode
       (Cohttp.Header.init_with "content-encoding" " GZip ")
       (gzip payload))

let test_optional_headers () =
  let plain = gzip payload in
  let header =
    changed (String.sub plain 0 10) 3 '\x1e'
    ^ "\x03\x00abcfixture.html\x00fixture comment\x00"
  in
  let crc = Zlib.update_crc_string Int32.zero header 0 (String.length header) in
  let header = header ^ String.sub (uint32 crc) 0 2 in
  let encoded = header ^ String.sub plain 10 (String.length plain - 10) in
  Alcotest.(check string)
    "extra, name, comment and FHCRC" payload
    (Http_compression.decode gzip_headers encoded);
  ignore
    (expect_protocol (fun () ->
         Http_compression.decode gzip_headers (changed encoded 13 'z')))

let test_invalid_gzip () =
  let encoded = gzip payload in
  for length = 0 to String.length encoded - 1 do
    ignore
      (expect_protocol (fun () ->
           Http_compression.decode gzip_headers (String.sub encoded 0 length)))
  done;
  List.iter
    (fun broken ->
      Alcotest.(check string)
        "fixed gzip diagnostic" "TWINS returned an invalid gzip response"
        (expect_protocol (fun () -> Http_compression.decode gzip_headers broken)))
    [
      changed encoded 0 '\x00';
      changed encoded 2 '\x00';
      changed encoded 3 '\x20';
      changed encoded 10 '\x07';
      changed encoded (String.length encoded - 8) '\x00';
      changed encoded (String.length encoded - 4) '\x00';
      encoded ^ "private trailing data";
      encoded ^ String.sub encoded 0 (String.length encoded - 1);
    ]

let test_identity_and_unknown () =
  List.iter
    (fun headers ->
      Alcotest.(check string)
        "identity preserves output" payload
        (Http_compression.decode headers payload))
    [
      Cohttp.Header.init ();
      Cohttp.Header.init_with "content-encoding" "identity";
    ];
  List.iter
    (fun encoding ->
      Alcotest.(check string)
        "unknown encoding not disclosed"
        "TWINS returned an unsupported content encoding"
        (expect_protocol (fun () ->
             Http_compression.decode
               (Cohttp.Header.init_with "content-encoding" encoding)
               "<private body>")))
    [ "br"; "deflate"; "gzip, gzip"; "gzip, private-encoding"; "" ]

let test_bound () =
  let source = String.make 100000 'x' in
  let encoded = gzip source in
  Alcotest.(check string)
    "exact limit accepted" source
    (Http_compression.decode ~max_bytes:100000 gzip_headers encoded);
  List.iter
    (fun (headers, body, max_bytes) ->
      Alcotest.(check string)
        "bounded expansion diagnostic"
        "TWINS response exceeds the decoded size limit"
        (expect_protocol (fun () ->
             Http_compression.decode ~max_bytes headers body)))
    [
      (gzip_headers, encoded, 99999);
      (gzip_headers, encoded ^ encoded, 150000);
      (Cohttp.Header.init (), source, 99999);
    ]

let with_encoding setting operation =
  let previous = Sys.getenv_opt "TWINS_HTTP_COMPRESSION" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "TWINS_HTTP_COMPRESSION"
        (Option.value previous ~default:"gzip"))
    (fun () ->
      Unix.putenv "TWINS_HTTP_COMPRESSION" setting;
      operation ())

let target = Uri.of_string "https://twins.tsukuba.ac.jp/campusweb/fixture"

let test_negotiation () =
  List.iter
    (fun setting ->
      with_encoding setting (fun () ->
          let headers =
            Http_client.headers
              (Session.create ~path:"/unused/fixture" ())
              target
              (Cohttp.Header.init_with "accept-encoding" "br")
          in
          Alcotest.(check (option string))
            "only supported encoding advertised" (Some setting)
            (Cohttp.Header.get headers "accept-encoding")))
    [ "gzip"; "identity" ];
  with_encoding "private-invalid-option" (fun () ->
      let called = ref false in
      let send ~headers:_ _ _ _ =
        called := true;
        Lwt.return (200, Cohttp.Header.init (), payload)
      in
      let result =
        Internal_error.protect (fun () ->
            Lwt_main.run
              (Http_client.request_lwt ~send (Session.create ()) `GET target 8))
      in
      (match result with
      | Error (Error.Invalid_argument message) ->
          Alcotest.(check string)
            "fixed option error"
            "TWINS_HTTP_COMPRESSION must be gzip or identity" message
      | _ -> Alcotest.fail "expected invalid setting");
      Alcotest.(check bool) "invalid setting fails before network" false !called)

let send_fixture ?(meth = `GET) ?(status = `OK) headers body =
  let consumed = ref false in
  let call ?body:_ ~headers:_ _ _ =
    Lwt.return (Cohttp.Response.make ~status ~headers (), body)
  in
  let read_body body =
    consumed := true;
    Lwt.return body
  in
  let result =
    Internal_error.protect (fun () ->
        Lwt_main.run
          (Http_client.send_with ~call ~read_body
             ~headers:(Cohttp.Header.init ()) meth target None))
  in
  Alcotest.(check bool) "encoded body consumed on every path" true !consumed;
  result

let test_transport () =
  List.iter
    (fun (headers, wire) ->
      match send_fixture headers wire with
      | Ok (_, _, body) ->
          Alcotest.(check string) "transparent decode" payload body
      | Error _ -> Alcotest.fail "unexpected transport failure")
    [ (gzip_headers, gzip payload); (Cohttp.Header.init (), payload) ];
  List.iter
    (fun headers ->
      match send_fixture headers "broken private data" with
      | Error (Error.Protocol_error _) -> ()
      | _ -> Alcotest.fail "expected decode failure after consumption")
    [ gzip_headers; Cohttp.Header.init_with "content-encoding" "br" ];
  List.iter
    (fun result ->
      match result with
      | Ok (_, _, body) -> Alcotest.(check string) "bodyless response" "" body
      | Error _ -> Alcotest.fail "bodyless response should not decode")
    [
      send_fixture ~meth:`HEAD gzip_headers "";
      send_fixture ~status:`No_content gzip_headers "";
      send_fixture ~status:`Not_modified gzip_headers "";
    ]

let test_profile () =
  let report = ref `Null in
  let wire = gzip (String.make 10000 'x') in
  ignore
    (Profile.run ~enabled:true
       ~emit:(fun value -> report := value)
       (fun () -> send_fixture gzip_headers wire));
  let open Yojson.Safe.Util in
  let hop =
    !report |> member "profile" |> member "http" |> to_list |> List.hd
  in
  Alcotest.(check int)
    "bytes remains materialized output" 10000
    (hop |> member "bytes" |> to_int);
  Alcotest.(check int)
    "wireBytes excludes content expansion" (String.length wire)
    (hop |> member "wireBytes" |> to_int)

let () =
  Alcotest.run "HTTP content decoding"
    [
      ( "compression",
        [
          Alcotest.test_case "gzip and concatenated members" `Quick test_decode;
          Alcotest.test_case "optional gzip headers and FHCRC" `Quick
            test_optional_headers;
          Alcotest.test_case "truncated and corrupt gzip" `Quick
            test_invalid_gzip;
          Alcotest.test_case "identity and unsupported encodings" `Quick
            test_identity_and_unknown;
          Alcotest.test_case "bounded combined output" `Quick test_bound;
          Alcotest.test_case "request negotiation and invalid option" `Quick
            test_negotiation;
          Alcotest.test_case "transport consumes before decoding" `Quick
            test_transport;
          Alcotest.test_case "decoded and wire profile sizes" `Quick
            test_profile;
        ] );
    ]
