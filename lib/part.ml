(*
 * Copyright (c) 2018 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

module Part = struct
  type t = {
    name : string;
    sep_indent : string;  (** Whitespaces before the [@@@part] separator *)
    body : string;
  }

  let v ~name ~sep_indent ~body = { name; sep_indent; body }
  let name { name; _ } = name
  let sep_indent { sep_indent; _ } = sep_indent
  let body { body; _ } = body
end

(** Remove empty strings at the beginning of a list *)
let rec remove_empty_heads = function
  | "" :: tl -> remove_empty_heads tl
  | l -> l

let trim_empty_rev l = remove_empty_heads (List.rev (remove_empty_heads l))

module Parse_parts = struct
  type part_meta = { sep_indent : string; name : string }

  type t =
    | Content of string
    | Compat_attr of part_meta
    (* ^^^^ This is for compat with the [[@@@part name]] delimiters *)
    | Part_begin of part_meta
    | Part_end

  let next_part ~name ~sep_indent ~is_begin_end_part lines_rev =
    let body =
      if is_begin_end_part then String.concat "\n" (List.rev lines_rev)
      else "\n" ^ String.concat "\n" (trim_empty_rev lines_rev)
    in
    Part.v ~name ~sep_indent ~body

  let anonymous_part = next_part ~name:"" ~sep_indent:""

  let parse_line line =
    match Ocaml_delimiter.parse line with
    | Ok [] -> [ Content line ]
    | Ok delimiters ->
        List.map
          (function
            | Ocaml_delimiter.Content s -> Content s
            | Ocaml_delimiter.Part_begin
                (syntax, { indent = sep_indent; payload = name }) -> (
                match syntax with
                | Attr -> Compat_attr { name; sep_indent }
                | Cmt -> Part_begin { name; sep_indent })
            | Part_end -> Part_end)
          delimiters
    | Error (`Msg msg) ->
        Fmt.epr "Warning: %s\n" msg;
        [ Content line ]

  let parsed_input_line i =
    match input_line i with
    | exception End_of_file -> None
    | line -> Some (parse_line line)

  let parsed_list i =
    let rec loop xs =
      match parsed_input_line i with
      | None -> List.rev xs
      | Some inputs ->
          let xs = List.rev_append inputs xs in
          loop xs
    in
    loop []

  let parse_parts input =
    let open Util.Result.Infix in
    let* parts, make_part, current_part, part_lines, lineno =
      List.fold_left
        (fun acc parse_part ->
          let* parts, make_part, current_part, part_lines, lineno = acc in
          let lineno = lineno + 1 in
          match (parse_part, current_part) with
          | Content line, _ ->
              Ok (parts, make_part, current_part, line :: part_lines, lineno)
          | Part_end, Some _ ->
              let part = make_part ~is_begin_end_part:true part_lines in
              Ok (part :: parts, anonymous_part, None, [], lineno)
          | Part_end, None -> Error ("There is no part to end.", lineno)
          | Part_begin { name; sep_indent }, None ->
              let named_part = next_part ~name ~sep_indent in
              let parts =
                match part_lines with
                | [] ->
                    (* Ignore empty anonymous parts: needed for legacy support *)
                    parts
                | _ ->
                    let part = make_part ~is_begin_end_part:true part_lines in
                    part :: parts
              in
              Ok (parts, named_part, Some name, [], lineno)
          | Compat_attr { name; sep_indent }, None ->
              let named_part = next_part ~name ~sep_indent in
              let part = make_part ~is_begin_end_part:false part_lines in
              Ok (part :: parts, named_part, None, [], lineno)
          | Part_begin _, Some p | Compat_attr _, Some p ->
              let msg = Printf.sprintf "Part %s has no end." p in
              Error (msg, lineno))
        (Ok ([], anonymous_part, None, [], 0))
        input
    in
    let* part =
      match current_part with
      | Some part ->
          let msg = Printf.sprintf "File ended before part %s ended." part in
          Error (msg, lineno + 1)
      | None -> Ok (make_part ~is_begin_end_part:true part_lines)
    in
    part :: parts |> List.rev |> Result.ok

  let of_file name =
    let channel = open_in name in
    let input = parsed_list channel in
    match parse_parts input with
    | Ok parts -> parts
    | Error (msg, line) -> Fmt.failwith "In file %s, line %d: %s" name line msg
end

type file = Part.t list

let read file = Parse_parts.of_file file

let find file ~part =
  match part with
  | Some part -> (
      match List.find_opt (fun p -> String.equal (Part.name p) part) file with
      | Some p -> Some [ Part.body p ]
      | None -> None)
  | None ->
      List.fold_left (fun acc p -> Part.body p :: acc) [] file |> List.rev
      |> fun x -> Some x

let rec replace_or_append part_name body = function
  | p :: tl when String.equal (Part.name p) part_name -> { p with body } :: tl
  | p :: tl -> p :: replace_or_append part_name body tl
  | [] -> [ { name = part_name; sep_indent = ""; body } ]

let replace file ~part ~lines =
  let part = match part with None -> "" | Some p -> p in
  replace_or_append part (String.concat "\n" lines) file

let contents file =
  let lines =
    List.fold_left
      (fun acc p ->
        let body = Part.body p in
        match Part.name p with
        | "" -> body :: acc
        | n ->
            let indent = Part.sep_indent p in
            body :: ("\n" ^ indent ^ "[@@@part \"" ^ n ^ "\"] ;;\n") :: acc)
      [] file
  in
  let lines = List.rev lines in
  let lines = String.concat "\n" lines in
  String.trim lines ^ "\n"
