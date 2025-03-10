open Syntax

module Tyvar = struct
  type t = string * int

  let name (n, _) = n
  let age (_, a) = a
  let compare t1 t2 = compare (age t1) (age t2)
  let from_age n = n + 1, ("'a" ^ string_of_int n, n)
end

module TyvarSet = Set.Make (Tyvar)

type tyvar = Tyvar.t

type ty =
  | TInt
  | TBool
  | TString
  | TUnit
  | TArrow of ty * ty
  | TVar of tyvar
  | TList of ty
  | TTuple of ty list

type scheme = TScheme of tyvar list * ty

let pprint_tyvar ppf t = Fmt.pf ppf "%s" (Tyvar.name t)
let ty_of_scheme t = TScheme ([], t)

let type_name = function
  | TInt -> "int"
  | TBool -> "bool"
  | TString -> "string"
  | TUnit -> "unit"
  | TArrow _ -> "fun"
  | TVar _ -> "tvar"
  | TList _ -> "list"
  | TTuple _ -> "tuple"
;;

let rec pprint_type ppf t =
  let tname = type_name t in
  match t with
  | TInt | TBool | TString | TUnit -> Fmt.pf ppf "%s" tname
  | TArrow (t1, t2) ->
    Fmt.pf ppf "@[<v 2>%s@ %a->@ %a@]" tname pprint_type t1 pprint_type t2
  | TVar x -> Fmt.pf ppf "@[<v 2>%s(%s)@]" tname (Tyvar.name x)
  | TList t -> Fmt.pf ppf "@[<v 2>%s@ %a@]" tname pprint_type t
  | TTuple ts ->
    Fmt.pf ppf "@[<v 2>%s@ %a@]" tname (Fmt.list ~sep:Fmt.comma pprint_type) ts
;;

let pprint_scheme ppf ts =
  match ts with
  | TScheme ([], t) -> pprint_type ppf t
  | TScheme (tyvars, t) ->
    Fmt.pf
      ppf
      "@[<v 2>forall %a.@ %a@]"
      (Fmt.list ~sep:Fmt.comma pprint_tyvar)
      tyvars
      pprint_type
      t
;;

type tyenv = (string * scheme) list
type tysubst = (tyvar * ty) list

type ctx =
  { tenv : tyenv
  ; n : int
  }

let new_typevar ctx =
  let n, tvar = Tyvar.from_age ctx.n in
  { ctx with n }, TVar tvar
;;

let%test "new_typevar" =
  let ctx = { tenv = []; n = 0 } in
  let { n; _ }, _ = new_typevar ctx in
  n = 1
;;

let emptytenv () = []
let lookup = Eval.lookup
let ext = Eval.ext

let lookup_by_age tvar subst =
  let age = Tyvar.age tvar in
  List.find_map
    (fun (tvar, ty) -> if age = Tyvar.age tvar then Some ty else None)
    subst
;;

let remove x tenv = List.remove_assoc x tenv

let%test "remove" =
  let tenv = emptytenv () in
  let tenv = ext tenv "x" TInt in
  let tenv = ext tenv "y" TInt in
  let tenv' = ext tenv "x" TBool in
  remove "x" tenv' = tenv
;;

let defaultenv () =
  let _, ta = Tyvar.from_age (-1) in
  let tenv = emptytenv () in
  let tenv =
    ext tenv "failwith" (TScheme ([ ta ], TArrow (TString, TVar ta)))
  in
  let tenv =
    ext tenv "List.hd" (TScheme ([ ta ], TArrow (TList (TVar ta), TVar ta)))
  in
  let tenv =
    ext
      tenv
      "List.tl"
      (TScheme ([ ta ], TArrow (TList (TVar ta), TList (TVar ta))))
  in
  tenv
;;

let esubst : tysubst = []

let freevar e =
  let rec freevar e k =
    match e with
    | Var x -> k [ x ]
    | Cons (hd, tl) ->
      freevar hd @@ fun vars1 ->
      freevar tl @@ fun vars2 -> k @@ List.concat [ vars1; vars2 ]
    | Unit | IntLit _ | BoolLit _ | StrLit _ | _ -> k []
  in
  freevar e (fun x -> x)
;;

let%test "freevar" = freevar (Var "x") = [ "x" ]

let%test "freevar2" =
  freevar (Cons (Var "x", Cons (Var "y", Empty))) = [ "x"; "y" ]
