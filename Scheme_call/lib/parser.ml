open Opal
open Ast

let rec const_e input = (const_v => fun x -> Const x) input

and const_v input =
  choice
    [ (integer => fun i -> Int i)
    ; (boolean => fun b -> Bool b)
    ; (str => fun s -> String s)
    ]
    input

and integer =
  token "+"
  <|> token "-"
  <|> token ""
  >>= fun y ->
  many1 digit => implode % int_of_string => fun x -> if y == "-" then -x else x

and boolean = token "#t" <|> token "#f" => fun x -> if x == "#t" then true else false

and str =
  spaces
  >> between (exactly '"') (exactly '"') (many (satisfy (fun x -> not (x == '"'))))
  => implode
  => fun x -> x
;;

let spec_initial =
  one_of [ '!'; '$'; '%'; '&'; '*'; '/'; ':'; '<'; '='; '>'; '?'; '^'; '_'; '~' ]
;;

let identifier =
  spaces
  >> (letter
     <|> spec_initial
     <~> many (alpha_num <|> spec_initial <|> one_of [ '+'; '-' ])
     => implode
     <|> token "+"
     <|> token "-")
;;

let parens = between (token "(" >> spaces) (token ")")
let parens_id = between (token "(" >> spaces) (token ")")

let rec expr input =
  (choice [ quote; conditional; let_expr; lambda; proc_call; const_e; var ]) input

and proc_call input = parens (many expr >>= operator) input

and operator = function
  | hd :: tl -> return (Proc_call (Op hd, tl))
  | _ -> mzero

and quote input = (token "'" >> quote2 <|> parens (token "quote" >> quote2)) input

and quote2 input =
  choice [ (const_d => fun x -> Quote x); (qlist => fun l -> Quote l) ] input

and qlist input =
  (between (token "(" >> spaces) (token ")") (sep_by (const_d <|> qlist) spaces)
  => fun xs -> List xs)
    input

and const_d input =
  choice
    [ (*(identifier => fun x -> Symbol x)
    ;*)
      (integer => fun i -> DConst (DInt i))
    ; (boolean => fun b -> DConst (DBool b))
    ; (str => fun s -> DConst (DString s))
    ]
    input

and var = identifier => fun x -> Var x
and conditional input = (if_conditional <|> cond_conditional) input

and if_conditional input =
  parens
    (token "if"
    >> expr
    >>= fun test ->
    expr
    >>= fun cons ->
    option
      (Cond (test, cons, None))
      (expr >>= fun alter -> return (Cond (test, cons, Some alter))))
    input

and cond_conditional input = parens (token "cond" >> cond_conditional2) input

and cond_conditional2 input =
  (parens (token "else" >> expr)
  <|> (between (token "(" >> spaces) (token ")") (many expr)
      >>= function
      | [ test; cons ] ->
        option
          (Cond (test, cons, None))
          (cond_conditional2 >>= fun alter -> return (Cond (test, cons, Some alter)))
      | [ test ] ->
        option
          (Cond (test, test, None))
          (cond_conditional2 >>= fun alter -> return (Cond (test, test, Some alter)))
      | _ -> mzero))
    input

and lambda input =
  parens
    (token "lambda"
    >> spaces
    >> formals
    >>= fun f -> spaces >> expr => fun e -> Lam (f, e))
    input

and formals =
  parens_id (many identifier)
  => (fun fs -> FVarList fs)
  <|> (identifier => fun f -> FVar f)

and ( <~~> ) x y = x >>= fun r -> y >>= fun rs -> return (r, rs)

and let_expr input =
  between
    (token "(" >> spaces)
    (token ")")
    (token "let"
    >> between
         (token "(" >> spaces)
         (token ")")
         (many (between (token "(" >> spaces) (token ")") (identifier <~~> expr)))
    >>= fun l ->
    expr
    => fun expr ->
    let names, objs = List.split l in
    Proc_call (Op (Lam (FVarList names, expr)), objs))
    input
;;

let rec def input =
  between
    (token "(" >> spaces)
    (token ")")
    (token "define" >> spaces >> (def2 <|> def3))
    input

and def2 input =
  (identifier >>= fun var -> expr => fun expression -> Def (var, expression)) input

and def3 input =
  (parens_id (many identifier)
  >>= fun fs ->
  expr
  >>= fun expression ->
  if fs = []
  then mzero
  else return (Def (List.hd fs, Lam (FVarList (List.tl fs), expression))))
    input
;;

let form = def <|> (expr => fun e -> Expr e)
let prog = many form << spaces << eof ()
let parse_prog str = parse prog (LazyStream.of_string str)
let parse_this parser str = parse parser (LazyStream.of_string str)
