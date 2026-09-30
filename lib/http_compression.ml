(* Fully consume the encoded HTTP body before decoding so the connection can be
   reused. Bound the combined output of every gzip member before appending it. *)
let max_decoded_bytes = 32 * 1024 * 1024

let malformed () =
  Internal_error.protocolf "TWINS returned an invalid gzip response"

let too_large () =
  Internal_error.protocolf "TWINS response exceeds the decoded size limit"

let gzip ~max_bytes source =
  let length = String.length source in
  let require position count =
    if position < 0 || count < 0 || position > length - count then malformed ()
  in
  let byte position =
    require position 1;
    Char.code source.[position]
  in
  let uint16 position = byte position lor (byte (position + 1) lsl 8) in
  let uint32 position =
    require position 4;
    String.get_int32_le source position
  in
  let rec terminated position =
    if byte position = 0 then position + 1 else terminated (position + 1)
  in
  let output = Buffer.create (min max_bytes 32768) in
  let chunk = Bytes.create 32768 in
  let rec member start =
    require start 10;
    if byte start <> 0x1f || byte (start + 1) <> 0x8b || byte (start + 2) <> 8
    then malformed ();
    let flags = byte (start + 3) in
    if flags land 0xe0 <> 0 then malformed ();
    let position = start + 10 in
    let position =
      if flags land 0x04 = 0 then position
      else
        let count = uint16 position in
        require (position + 2) count;
        position + 2 + count
    in
    let position =
      if flags land 0x08 = 0 then position else terminated position
    in
    let position =
      if flags land 0x10 = 0 then position else terminated position
    in
    let position =
      if flags land 0x02 = 0 then position
      else
        let checksum =
          Zlib.update_crc_string Int32.zero source start (position - start)
          |> fun value -> Int32.to_int (Int32.logand value 0xffffl)
        in
        if uint16 position <> checksum then malformed ();
        position + 2
    in
    let stream = Zlib.inflate_init false in
    let trailer, checksum, size =
      Fun.protect
        ~finally:(fun () -> Zlib.inflate_end stream)
        (fun () ->
          let rec inflate position checksum size =
            require position 1;
            let finished, used_in, used_out =
              Zlib.inflate_string stream source position (length - position)
                chunk 0 (Bytes.length chunk) Zlib.Z_SYNC_FLUSH
            in
            if used_out > max_bytes - Buffer.length output then too_large ();
            Buffer.add_subbytes output chunk 0 used_out;
            let checksum = Zlib.update_crc checksum chunk 0 used_out in
            let size = Int32.add size (Int32.of_int used_out) in
            let position = position + used_in in
            if finished then (position, checksum, size)
            else if used_in = 0 && used_out = 0 then malformed ()
            else inflate position checksum size
          in
          inflate position Int32.zero Int32.zero)
    in
    require trailer 8;
    if uint32 trailer <> checksum || uint32 (trailer + 4) <> size then
      malformed ();
    let next = trailer + 8 in
    if next < length then member next
  in
  (try member 0 with Zlib.Error _ -> malformed ());
  Buffer.contents output

let decode ?(max_bytes = max_decoded_bytes) headers body =
  if max_bytes < 0 then invalid_arg "negative decoded response size limit";
  let encoding =
    Cohttp.Header.get_multi headers "content-encoding"
    |> List.concat_map (String.split_on_char ',')
    |> List.map (fun value -> String.lowercase_ascii (String.trim value))
  in
  match encoding with
  | [] | [ "identity" ] ->
      if String.length body > max_bytes then too_large ();
      body
  | [ "gzip" ] -> gzip ~max_bytes body
  | _ ->
      Internal_error.protocolf "TWINS returned an unsupported content encoding"
