module Parser = Minicaml.Parser
module Syntax = Minicaml.Syntax
module Eval = Minicaml.Eval
module Type = Minicaml.Type

let normalize_ty t =
  let open Type in
  let new_tyvar n =
    let _, tv = Tyvar.from_age n in
    TVar tv
  in
  let tvars = List.sort_uniq Tyvar.compare @@ freetyvar_ty t in
  let new_tvars = List.init (List.length tvars) new_tyvar in
  let subst = List.map2 (fun tvar new_tvar -> tvar, new_tvar) tvars new_tvars in
  subst_ty subst t
;;

let normalize_eq t1 t2 =
  let t1 = normalize_ty t1 in
  let t2 = normalize_ty t2 in
  t1 = t2
;;

let type_testable = Alcotest.testable Type.pprint_type ( = )
let type_testable_normalize = Alcotest.testable Type.pprint_type normalize_eq
let parse = Eval.unsafeParse

let infer_test ?(normalize = false) ?(print_error = false) name exp tenv want =
  let got =
    try
      let _, got = Type.infer tenv (parse exp) in
      Some got
    with
    | e ->
      if print_error then Fmt.pr "%s%a\n" (Printexc.to_string e) Fmt.flush ();
      None
  in
  let testable' =
    if normalize then type_testable_normalize else type_testable
  in
  Alcotest.(check (option testable')) name want got
;;

let test_var () =
  let open Type in
  let tenv = defaultenv () in
  let tenv = ext tenv "x" (ty_of_scheme TInt) in
  let tenv = ext tenv "y" (ty_of_scheme TBool) in
  let tenv = ext tenv "z" (ty_of_scheme TString) in
  let tenv = ext tenv "x" (ty_of_scheme TUnit) in
  let table =
    [ "x", TUnit, tenv
    ; "y", TBool, tenv
    ; "z", TString, tenv
    ] [@ocamlformat "disable"]
  in
  List.iter
    (fun (exp, t, tenv) ->
      let _, got = infer tenv (parse exp) in
      Alcotest.(check type_testable) exp t got)
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
      let _, got = infer (defaultenv ()) (parse exp) in
      Alcotest.(check type_testable) exp t got)
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
      let _, got = infer (defaultenv ()) (parse exp) in
      Alcotest.(check type_testable) exp t got)
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
  List.iter (fun (exp, want) -> infer_test exp exp (defaultenv ()) want) table
;;

let test_fun () =
  let open Type in
  let etenv = defaultenv () in
  let tenv = etenv in
  let tenv = ext tenv "print" @@ ty_of_scheme (TArrow (TString, TUnit)) in
  let table =
    [ {|print "hello"|}, Some TUnit, tenv
    ; ( "fun x -> if true then x else 100"
      , Some (TArrow (TInt, TInt))
      , ext etenv "x" (ty_of_scheme TInt) )
    ; ( "(fun x -> if true then x else 100) (if true then y else 200)"
      , Some TInt
      , ext (ext etenv "x" (ty_of_scheme TInt)) "y" (ty_of_scheme TInt) )
    ; ( "fun f -> (fun x -> f (f (f x + 10)))"
      , Some (TArrow (TArrow (TInt, TInt), TArrow (TInt, TInt)))
      , let tenv = ext etenv "f" @@ ty_of_scheme (TArrow (TInt, TInt)) in
        let tenv = ext tenv "x" @@ ty_of_scheme TInt in
        tenv )
    ; "(fun x -> x) true", Some TBool, defaultenv ()
    ; "(fun x -> x + 1)", Some (TArrow (TInt, TInt)), defaultenv ()
    ]
  in
  List.iter (fun (exp, want, tenv) -> infer_test exp exp tenv want) table
;;

let test_let () =
  let open Type in
  let etenv = defaultenv () in
  let tenv = etenv in
  let table =
    [ "let x = 1 in x", Some TInt, tenv
    ; "let id = fun x -> x in id 1", Some TInt, tenv
    ; "let id = fun x -> x + 1 in id", Some (TArrow (TInt, TInt)), tenv
    ; ( {|let f = fun x ->
            let g = fun y -> x + y in
            g 100 in
          f|}
      , Some (TArrow (TInt, TInt))
      , tenv )
    ; ( {|let hd = fun l -> match l with
            | [] -> failwith "hd"
            | h :: _ -> h
          in hd [1]|}
      , Some TInt
      , tenv )
    ; ( {|let f =
            let x = 100 in
            let y = 200 in
            x + y in
          x|}
      , None
      , tenv )
    ; "let rec f x = x + 1 in x", None, tenv
    ; ( "let trueFn = fun x -> true in [trueFn 1; trueFn bool; trueFn ()]"
      , Some (TList TBool)
      , ext (defaultenv ()) "bool" (ty_of_scheme @@ TVar ("a", -10)) )
    ]
  in
  List.iter (fun (exp, want, tenv) -> infer_test exp exp tenv want) table
