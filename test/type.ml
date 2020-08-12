module Parser = Minicaml.Parser
module Syntax = Minicaml.Syntax
module Eval = Minicaml.Eval
module Type = Minicaml.Type

let type_testable = Alcotest.testable Type.pprint_type ( = )
let parse = Eval.unsafeParse

let test_var () =
  let open Type in
  let tenv = defaultenv () in
  let tenv = ext tenv "x" TInt in
  let tenv = ext tenv "y" TBool in
  let tenv = ext tenv "z" TString in
  let tenv = ext tenv "x" TUnit in
  let table =
    [ "x", TUnit, tenv
    ; "y", TBool, tenv
    ; "z", TString, tenv
    ] [@ocamlformat "disable"]
  in
  List.iter
    (fun (exp, t, tenv) -> Alcotest.(check type_testable) exp t (check (parse exp) tenv))
    table
;;

let test_literals () =
  let open Type in
  let table =
    [ "1", TInt
    ; "true", TBool
    ; "()", TUnit
    ; {|"aaaa"|}, TString
    ] [@ocamlformat "disable"]
  in
  List.iter
    (fun (exp, t) ->
      Alcotest.(check type_testable) exp t (check (parse exp) @@ defaultenv ()))
    table
;;

let test_int_binop () =
  let open Type in
  let table =
    [ "1 + 2", TInt
    ; "-1 - 1", TInt
    ; "0 * 10", TInt
    ; "-1 / -2", TInt
    ; "1 > 20", TBool
    ; "1 < 20", TBool
    ; "1 = 1", TBool
    ]
  in
  List.iter
    (fun (exp, t) ->
      Alcotest.(check type_testable) exp t (check (parse exp) @@ defaultenv ()))
    table
;;

let test_if () =
  let open Type in
  let table =
    [ "if 1 then 1 else 1", None
    ; "if () then 1 else 1", None
    ; "if \"\" then 1 else 1", None
    ; "if (fun x -> x) then 1 else 1", None
    ; "if true then 1 else ()", None
    ; "if true then () else 1", None
    ; "if true then \"\" else true", None
    ; "if true then 1 else 1", Some TInt
    ; "if true then () else ()", Some TUnit
    ; "if true then \"\" else \"\"", Some TString
    ; "if true then true else false", Some TBool
    ]
  in
  List.iter
    (fun (exp, t) ->
      let got =
        try Some (check (parse exp) @@ defaultenv ()) with
        | _ -> None
      in
      Alcotest.(check (option type_testable)) exp t got)
    table
;;

let test_fun () =
  let open Type in
  let etenv = defaultenv () in
  let tenv = etenv in
  let tenv = ext tenv "print" @@ TArrow (TString, TUnit) in
  let table =
    [ {|print "hello"|}, Some TUnit, tenv
    ; "fun x -> if true then x else 100", Some (TArrow (TInt, TInt)), ext etenv "x" TInt
    ; "fun x -> if true then x else 100", None, ext (defaultenv ()) "x" TBool
    ; ( "(fun x -> if true then x else 100) (if true then y else 200)"
      , Some TInt
      , ext (ext etenv "x" TInt) "y" TInt )
    ; ( "fun f -> (fun x -> f (f (f x + 10)))"
      , Some (TArrow (TArrow (TInt, TInt), TArrow (TInt, TInt)))
      , let tenv = ext etenv "f" @@ TArrow (TInt, TInt) in
        let tenv = ext tenv "x" @@ TInt in
        tenv )
    ]
  in
  List.iter
    (fun (exp, t, tenv) ->
      let got =
        try Some (check (parse exp) tenv) with
        | _ -> None
      in
      Alcotest.(check (option type_testable)) exp t got)
    table
;;

let test_let () =
  let open Type in
  let etenv = defaultenv () in
  let tenv = etenv in
  let table = [ "let x = 1 in x", Some TInt, tenv
                [@ocamlformat "disable"] ] in
  List.iter
    (fun (exp, t, tenv) ->
      let got =
        try Some (check (parse exp) tenv) with
        | _ -> None
      in
      Alcotest.(check (option type_testable)) exp t got)
    table
;;

let () =
  Alcotest.run
    "Type"
    [ ( "check"
      , [ Alcotest.test_case "var" `Quick test_var
        ; Alcotest.test_case "literals" `Quick test_literals
        ; Alcotest.test_case "int_binop" `Quick test_int_binop
        ; Alcotest.test_case "if" `Quick test_if
        ; Alcotest.test_case "fun" `Quick test_fun
        ; Alcotest.test_case "let" `Quick test_let
        ] )
    ]
;;
