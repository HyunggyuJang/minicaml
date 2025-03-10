open Peg.Core
open Parser.Syntax
open Syntax

(* === utils === *)

let run = Peg.Core.runParser
let parse = Peg.Core.parse
let explode = Peg.Utils.explode
let implode = Peg.Utils.implode
let rec fix f x = f (fix f) x

(* === tokens === *)

module Token = struct
  type prefixOp = Not

  type infix0op =
    | Equal
    | Less
    | Greater

  type infix11opR = Colcol

  type infix2op =
    | Plus
    | Minus

  type infix3op =
    | Asterisk
    | Slash
end

let escape =
  let* _ = char '\\' in
  let* escaped =
    choice
      [ char '\\'
      ; char '"'
      ; char '\''
      ; char 'n' *> pure '\n'
      ; char 't' *> pure '\t'
      ; char 'r' *> pure '\r'
      ]
    <?> "escape sequence"
  in
  pure @@ Peg.Utils.implode [ escaped ]
;;

let regularchar =
  let c =
    let* c =
      notP (choice [ char '\\'; char '"'; char '\''; char '\n' ]) *> item ()
    in
    pure @@ Peg.Utils.implode [ c ]
  in
  escape <|> c
;;

let idP =
  let* d = letter <|> char '_' in
  let* ds = many (alnum <|> char '.' <|> char '_' <|> char '\'') in
  pure @@ Peg.Utils.implode (d :: ds)
;;

(* avoid name conflict *)
let notParser = string "not"
let trueP = string "true"
let falseP = string "false"
let funP = string "fun"
let letP = string "let"
let recP = string "rec"
let inP = string "in"
let ifP = string "if"
let thenP = string "then"
let elseP = string "else"
let matchP = string "match"
let withP = string "with"
let bool = trueP *> pure true <|> falseP *> pure false

let keyword =
  let px =
    [ notParser
    ; trueP
    ; falseP
    ; funP
    ; letP
    ; recP
    ; inP
    ; ifP
    ; thenP
    ; elseP
    ; matchP
    ; withP
    ] [@ocamlformat "disable"]
  in
  let px = List.map (fun p -> p <* notP idP) px in
  choice px
;;

(* termination *)

let arrow = string "->"
let vbar = string "|"

(* group *)

let lparen = string "("
let rparen = string ")"
let lbra = string "["
let rbra = string "]"

(* op *)

let plus = string "+"
let minus = string "-"
let asterisk = string "*"
let slash = string "/"
let equal = string "="
let less = string "<"
let greater = string ">"
let semicol = string ";"
let comma = string ","
let colcol = string "::"

(* op relation *)

let prefixOp = notParser *> pure Token.Not

let infix0op =
  let open Token in
  equal *> pure Equal <|> less *> pure Less <|> greater *> pure Greater
;;

let infix1opR = colcol *> pure Token.Colcol

let infix2op =
  let open Token in
  plus *> pure Plus <|> minus *> pure Minus
;;

let infix3op =
  let open Token in
  asterisk *> pure Asterisk <|> slash *> pure Slash
;;

(* literal *)

let var = notP keyword *> idP

let int =
  let* neg = option false (minus *> pure true) in
  let* ns = many1 digit in
  let num = int_of_string @@ Peg.Utils.implode ns in
  let value = if neg then -num else num in
  pure value
;;

let empty_list = lbra *> ows *> rbra *> pure Empty
let unitP = lparen *> ows *> rparen *> pure Unit

let stringLit =
  let* ss = string "\"" *> many (regularchar <|> string "'") <* string "\"" in
  pure @@ String.concat "" ss
;;

(* parser *)

let rec exp () =
  let exp = pure () >>= exp in
  let cases = pure () >>= cases in
  let prefix = pure () >>= prefix in
  let funP' =
    let* _ = token funP in
    let* x = token var in
    let* _ = token arrow in
    let* e = exp in
    pure @@ Fun (x, e)
  in
  let letP' =
    let* _ = token letP in
    let* x = token var in
    let* _ = token equal in
    let* e1 = token exp in
    let* _ = token inP in
    let* e2 = exp in
    pure @@ Let (x, e1, e2)
  in
  let letRecP =
    let* _ = token letP in
    let* _ = token recP in
    let* n = token var in
    let* x = token var in
    let* _ = token equal in
    let* e1 = token exp in
    let* _ = token inP in
    let* e2 = exp in
    pure @@ LetRec (n, x, e1, e2)
  in
  let ifP' =
    let* _ = token ifP in
    let* ce = token exp in
    let* _ = token thenP in
    let* e1 = token exp in
    let* _ = token elseP in
    let* e2 = exp in
    pure @@ If (ce, e1, e2)
  in
  let matchP' =
    let* _ = token matchP in
    let* e = token exp in
    let* _ = token withP in
    let* cs = cases in
    pure @@ Match (e, cs)
  in
  choice [ prefix; funP'; letP'; letRecP; ifP'; matchP' ]
  <?> "(, fun, let, if, match"