;;

let test_letrec () =
  let open Type in
  let etenv = defaultenv () in
  let n = -10 in
  let n, ta = Tyvar.from_age n in
  let _, tb = Tyvar.from_age n in
  let tenv = etenv in
  let tenv = ext tenv "a" (ty_of_scheme @@ TVar ta) in
  let tenv = ext tenv "b" (ty_of_scheme @@ TVar tb) in
  let table =
    [ "let rec id x = x in id 1", Some TInt, etenv
    ; ( "let rec fact n = if n = 0 then 1 else n * fact (n - 1) in fact 5"
      , Some TInt
      , etenv )
    ; ( {|
      let rec fact n = fun k ->
        if n = 0 then k 1
        else fact (n - 1) (fun x ->
             k (x * n))
      in fact 5 (fun x -> x)
      |}
      , Some TInt
      , etenv )
    ; "let rec loop x = loop x in loop", Some (TArrow (TVar ta, TVar tb)), tenv
    ; "let rec id x = x in id id", Some (TArrow (TVar ta, TVar ta)), etenv
    ]
  in
  List.iter
    (fun (exp, want, tenv) ->
      infer_test ~normalize:true ~print_error:true exp exp tenv want)
    table
;;

let test_list () =
  let open Type in
  let _, ta = Tyvar.from_age 0 in
  let table =
    [ "[]", Some (TList (TVar ta))
    ; "[false]", Some (TList TBool)
    ; "[1; 2; 3; 4; 5]", Some (TList TInt)
    ; "let x = 1 in [x]", Some (TList TInt)
    ; "[1; false]", None
    ; "[1; false; 1]", None
    ]
  in
  List.iter (fun (exp, want) -> infer_test exp exp (defaultenv ()) want) table
;;

let test_tuple () =
  let open Type in
  let table =
    [ "<1, 2>", Some (TTuple [TInt; TInt])
    ; "<true, false>", Some (TTuple [TBool; TBool])
    ; "<1, true>", Some (TTuple [TInt; TBool])
    ; "<1, true, 2>", Some (TTuple [TInt; TBool; TInt])
    ; "let x = 1 in <x, x>", Some (TTuple [TInt; TInt])
    ; "<>", None
    ; "<1>", None
    ]
  in
  List.iter (fun (exp, want) -> infer_test exp exp (defaultenv ()) want) table
;;

let test_match () =
  let open Type in
  let _, ta = Tyvar.from_age 0 in
  let _, tx = Tyvar.from_age 1 in
  let _, ty = Tyvar.from_age 2 in
  let table =
    [ "match true with x -> x", Some TBool
    ; "match true with | 1 -> 1 | 2 -> 2", None
    ; "match x' with | 1 -> 1 | 2 -> 2", Some TInt
    ; "match x' with | 1 -> 1 | _ -> y'", Some TInt
    ; "match [] with | [] -> 1 | h :: tl -> h", Some TInt
    ; "match [1; 2; 3] with | [] -> failwith \"fail\" | h :: _ -> h", Some TInt
    ; "fun x -> match 1 with x -> x", Some (TArrow (TVar ta, TInt))
    ; "fun x -> match 1 with | x -> x | _ -> x + 10", Some (TArrow (TInt, TInt))
    ; "match [true; false] with | x :: [] -> x | x -> false", Some TBool
    ]
  in
  let tenv = defaultenv () in
  let tenv = ext tenv "x'" (ty_of_scheme @@ TVar tx) in
  let tenv = ext tenv "y'" (ty_of_scheme @@ TVar ty) in
  List.iter
    (fun (exp, want) -> infer_test ~print_error:true exp exp tenv want)
    table
;;

let () =
  Alcotest.run
    "Type"
    [ ( "infer"
      , [ Alcotest.test_case "var" `Quick test_var
        ; Alcotest.test_case "literals" `Quick test_literals
        ; Alcotest.test_case "int_binop" `Quick test_int_binop
        ; Alcotest.test_case "if" `Quick test_if
        ; Alcotest.test_case "fun" `Quick test_fun
        ; Alcotest.test_case "let" `Quick test_let
        ; Alcotest.test_case "letrec" `Quick test_letrec
        ; Alcotest.test_case "list" `Quick test_list
        ; Alcotest.test_case "tuple" `Quick test_tuple
        ; Alcotest.test_case "match" `Quick test_match
        ] )
    ]
;;
