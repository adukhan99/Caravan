let () =
  let files = Sys.readdir "." in
  let out = open_out "all_tools.ml" in
  Printf.fprintf out "let all_tools : Caravan.Tool.packed_tool list = [\n";
  Array.iter (fun f ->
    if Filename.check_suffix f ".ml" && f <> "all_tools.ml" && f <> "gen_tools.ml"
       (* delegate.ml requires Eio net+clock at runtime; it is instantiated manually
          via Delegate.make in the entrypoint and must NOT appear in the static list. *)
       && f <> "delegate.ml" then
      let name = Filename.chop_suffix f ".ml" in
      let cap_name = String.capitalize_ascii name in
      let content =
        try
          let ic = open_in f in
          let len = in_channel_length ic in
          let s = really_input_string ic len in
          close_in ic; s
        with _ -> ""
      in
      if String.length content > 0 then
        (* Just a simple heuristic: if it mentions 'module CapName' or 'let execute' *)
        let module_str = "module " ^ cap_name in
        let has_mod = 
          let rec search i =
            if i + String.length module_str <= String.length content then
              if String.sub content i (String.length module_str) = module_str then true
              else search (i + 1)
            else false
          in search 0
        in
        if has_mod then
          Printf.fprintf out "  Caravan.Tool.Tool (module %s.%s);\n" cap_name cap_name
  ) files;
  Printf.fprintf out "]\n";
  close_out out