;;

let list_diff l1 l2 =
  let module SS = TyvarSet in
  let s1 = SS.of_list l1 in
  let s2 = SS.of_list l2 in
  let ret = SS.diff s1 s2 in
  SS.elements ret
;;

let list_inter l1 l2 =
  let module SS = TyvarSet in
  let s1 = SS.of_list l1 in
  let s2 = SS.of_list l2 in
  let ret = SS.inter s1 s2 in
  SS.elements ret
;;

let list_uniq l =
  let module SS = TyvarSet in
  let s = SS.of_list l in
  SS.elements s
;;

let rec freetyvar_ty t =
  match t with
  | TInt | TBool | TString | TUnit -> []
  | TArrow (t1, t2) -> List.concat [ freetyvar_ty t1; freetyvar_ty t2 ]
  | TVar x -> [ x ]
  | TList t -> freetyvar_ty t
  | TTuple ts -> List.concat_map freetyvar_ty ts
;;

let freetyvar_sc ts =
  match ts with
  | TScheme (tyvars, t) -> list_diff (freetyvar_ty t) tyvars
;;

let rec freetyvar_tyenv tenv =
  match tenv with
  | [] -> []
  | (_, t) :: tenv -> List.concat [ freetyvar_sc t; freetyvar_tyenv tenv ]
;;

