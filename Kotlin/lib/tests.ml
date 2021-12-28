open Ast
open Parser

(* Тесты на парсер *)

let%test _ =
  apply_parser parse_modifiers "public private protected open override"
  = Some [ Public; Private; Protected; Open; Override ]
;;

let%test _ = apply_parser parse_variable_type_modifier "var" = Some Var
let%test _ = apply_parser parse_variable_type_modifier "val" = Some Val

let%test _ =
  List.for_all
    (fun keyword -> apply_parser parse_identifier keyword = None)
    reserved_keywords
;;

let%test _ = apply_parser parse_identifier "identifier" = Some "identifier"
let%test _ = apply_parser parse_typename "Int" = Some Int
let%test _ = apply_parser parse_typename "String" = Some String
let%test _ = apply_parser parse_typename "Boolean" = Some Boolean
let%test _ = apply_parser parse_typename "MyClass" = Some (ClassIdentifier "MyClass")

let%test _ =
  apply_parser parse_typename "MyClass?" = Some (Nullable (ClassIdentifier "MyClass"))
;;

(* Тесты на парсер для Expression-ов *)
open Expression

let%test _ =
  List.for_all
    (fun keyword -> apply_parser parse_var_identifier keyword = None)
    reserved_keywords
;;

let%test _ =
  apply_parser parse_var_identifier "identifier" = Some (VarIdentifier "identifier")
;;