and prefix () =
  let infix0 = pure () >>= infix0 in
  let* e1 = optional (prefixOp <* rws) in
  let* e2 = infix0 in
  pure
  @@
  match e1 with
  | None -> e2
  | Some Token.Not -> Not e2

and infix0 () =
  let infix1 = pure () >>= infix1 in
  let pair a b = a, b in
  let f e1 (op, e2) =
    match op with
    | Token.Equal -> Eq (e1, e2)
    | Token.Less -> Less (e1, e2)
    | Token.Greater -> Greater (e1, e2)
  in
  let* e1 = infix1 in
  let* es = many (pair <$> ows *> infix0op <*> ows *> infix1) in
  pure @@ List.fold_left f e1 es

and infix1 () =
  let infix1 = pure () >>= infix1 in
  let infix2 = pure () >>= infix2 in
  let pair a b = a, b in
  let f (op, e1) e2 =
    match op with
    | Token.Colcol -> Cons (e2, e1)
  in
  let* e1 = infix2 in
  let* es = many (pair <$> ows *> infix1opR <*> ows *> infix1) in
  pure @@ List.fold_right f es e1

and infix2 () =
  let infix3 = pure () >>= infix3 in
  let pair a b = a, b in
  let f e1 (op, e2) =
    match op with
    | Token.Plus -> Plus (e1, e2)
    | Token.Minus -> Minus (e1, e2)
  in
  let* e1 = infix3 in
  let* es = many (pair <$> ows *> infix2op <*> ows *> infix3) in
  pure @@ List.fold_left f e1 es

and infix3 () =
  let infix4 = pure () >>= infix4 in
  let pair a b = a, b in
  let f e1 (op, e2) =
    match op with
    | Token.Asterisk -> Times (e1, e2)
    | Token.Slash -> Div (e1, e2)
  in
  let* e1 = infix4 in
  let* es = many (pair <$> ows *> infix3op <*> ows *> infix4) in
  pure @@ List.fold_left f e1 es

and infix4 () =
  let priexp = pure () >>= priexp in
  let apply =
    let* fn = priexp in
    let* es = many1 (rws *> priexp) in
    pure @@ List.fold_left (fun e1 e2 -> App (e1, e2)) fn es
  in
  apply <|> priexp

and priexp () =
  let exp = pure () >>= exp in
  let literalP = pure () >>= literalP in
  literalP <|> (lparen *> ows *> exp <* ows <* rparen)

and cases () =
  let exp = pure () >>= exp in
  let pattern = pure () >>= pattern in
  let single_pair =
    let* e1 = token pattern in
    let* _ = token arrow in
    let* e2 = exp in
    pure (e1, e2)
  in
  let single = List.cons <$> single_pair <*> pure [] in
  let multiple = many1 (ows *> vbar *> ows *> single_pair) in
  single <|> multiple

and pattern () =
  let pattern = pure () >>= pattern in
  let pattern_inner = pure () >>= pattern_inner in
  let* p = pattern_inner in
  let* ps = many (ows *> colcol *> ows *> pattern) in
  match ps with
  | [] -> pure p
  | _ ->
    let ps = p :: ps in
    let r = Utils.fold_right1 (fun p acc -> Cons (p, acc)) ps in
    pure r

and pattern_inner () = literalP ()

and literalP () =
  let list = pure () >>= list in
  let tuple = pure () >>= tuple in
  choice
    [ (fun v -> Var v) <$> var <?> "variable"
    ; (fun i -> IntLit i) <$> int <?> "number"
    ; (fun b -> BoolLit b) <$> bool <?> "true or false"
    ; (fun s -> StrLit s) <$> stringLit <?> "string"
    ; unitP <?> "unit"
    ; empty_list <?> "[]"
    ; list <?> "list"
    ; tuple <?> "tuple"
    ]

and list () =
  let exp = pure () >>= exp in
  let* _ = lbra <* ows in
  let* e = exp in
  let* es = many (ows *> semicol *> ows *> exp) in
  let* _ = optional @@ (ows *> semicol) in
  let* _ = ows *> rbra in
  match es with
  | [] -> pure @@ Cons (e, Empty)
  | _ ->
    let es = e :: es in
    let r = List.fold_right (fun e acc -> Cons (e, acc)) es Empty in
    pure r

and tuple () =
  let exp = pure () >>= exp in
  let* _ = less <* ows in
  let* e = exp in
  let* es = many1 (ows *> comma *> ows *> exp) in
  let* _ = optional @@ (ows *> comma) in
  let* _ = ows *> greater in
  pure @@ Tuple (e :: es)
;;

(* grammer *)

let exp = exp ()
let pattern = pattern ()
let cases = cases ()
let main = ows *> exp <* ows <* eof ()
let main = Parser.run main