let substitute tvar t tenv =
  List.map (fun (x, t') -> if t' = tvar then x, t else x, t') tenv
;;

let occurs tx t =
  let rec occurs tx t k =
    match t with
    | TArrow (t1, t2) ->
      occurs tx t1 @@ fun r1 ->
      occurs tx t2 @@ fun r2 -> k (r1 || r2)
    | _ when t = tx -> k true
    | _ -> k false
  in
  occurs tx t (fun x -> x)
;;

let%test "occurs" = occurs TInt (TArrow (TInt, TBool))

let rec subst_ty subst t =
  match t with
  | TInt -> TInt
  | TBool -> TBool
  | TString -> TString
  | TUnit -> TUnit
  | TArrow (from_t, to_t) -> TArrow (subst_ty subst from_t, subst_ty subst to_t)
  | TVar x ->
    (match lookup_by_age x subst with
     | None -> TVar x
     | Some t -> t)
  | TList t -> TList (subst_ty subst t)
  | TTuple ts -> TTuple (List.map (subst_ty subst) ts)
;;

let%test "subst_ty: simple" =
  let _, tx = Tyvar.from_age 0 in
  let subst = emptytenv () in
  let subst = ext subst tx TInt in
  subst_ty subst (TVar tx) = TInt
;;

let%test "subst_ty: complex" =
  let _, tx = Tyvar.from_age 0 in
  let _, ty = Tyvar.from_age 1 in
  let subst = emptytenv () in
  let subst = ext subst tx TInt in
  let subst = ext subst ty TBool in
  subst_ty subst (TArrow (TVar tx, TVar ty)) = TArrow (TInt, TBool)
;;

let subst_tvars (subst : tysubst) tvars =
  List.map
    (fun tvar ->
      match List.assoc_opt tvar subst with
      | Some (TVar y) -> y
      | _ -> tvar)
    tvars
;;

let%test "subst_tyvars" =
  let _, tx = Tyvar.from_age 0 in
  let _, ty = Tyvar.from_age 1 in
  let _, tz = Tyvar.from_age 2 in
  subst_tvars [ tx, TVar tz ] [ tx; ty ] = [ tz; ty ]
;;

let vars_of_subst (subst : tysubst) =
  list_uniq
  @@ List.flatten
  @@ List.map (fun (x, t) -> x :: freetyvar_ty t) subst
;;

let%test "vars_of_subst" =
  let _, tx = Tyvar.from_age 0 in
  let _, ty = Tyvar.from_age 1 in
  let _, tz = Tyvar.from_age 2 in
  let subst = emptytenv () in
  let subst = ext subst tx TInt in
  let subst = ext subst ty @@ TList (TVar tz) in
  vars_of_subst subst = [ tx; ty; tz ]
;;

let subst_ts subst ts ctx =
  match ts with
  | TScheme (tvars, t) ->
    (* [tvars] are the binding variables *)
    (* the variables in [t] other than the ones in [tvars] are the free
       variables *)
    let collisionvars = list_inter tvars @@ vars_of_subst subst in
    (* the variables (wrongly) captured ones *)
    let ctx, subst' =
      (* generate a mapping from captured vars to fresh variables *)
      List.fold_left
        (fun (ctx, subst') var ->
          let ctx, newvar = new_typevar ctx in
          let subst' = (var, newvar) :: subst' in
          ctx, subst')
        (ctx, [])
        collisionvars
    in
    (* now the [tvars] do not collide with the variables from subst *)
    let tvars = subst_tvars subst' tvars in
    (* update [t] accordingly *)
    let t = subst_ty subst' t in
    (* Why do we change the variables of [TScheme] rather than those of
       [subst]? *)
    (* This is because [subst] has more global effect, while the [tvars] only
       affect [t], that is, has more local effect. *)
    (* Now substitute free variables of in [t] *)
    let t = subst_ty subst t in
    ctx, TScheme (tvars, t)
;;

let%test "subst_ts" =
  let _, tx = Tyvar.from_age 0 in
  let _, ty = Tyvar.from_age 1 in
  let _, tz = Tyvar.from_age 2 in
  let subst = emptytenv () in
  let subst = ext subst tx TInt in
  let subst = ext subst ty @@ TList (TVar tz) in
  let ts = TScheme ([ tx ], TArrow (TVar tx, TVar ty)) in
  (* age should respect [tz]; should start greater than 2 *)
  let ctx = { tenv = []; n = 3 } in
  let newtx =
    match new_typevar ctx with
    | _, TVar tx -> tx
    | _ -> assert false
  in
  let _, ts = subst_ts subst ts ctx in
  (* pprint_scheme Format.std_formatter ts; *)
  ts = TScheme ([ newtx ], TArrow (TVar newtx, TList (TVar tz)))
;;

let subst_tyenv subst ctx =
  List.fold_right
    (fun (x, ts) ctx ->
      let ctx, ts = subst_ts subst ts ctx in
      let tenv = ext ctx.tenv x ts in
      { ctx with tenv })
    ctx.tenv
    { ctx with tenv = defaultenv () }
;;

let subst_eql subst eql =
  List.map (fun (t1, t2) -> subst_ty subst t1, subst_ty subst t2) eql
;;

(** [compose_subst θ2 θ1] is an encoding of θ2 o θ1 *)
let compose_subst subst2 subst1 =
  let subst1' = List.map (fun (tx, t) -> tx, subst_ty subst2 t) subst1 in
  List.fold_left
    (fun subst (x, t) ->
      match lookup_by_age x subst1 with
      | Some _ -> subst
      | None -> (x, t) :: subst)
    subst1'
    subst2
;;

let unify eql =
  let rec solve eql subst =
    match eql with
    | [] -> Ok subst
    | (t1, t2) :: eql ->
      if t1 = t2
      then solve eql subst
      else (
        match t1, t2 with
        | TArrow (from1, to1), TArrow (from2, to2) ->
          solve ((from1, from2) :: (to1, to2) :: eql) subst
        | TList t1, TList t2 -> solve ((t1, t2) :: eql) subst
        | TVar x, _ ->
          if occurs t1 t2
          then
            Error
              (Fmt.str "type %s contains a reference to itself" (type_name t2))
          else solve (subst_eql [ x, t2 ] eql) (compose_subst [ x, t2 ] subst)
        | _, TVar x ->
          if occurs t2 t1
          then
            Error
              (Fmt.str "type %s contains a reference to itself" (type_name t1))
          else solve (subst_eql [ x, t1 ] eql) (compose_subst [ x, t1 ] subst)
        | _, _ ->
          Error
            (Fmt.str
               "@[expected %s but got %s:@ One: %a@ Another: %a@]"
               (type_name t1)
               (type_name t2)
               pprint_type
               t1
               pprint_type
               t2))
  in
  match solve eql [] with
  | Error message -> failwith @@ "unify failed: " ^ message
  | Ok subst -> subst
;;

let%test "unify_1" =
  let n = 0 in
  let n, t0 = Tyvar.from_age n in
  let n, t1 = Tyvar.from_age n in
  let _, t2 = Tyvar.from_age n in
  let subst = unify [ TVar t0, TVar t1; TVar t0, TVar t2 ] in
  [ t1, TVar t2; t0, TVar t2 ] = subst
;;

let%test "unify_2" =
  let n = 0 in
  let n, t0 = Tyvar.from_age n in
  let n, t1 = Tyvar.from_age n in
  let _, t2 = Tyvar.from_age n in
  let subst = unify [ TVar t0, TVar t1; TVar t1, TVar t2 ] in
  [ t1, TVar t2; t0, TVar t2 ] = subst
;;

(** Polymorphic type always instantiate fresh variables for bound type variables *)
let instantiate ts ctx =
  match ts with
  | TScheme (tvars, t) ->
    let ctx, subst =
      List.fold_left
        (fun (ctx, subst) tvar ->
          let ctx, newtvar = new_typevar ctx in
          let subst = ext subst tvar newtvar in
          ctx, subst)
        (ctx, [])
        tvars
    in
    let t = subst_ty subst t in
    ctx, t
;;

let generalize t tenv =
  let tvars = list_diff (freetyvar_ty t) (freetyvar_tyenv tenv) in
  TScheme (tvars, t)
;;

let%test "generalize: simple" =
  generalize TInt (emptytenv ()) = TScheme ([], TInt)
;;

let%test "generalize: complex" =
  let ta = "a", 0 in
  let tb = "b", 1 in
  let tenv = emptytenv () in
  let tenv = ext tenv "xxxxx" (TScheme ([], TVar ta)) in
  let t = TArrow (TVar ta, TVar tb) in
  generalize t tenv = TScheme ([ tb ], t)
;;

let rec infer ctx e =
  match e with
  | Var x ->
    (match lookup x ctx.tenv with
     | Some ts ->
       let ctx, t = instantiate ts ctx in
       ctx.n, t, esubst
     | None -> failwith @@ "failed to lookup type of var " ^ x)
  | Unit -> ctx.n, TUnit, esubst
  | IntLit _ -> ctx.n, TInt, esubst
  | BoolLit _ -> ctx.n, TBool, esubst
  | StrLit _ -> ctx.n, TString, esubst
  | FailWith _ ->
    let ctx, tvar = new_typevar ctx in
    ctx.n, tvar, esubst
  | Plus (e1, e2) | Minus (e1, e2) | Times (e1, e2) | Div (e1, e2) ->
    binop_infer ctx e1 e2 (fun (t1, t2) -> [ t1, TInt; t2, TInt ]) TInt
  | Greater (e1, e2) | Less (e1, e2) ->
    binop_infer ctx e1 e2 (fun (t1, t2) -> [ t1, TInt; t2, TInt ]) TBool
  | Not e1 -> prefixop_infer ctx e1 TBool TBool
  | Eq (e1, e2) -> binop_infer ctx e1 e2 (fun (t1, t2) -> [ t1, t2 ]) TBool
  | If (c, et, ef) ->
    let n, ct, subst = infer ctx c in
    let subst_c = unify [ ct, TBool ] in
    let subst = compose_subst subst_c subst in
    let ctx = subst_tyenv subst { ctx with n } in
    let n, tt, subst_t = infer ctx et in
    let subst = compose_subst subst_t subst in
    let ctx = subst_tyenv subst_t { ctx with n } in
    let n, tf, subst_f = infer ctx ef in
    let subst = compose_subst subst_f subst in
    let tt = subst_ty subst_f tt in
    let subst_r = unify [ tt, tf ] in
    let subst = compose_subst subst_r subst in
    let tf = subst_ty subst_r tf in
    n, tf, subst
  | Fun (x, e) ->
    let ctx, tvar = new_typevar ctx in
    let tenv = ext ctx.tenv x (ty_of_scheme tvar) in
    let n, t, subst = infer { ctx with tenv } e in
    let tvar = subst_ty subst tvar in
    n, TArrow (tvar, t), subst
  | App (e1, e2) ->
    let n, t1, subst1 = infer ctx e1 in
    let ctx = subst_tyenv subst1 { ctx with n } in
    let n, t2, subst2 = infer ctx e2 in
    let ctx, tvar = new_typevar { ctx with n } in
    let t1 = subst_ty subst2 t1 in
    let subst3 = unify [ t1, TArrow (t2, tvar) ] in
    let tvar = subst_ty subst3 tvar in
    ctx.n, tvar, compose_subst subst3 (compose_subst subst2 subst1)
  | Let (x, e1, e2) ->
    let n, t1, subst1 = infer ctx e1 in
    let ctx = subst_tyenv subst1 { ctx with n } in
    let s1 = generalize t1 ctx.tenv in
    let tenv = ext ctx.tenv x s1 in
    let n, t2, subst2 = infer { ctx with tenv } e2 in
    n, t2, compose_subst subst2 subst1
  | LetRec (f, x, e1, e2) ->
    let ctx, tvar_fn = new_typevar ctx in
    let ctx, tvar_arg = new_typevar ctx in
    let tenv_original = ctx.tenv in
    let tenv = ext tenv_original f (ty_of_scheme tvar_fn) in
    let tenv = ext tenv x (ty_of_scheme tvar_arg) in
    let n, t1, subst = infer { ctx with tenv } e1 in
    let tvar_fn = subst_ty subst tvar_fn in
    let tvar_arg = subst_ty subst tvar_arg in
    let subst' = unify [ tvar_fn, TArrow (tvar_arg, t1) ] in
    let subst = compose_subst subst' subst in
    let ctx = subst_tyenv subst { n; tenv = tenv_original } in
    let tenv = ctx.tenv in
    let tvar_fn = subst_ty subst' tvar_fn in
    let tvar_fn = generalize tvar_fn tenv in
    let tenv = ext tenv f tvar_fn in
    let n, t2, subst' = infer { ctx with tenv } e2 in
    n, t2, compose_subst subst' subst
  | Match (e1, cases) ->
    let loop (subst, ctx, bt, t1) (p, b) =
      let vars = freevar p in
      let ctx =
        List.fold_left
          (fun ctx var ->
            let ctx, tvar = new_typevar ctx in
            let tenv = ext ctx.tenv var (ty_of_scheme tvar) in
            { ctx with tenv })
          ctx
          vars
      in
      let n, pt, subst' = infer ctx p in
      let subst = compose_subst subst' subst in
      let subst' = unify [ t1, pt ] in
      let subst = compose_subst subst' subst in
      let ctx = subst_tyenv subst { ctx with n } in
      let n, bt', subst' = infer ctx b in
      let subst = compose_subst subst' subst in
      let subst' = unify [ bt, bt' ] in
      let subst = compose_subst subst' subst in
      let t1 = subst_ty subst t1 in
      let bt = subst_ty subst bt in
      let tenv =
        List.fold_left (fun tenv var -> remove var tenv) ctx.tenv vars
      in
      subst, { n; tenv }, bt, t1
    in
    let n, t1, subst = infer ctx e1 in
    let ctx, bt = new_typevar { ctx with n } in
    let subst, ctx, bt, _ = List.fold_left loop (subst, ctx, bt, t1) cases in
    ctx.n, bt, subst
  | Empty ->
    let ctx, tvar = new_typevar ctx in
    ctx.n, TList tvar, esubst
  | Cons (e1, e2) ->
    let n, t1, subst1 = infer ctx e1 in
    let n, t2, subst2 = infer { ctx with n } e2 in
    let t1 = subst_ty subst2 t1 in
    let subst = compose_subst subst2 subst1 in
    let subst' = unify [ t2, TList t1 ] in
    let subst = compose_subst subst' subst in
    let t2 = subst_ty subst' t2 in
    n, t2, subst
  | Tuple es ->
    let _, subst, { n; _ }, ts =
      List.fold_left
        (fun (subst_prev, subst_acc, ctx, ts) e ->
          let ts = List.map (subst_ty subst_prev) ts in
          let ctx = subst_tyenv subst_prev ctx in
          let n, t, subst = infer ctx e in
          subst, compose_subst subst subst_acc, { ctx with n }, t :: ts)
        (esubst, esubst, ctx, [])
        es
    in
    n, TTuple (List.rev ts), subst

and prefixop_infer ctx e1 expectedType retType =
  let n, t1, subst1 = infer ctx e1 in
  let subst2 = unify [ t1, expectedType ] in
  n, retType, compose_subst subst2 subst1

and binop_infer ctx e1 e2 cmp retType =
  let n, t1, subst1 = infer ctx e1 in
  let ctx = subst_tyenv subst1 { ctx with n } in
  let n, t2, subst2 = infer ctx e2 in
  let t1 = subst_ty subst2 t1 in
  let subst3 = unify (cmp (t1, t2)) in
  n, retType, compose_subst subst3 (compose_subst subst2 subst1)
;;

let infer tenv e =
  let _, t, _ = infer { tenv; n = 0 } e in
  tenv, t
;;