let%test _ = apply_parser parse_int_value "string" = None
let%test _ = apply_parser parse_int_value "123" = Some (IntValue 123)
let%test _ = apply_parser parse_int_value "-123" = Some (IntValue (-123))
let%test _ = apply_parser parse_string_value {| string" |} = None
let%test _ = apply_parser parse_string_value {| "string |} = None
let%test _ = apply_parser parse_string_value {| "string" |} = Some (StringValue "string")
let%test _ = apply_parser parse_string_value {| "" |} = Some (StringValue "")
let%test _ = apply_parser parse_boolean_value "false" = Some (BooleanValue false)
let%test _ = apply_parser parse_boolean_value "true" = Some (BooleanValue true)
let%test _ = apply_parser parse_null_value "null" = Some NullValue
let%test _ = apply_parser parse_const_value "string" = None
let%test _ = apply_parser parse_const_value "123" = Some (Const (IntValue 123))

let%test _ =
  apply_parser parse_const_value {| "string" |} = Some (Const (StringValue "string"))
;;

let%test _ = apply_parser parse_const_value "false" = Some (Const (BooleanValue false))
let%test _ = apply_parser parse_const_value "true" = Some (Const (BooleanValue true))
let%test _ = apply_parser parse_const_value "null" = Some (Const NullValue)

let%test _ =
  apply_parser expression {| 5 < 6 |}
  = Some (Less (Const (IntValue 5), Const (IntValue 6)))
;;

let%test _ =
  apply_parser expression {| 6 > 5 |}
  = Some (Less (Const (IntValue 5), Const (IntValue 6)))
;;

let%test _ =
  apply_parser expression {| 5 == 6 |}
  = Some (Equal (Const (IntValue 5), Const (IntValue 6)))
;;

let%test _ = apply_parser expression {| !true |} = Some (Not (Const (BooleanValue true)))

let%test _ =
  apply_parser expression {| 5 != 6 |}
  = Some (Not (Equal (Const (IntValue 5), Const (IntValue 6))))
;;

let%test _ =
  apply_parser expression {| 5 <= 6 |}
  = Some
      (Or
         ( Equal (Const (IntValue 5), Const (IntValue 6))
         , Less (Const (IntValue 5), Const (IntValue 6)) ))
;;

let%test _ =
  apply_parser expression {| 6 >= 5 |}
  = Some
      (Or
         ( Equal (Const (IntValue 6), Const (IntValue 5))
         , Less (Const (IntValue 5), Const (IntValue 6)) ))
;;

let%test _ =
  apply_parser expression {| !true || 6 >= 5 |}
  = Some
      (Or
         ( Not (Const (BooleanValue true))
         , Or
             ( Equal (Const (IntValue 6), Const (IntValue 5))
             , Less (Const (IntValue 5), Const (IntValue 6)) ) ))
;;

let%test _ =
  apply_parser expression {| (!true || 6 >= 5) && 1 < 2 |}
  = Some
      (And
         ( Or
             ( Not (Const (BooleanValue true))
             , Or
                 ( Equal (Const (IntValue 6), Const (IntValue 5))
                 , Less (Const (IntValue 5), Const (IntValue 6)) ) )
         , Less (Const (IntValue 1), Const (IntValue 2)) ))
;;

let%test _ =
  apply_parser expression {| !true || 6 + 1 > 5 && 1 < 2 |}
  = Some
      (Or
         ( Not (Const (BooleanValue true))
         , And
             ( Less (Const (IntValue 5), Add (Const (IntValue 6), Const (IntValue 1)))
             , Less (Const (IntValue 1), Const (IntValue 2)) ) ))
;;

let%test _ =
  apply_parser expression {| !true || 2 * 6 + 4 / 2 > 5 && 1 < 2 |}
  = Some
      (Or
         ( Not (Const (BooleanValue true))
         , And
             ( Less
                 ( Const (IntValue 5)
                 , Add
                     ( Mul (Const (IntValue 2), Const (IntValue 6))
                     , Div (Const (IntValue 4), Const (IntValue 2)) ) )
             , Less (Const (IntValue 1), Const (IntValue 2)) ) ))
;;

let%test _ =
  apply_parser expression {| { 1 } |}
  = Some
      (AnonymousFunctionDeclaration
         (AnonymousFunctionDeclarationStatement
            ([], Block [ Expression (Const (IntValue 1)) ])))
;;

let%test _ = apply_parser expression {| { -> 1 } |} = None

let%test _ =
  apply_parser expression {| { x: Int, y: Int -> x + y } |}
  = Some
      (AnonymousFunctionDeclaration
         (AnonymousFunctionDeclarationStatement
            ( [ "x", Int; "y", Int ]
            , Block [ Expression (Add (VarIdentifier "x", VarIdentifier "y")) ] )))
;;

let%test _ = apply_parser expression {| baz() |} = Some (FunctionCall ("baz", []))

let%test _ =
  apply_parser expression {| baz(foo, "bar") |}
  = Some (FunctionCall ("baz", [ VarIdentifier "foo"; Const (StringValue "bar") ]))
;;

let%test _ =
  apply_parser expression {| foo.bar?.baz() |}
  = Some
      (Dereference
         ( VarIdentifier "foo"
         , ElvisDereference (VarIdentifier "bar", FunctionCall ("baz", [])) ))
;;

(* Тесты на парсер для Statement-ов *)
open Statement

let%test _ =
  apply_parser statement {| { 1 } |} = Some (Block [ Expression (Const (IntValue 1)) ])
;;

let%test _ =
  apply_parser statement {| { 
    1 
    2
  } |}
  = Some (Block [ Expression (Const (IntValue 1)); Expression (Const (IntValue 2)) ])
;;

let%test _ =
  apply_parser statement {| fun main(): Int { 
    return 0
  } |}
  = Some (FunDeclaration ([], "main", [], Int, Block [ Return (Const (IntValue 0)) ]))
;;

let%test _ =
  apply_parser statement {| fun func_with_args(x: Int, y: Int): Int { 
    return 0
  } |}
  = Some
      (FunDeclaration
         ( []
         , "func_with_args"
         , [ "x", Int; "y", Int ]
         , Int
         , Block [ Return (Const (IntValue 0)) ] ))
;;

let%test _ =
  apply_parser
    statement
    {| protected open fun func_with_modifiers(): Int { 
    return 0
  } |}
  = Some
      (FunDeclaration
         ( [ Protected; Open ]
         , "func_with_modifiers"
         , []
         , Int
         , Block [ Return (Const (IntValue 0)) ] ))
;;

let%test _ =
  apply_parser statement {| val foo: Int |}
  = Some (VarDeclaration ([], Val, "foo", Int, None))
;;

let%test _ =
  apply_parser statement {| var foo: Int |}
  = Some (VarDeclaration ([], Var, "foo", Int, None))
;;

let%test _ =
  apply_parser statement {| open val foo: Int = 1 |}
  = Some (VarDeclaration ([ Open ], Val, "foo", Int, Some (Const (IntValue 1))))
;;

let%test _ =
  apply_parser statement {| class MyClass() { 
    
  } |}
  = Some (ClassDeclaration ([], "MyClass", [], None, Block []))
;;

let%test _ =
  apply_parser statement {| open class MyClassWithSuper(): Foo() { 
    
  } |}
  = Some
      (ClassDeclaration
         ([ Open ], "MyClassWithSuper", [], Some (FunctionCall ("Foo", [])), Block []))
;;

let%test _ =
  apply_parser
    statement
    {| class MyClassWithContent() { 
    var foo: Int = 1
    fun bar(): Int {
      return 0
    }
  } |}
  = Some
      (ClassDeclaration
         ( []
         , "MyClassWithContent"
         , []
         , None
         , Block
             [ VarDeclaration ([], Var, "foo", Int, Some (Const (IntValue 1)))
             ; FunDeclaration ([], "bar", [], Int, Block [ Return (Const (IntValue 0)) ])
             ] ))
;;

let%test _ =
  apply_parser statement {| while(true) {} |}
  = Some (While (Const (BooleanValue true), Block []))
;;

let%test _ =
  apply_parser statement {| if(true) {} |}
  = Some (If (Const (BooleanValue true), Block [], None))
;;

let%test _ =
  apply_parser statement {| if(true) {} else {}|}
  = Some (If (Const (BooleanValue true), Block [], Some (Block [])))
;;

let%test _ =
  apply_parser statement {| if(true) 1 else 2|}
  = Some
      (If
         ( Const (BooleanValue true)
         , Expression (Const (IntValue 1))
         , Some (Expression (Const (IntValue 2))) ))
;;

let%test _ =
  apply_parser statement {| a = 1 |}
  = Some (Assign (VarIdentifier "a", Const (IntValue 1)))
;;

let%test _ =
  apply_parser statement {| a.foo = 1 * 2 + 3 |}
  = Some
      (Assign
         ( Dereference (VarIdentifier "a", VarIdentifier "foo")
         , Add (Mul (Const (IntValue 1), Const (IntValue 2)), Const (IntValue 3)) ))
;;

(* Тесты на интерпретатор *)
exception Test_failed

open Utils
open Interpreter
open Interpreter.Interpret (Base.Result)

let empty_ctx =
  let ctx =
    { environment = []
    ; checked_not_null_values = []
    ; last_eval_expression = Unitialized
    ; last_return_value = Unitialized
    ; last_derefered_variable = None
    ; scope = Initialize
    }
  in
  let ctx_with_standard_classes =
    Base.Option.value_exn (Base.Result.ok (load_standard_classes ctx))
  in
  ctx_with_standard_classes
;;

let%test _ =
  let ctx = parse_and_run {| fun main(): Int { 
    return 1
  } 
  |} in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 1
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Add (Const (IntValue 1), Const (IntValue 2)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 3
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Add (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = StringValue "foobar"
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Add (Const (BooleanValue false), Const (StringValue "bar")))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Sub (Const (IntValue 1), Const (IntValue 2)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue (-1)
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Sub (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Mul (Const (IntValue 1), Const (IntValue 2)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 2
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Mul (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Div (Const (IntValue 2), Const (IntValue 2)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 1
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Div (Const (IntValue 3), Const (IntValue 2)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 1
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Mod (Const (IntValue 2), Const (IntValue 2)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 0
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Mod (Const (IntValue 3), Const (IntValue 2)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 1
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Div (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Mod (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (And (Const (BooleanValue true), Const (BooleanValue false)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (And (Const (BooleanValue false), Const (BooleanValue false)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (And (Const (BooleanValue true), Const (BooleanValue true)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (And (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Or (Const (BooleanValue true), Const (BooleanValue false)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Or (Const (BooleanValue false), Const (BooleanValue false)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Or (Const (BooleanValue true), Const (BooleanValue true)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Or (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Not (Const (BooleanValue false))) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Not (Const (BooleanValue true))) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Not (Const (StringValue "foo"))) in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Equal (Const (IntValue 1), Const (IntValue 1)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Equal (Const (IntValue 42), Const (IntValue 1)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Equal (Const (StringValue "foo"), Const (StringValue "foo")))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Equal (Const (StringValue "foo"), Const (StringValue "bar")))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Equal (Const (StringValue "foo"), Const (StringValue "foo")))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Equal (Const (BooleanValue false), Const (BooleanValue true)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Equal (Const (BooleanValue true), Const (BooleanValue true)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Equal (Const NullValue, Const NullValue)) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Equal (Const Unitialized, Const NullValue)) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression
      empty_ctx
      (Equal
         ( Const
             (AnonymousFunction
                { identity_code = 1
                ; fun_typename = Int
                ; arguments = []
                ; statement = Block []
                })
         , Const
             (AnonymousFunction
                { identity_code = 2
                ; fun_typename = Int
                ; arguments = []
                ; statement = Block []
                }) ))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;
;;

let ctx =
  let obj_class = { constructor_args = []; super_call = None; statements = [] } in
  interpret_expression
    empty_ctx
    (Equal
       ( Const
           (Object
              { identity_code = 1
              ; classname = "foo"
              ; super = None
              ; obj_class
              ; fields = []
              ; methods = []
              })
       , Const
           (Object
              { identity_code = 2
              ; classname = "foo"
              ; super = None
              ; obj_class
              ; fields = []
              ; methods = []
              }) ))
in
match ctx with
| Error _ -> raise Test_failed
| Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Less (Const (IntValue 1), Const (IntValue 42)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue true
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Less (Const (IntValue 42), Const (IntValue 1)))
  in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = BooleanValue false
;;

let%test _ =
  let ctx =
    interpret_expression empty_ctx (Less (Const (BooleanValue false), Const (IntValue 1)))
  in
  match ctx with
  | Error err ->
    (match err with
    | UnsupportedOperandTypes _ -> true
    | _ -> false)
  | Ok _ -> raise Test_failed
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Const (IntValue 1)) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 1
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Const (IntValue 1)) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = IntValue 1
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Const (StringValue "foo")) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = StringValue "foo"
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (Const NullValue) in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx -> eval_ctx.last_eval_expression = NullValue
;;

let%test _ =
  let rc =
    { name = "foo"
    ; modifiers = []
    ; clojure = ref []
    ; content =
        Variable { var_typename = Int; mutable_status = false; value = ref (IntValue 1) }
    }
  in
  let ctx_with_variable = { empty_ctx with environment = [ rc ] } in
  let ctx = interpret_expression ctx_with_variable (VarIdentifier "foo") in
  match ctx with
  | Error _ -> raise Test_failed
  | Ok eval_ctx ->
    eval_ctx.last_eval_expression = IntValue 1
    && eval_ctx.last_derefered_variable = Some rc
;;

let%test _ =
  let ctx = interpret_expression empty_ctx (VarIdentifier "foo") in
  match ctx with
  | Error err ->
    (match err with
    | UnknownVariable "foo" -> true
    | _ -> raise Test_failed)
  | Ok _ -> raise Test_failed
;;