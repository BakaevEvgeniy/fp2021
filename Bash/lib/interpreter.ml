open Ast

(* -------------------- Monads to be passed to the interpreter -------------------- *)

(** Infix monad with a fail function *)
module type MonadFail = sig
  include Base.Monad.Infix

  val return : 'a -> 'a t
  val fail : string -> 'a t
end

(** Result as a monad-fail *)
module Result : MonadFail with type 'a t = ('a, string) result = struct
  type 'a t = ('a, string) result

  let return = Result.ok
  let ( >>= ) = Result.bind
  let ( >>| ) f g = f >>= fun x -> return (g x)
  let fail = Result.error
end

(* -------------------- Maps with pretty-printing -------------------- *)

(** Ordered type with pretty-printing *)
module type PpOrderedType = sig
  include Map.OrderedType

  val pp_t : Format.formatter -> t -> unit
end

(** Functor to create maps with pretty-printing for deriving *)
module TMap (T : PpOrderedType) = struct
  include Map.Make (T)

  let of_list l = of_seq (List.to_seq l)

  let pp pp_v ppf m =
    Format.fprintf ppf "@[[@[";
    iter (fun k v -> Format.fprintf ppf "@[%a: %a@],@\n" T.pp_t k pp_v v) m;
    Format.fprintf ppf "@]]@]"
  ;;
end

(** Map with string keys *)
module SMap = TMap (struct
  include String

  let pp_t = Format.pp_print_string
end)

(** Map with integer keys *)
module IMap = TMap (struct
  include Int

  let pp_t = Format.pp_print_int
end)

(* -------------------- Interpreter -------------------- *)

(** Main interpreter module *)
module Eval (M : MonadFail) = struct
  open M

  (* -------------------- Helper functions -------------------- *)

  (** [mapm f l] applies [f] to each element of [l] returning the resulting list if all
  applications succeed and failing otherwise *)
  let mapm f l =
    List.fold_right
      (fun e acc -> acc >>= fun tl -> f e >>| fun hd -> hd :: tl)
      l
      (return [])
  ;;

  (** [flat_mapm f l] applies [f] to each element of [l] returning the resulting flattened
  list if all applications succeed and failing otherwise *)
  let flat_mapm f l = mapm f l >>| List.concat

  (* -------------------- Environment -------------------- *)

  (** Container for values of variables *)
  type var_t =
    | IndArray of string IMap.t (** Simple variable or indexed array *)
    | AssocArray of string SMap.t (** Associative array *)
  [@@deriving show { with_path = false }]

  (** Container for functions *)
  type fun_t = compound [@@deriving show { with_path = false }]

  (** Complete environment *)
  type environment =
    { vars : var_t SMap.t (** Variables available in the current scope *)
    ; funs : fun_t SMap.t (** Functions available in the current scope *)
    ; stdin : string (** Current stdin contents *)
    ; stdout : string (** Current stdout contents *)
    ; stderr : string (** Current stderr contents *)
    ; retcode : int (** Return code of the last operation *)
    }
  [@@deriving show { with_path = false }]

  let get_var name env = SMap.find_opt name env.vars
  let set_var name v env = SMap.add name v env.vars
  let get_fun name env = SMap.find_opt name env.funs
  let set_fun name v env = SMap.add name v env.funs

  (* -------------------- Evaluation -------------------- *)

  (** Evaluate variable *)
  let ev_var env ((name, index) : var) =
    let find f a i =
      match f i a with
      | None -> ""
      | Some v -> v
    in
    match get_var name env with
    | None -> return ""
    | Some (IndArray vs) ->
      (match int_of_string_opt index with
      | None -> return (find IMap.find_opt vs 0)
      | Some i -> return (find IMap.find_opt vs i))
    | Some (AssocArray vs) -> return (find SMap.find_opt vs index)
  ;;

  (** Evaluate arithmetic expression *)
  let ev_arithm envs =
    let rec ev_ari ?(c = fun _ _ -> true) ?(e = "") op l r =
      ev l >>= fun l -> ev r >>= fun r -> if c l r then return (op l r) else fail e
    and ev_log op l r = ev l >>= fun l -> ev r >>| fun r -> if op l r then 1 else 0
    and ev = function
      | Num n -> return n
      | Var x ->
        ev_var envs x
        >>| fun s ->
        (match int_of_string_opt s with
        | None -> 0
        | Some n -> n)
      | Plus (l, r) -> ev_ari ( + ) l r
      | Minus (l, r) -> ev_ari ( - ) l r
      | Mul (l, r) -> ev_ari ( * ) l r
      | Div (l, r) -> ev_ari ~c:(fun _ r -> r <> 0) ~e:"Division by 0" ( / ) l r
      | Less (l, r) -> ev_log ( < ) l r
      | Greater (l, r) -> ev_log ( > ) l r
      | LessEq (l, r) -> ev_log ( <= ) l r
      | GreaterEq (l, r) -> ev_log ( >= ) l r
      | Equal (l, r) -> ev_log ( = ) l r
      | NEqual (l, r) -> ev_log ( <> ) l r
    in
    ev
  ;;

  (** Evaluate parameter expansion *)
  let ev_param_exp env =
    let subst size ~all ~beg v p r =
      ev_var env v
      >>| fun s ->
      if s = "" && Base.String.for_all s ~f:(fun c -> c = '*')
      then r (* A hack because Re.replace does nothing on an empty string *)
      else (
        let cond g =
          let c =
            match beg with
            | None -> true (* Anywhere *)
            | Some true -> Re.Group.start g 0 = 0 (* Only at the beginning *)
            | Some false -> Re.Group.stop g 0 = String.length s
            (* Only at the end *)
          in
          if c then r else Re.Group.get g 0
        in
        let re = Re.Glob.glob p |> size |> Re.compile in
        Re.replace ~all:(all || beg = Some false) re ~f:cond s)
      (* ~all has to be true when matching only at the end *)
    in
    function
    | Param v -> ev_var env v
    | PosParam i -> ev_var env (string_of_int i, "0")
    | Length v -> ev_var env v >>| fun s -> string_of_int (String.length s)
    | Substring (v, pos, len) ->
      ev_var env v
      >>= fun s ->
      ev_arithm env pos
      >>= fun pos ->
      (match len with
      | Some a -> ev_arithm env a >>| fun n -> Some n
      | None -> return None)
      >>= fun len ->
      let s_len = String.length s in
      let p = if 0 <= pos && pos < s_len then pos else s_len + pos in
      let l =
        match len with
        | Some l when l >= 0 -> min l (s_len - p)
        | Some l -> s_len + l - p
        | None -> s_len - p
      in
      if p >= 0 && l >= 0
      then return (String.sub s p l)
      else if l >= 0
      then return ""
      else fail "substring expression < 0"
    | CutMinBeg (v, p) -> subst Re.shortest ~all:false ~beg:(Some true) v p ""
    | CutMaxBeg (v, p) -> subst Re.longest ~all:false ~beg:(Some true) v p ""
    | CutMinEnd (v, p) -> subst Re.shortest ~all:false ~beg:(Some false) v p ""
    | CutMaxEnd (v, p) -> subst Re.longest ~all:false ~beg:(Some false) v p ""
    | SubstOne (v, p, r) -> subst Re.longest ~all:false ~beg:None v p r
    | SubstAll (v, p, r) -> subst Re.longest ~all:true ~beg:None v p r
    | SubstBeg (v, p, r) -> subst Re.longest ~all:false ~beg:(Some true) v p r
    | SubstEnd (v, p, r) -> subst Re.longest ~all:false ~beg:(Some false) v p r
  ;;

  (** Evaluate filename expansion *)
  let ev_filename_exp _ s =
    let cts dir =
      let re = Re.Glob.glob s |> Re.whole_string |> Re.compile in
      let rd d = Array.to_list (Sys.readdir d) in
      (* Source: https://gist.github.com/lindig/be55f453026c65e761f4e7012f8ab9b5 *)
      let rec helper res = function
        | d :: tl when Sys.is_directory d ->
          rd d
          |> List.map (Filename.concat d)
          |> List.append tl
          |> if Re.execp re d then helper (d :: res) else helper res
        | f :: tl when Re.execp re f -> helper (f :: res) tl
        | _ :: tl -> helper res tl
        | [] -> res
      in
      helper [] (rd dir)
    in
    cts (Sys.getcwd ()) |> List.sort String.compare |> return
  ;;

  (** Evaluate word *)
  let rec ev_word env = function
    | BraceExp ws -> ev_words env ws
    | ParamExp p -> ev_param_exp env p >>| fun s -> env, [ s ]
    | CmdSubst c ->
      ev_cmd { env with stdin = "" } c
      >>= fun { stdout; stderr; retcode } ->
      (match Parser.split_words stdout with
      | Ok ss -> return ({ env with stderr = env.stderr ^ stderr; retcode }, ss)
      | Error e -> fail e)
    | ArithmExp a -> ev_arithm env a >>| fun n -> env, [ string_of_int n ]
    | FilenameExp s -> ev_filename_exp env s >>| fun ss -> env, ss
    | Word s -> return (env, [ s ])

  (** Evaluate word list *)
  and ev_words env ?(c = fun _ -> true) ?(e = "Evaluated words condition mismatch") ws =
    let ( @+ ) old_env { stdout; stderr; retcode } =
      { old_env with stdout = env.stdout ^ stdout; stderr = env.stderr ^ stderr; retcode }
    in
    List.fold_left
      (fun acc w ->
        acc
        >>= fun (env, l) ->
        ev_word env w
        >>= fun (n_env, ss) -> if c ss then return (env @+ n_env, ss :: l) else fail e)
      (return (env, []))
      ws
    >>| fun (env, l) -> env, List.(l |> rev |> flatten)

  (** Evaluate assignment *)
  and ev_assignt env =
    let open struct
      type 'a container =
        | Simple of string * 'a (** Simple assignment of key and value *)
        | Ind of 'a list (** Indexed array assignment of values *)
        | Assoc of (string * 'a) list (** Associative array assignment of pairs *)
    end in
    let env_set env name =
      let env_with x = { env with vars = set_var name x env } in
      function
      | Simple (k, v) ->
        env_with
          (match get_var name env, int_of_string_opt k with
          | None, None -> AssocArray (SMap.singleton k v)
          | None, Some i -> IndArray (IMap.singleton i v)
          | Some (IndArray a), None -> IndArray (IMap.add 0 v a)
          | Some (IndArray a), Some i -> IndArray (IMap.add i v a)
          | Some (AssocArray a), _ -> AssocArray (SMap.add k v a))
      | Ind vs -> env_with (IndArray (vs |> List.mapi (fun i v -> i, v) |> IMap.of_list))
      | Assoc ps -> env_with (AssocArray (SMap.of_list ps))
    in
    function
    | SimpleAssignt ((name, i), w) ->
      ev_word env w
      >>= (function
      | new_env, [ s ] -> return (env_set new_env name (Simple (i, s)))
      | _ -> fail "Illegal expansion in simple assignment")
    | IndArrAssignt (name, ws) ->
      ev_words env ws >>| fun (new_env, ss) -> env_set new_env name (Ind ss)
    | AssocArrAssignt (name, ps) ->
      ev_words
        env
        ~c:(function
          | [ _ ] -> true
          | _ -> false)
        ~e:"Illegal expansion in associative array assignment"
        (List.map (fun (_, w) -> w) ps)
      >>| fun (new_env, ss) ->
      env_set new_env name (Assoc (List.map2 (fun (k, _) v -> k, v) ps ss))

  (** Evaluate command *)
  and ev_cmd env =
    let env_with assignts =
      List.fold_left
        (fun acc a -> acc >>= fun env -> ev_assignt env a)
        (return env)
        assignts
    in
    let expand env ws =
      ev_words env ws
      >>= function
      | new_env, cmd :: tl -> return (new_env, cmd, tl)
      | _, [] -> fail "Simple command expanded to nothing"
    in
    let try_read =
      let read_from s =
        if Sys.file_exists s
        then (
          let ch = open_in s in
          try Some (really_input_string ch (in_channel_length ch)) with
          | End_of_file -> None)
        else None
      in
      function
      | s when Filename.dirname s = "." -> read_from (Filename.basename s)
      | s when Filename.dirname s = "" -> read_from s
      | _ -> None
    in
    function
    | Assignt assignts -> env_with assignts
    | Command (assignts, ws) ->
      env_with assignts
      >>= fun new_env ->
      expand new_env ws
      >>= fun (new_env, cmd, args) ->
      (match get_fun cmd new_env, Builtins.find cmd, try_read cmd with
      | Some _, _, _ -> ev_compound new_env
      | None, Some f, _ ->
        (match f args new_env.stdin with
        | stdin, stdout, stderr, retcode ->
          return
            { new_env with
              stdin
            ; stdout = new_env.stdout ^ stdout
            ; stderr = new_env.stderr ^ stderr
            ; retcode
            })
      | None, None, Some s ->
        (match Parser.parse s with
        | Ok script -> ev_script new_env script
        | Error e -> fail (Printf.sprintf "%s: syntax error %s" cmd e))
      | None, None, None -> fail (cmd ^ ": command not found"))

  (** Evaluate redirection *)
  and ev_redir (_ : environment) = fail "Not implemented"

  (** Evaluate pipeline list *)
  and ev_pipeline_list (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate pipeline *)
  and ev_pipeline (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate compound *)
  and ev_compound (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate while loop *)
  and ev_while_loop (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate for loop (list form) *)
  and ev_for_list_loop (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate for loop (expression form) *)
  and ev_for_expr_loop (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate if statement *)
  and ev_if_stmt (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate case statement *)
  and ev_case_stmt (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate script element *)
  and ev_script_elem (_ : environment) : environment t = fail "Not implemented"

  (** Evaluate Bash script *)
  and ev_script env : script -> environment t = function
    | Empty -> return env
    | Script _ -> fail "TODO: evaluate script element"
  ;;
end

(** Interprets the given Bash script AST as a Bash script *)
let interpret script =
  let open Eval (Result) in
  match ev_script script with
  | _ -> "Not implemented"
;;

(* ----------------------------------------------- *)
(* -------------------- Tests -------------------- *)
(* ----------------------------------------------- *)

open Eval (Result)

(* -------------------- Helper functions -------------------- *)

let empty_env =
  { vars = SMap.empty
  ; funs = SMap.empty
  ; stdin = ""
  ; stdout = ""
  ; stderr = ""
  ; retcode = 0
  }
;;

let succ_ev ?(env = empty_env) pp_giv pp_res ev giv exp =
  match ev env giv with
  | Error e ->
    Printf.printf "Error: %s\n" e;
    false
  | Ok res when exp = res -> true
  | Ok res ->
    print_string "\n-------------------- Input --------------------\n";
    pp_giv Format.std_formatter giv;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n----------------- Environment -----------------\n";
    pp_environment Format.std_formatter env;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n------------------- Expected ------------------\n";
    pp_res Format.std_formatter exp;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n-------------------- Actual -------------------\n";
    pp_res Format.std_formatter res;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n-----------------------------------------------\n";
    flush stdout;
    false
;;

let fail_ev ?(env = empty_env) pp_giv pp_res ev giv exp =
  match ev env giv with
  | Error e when exp = e -> true
  | Error e ->
    print_string "\n-------------------- Input --------------------\n";
    pp_giv Format.std_formatter giv;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n----------------- Environment -----------------\n";
    pp_environment Format.std_formatter env;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n--------------- Unexpected error --------------\n";
    print_string e;
    print_string "\n-----------------------------------------------\n";
    flush stdout;
    false
  | Ok res ->
    print_string "\n-------------------- Input --------------------\n";
    pp_giv Format.std_formatter giv;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n----------------- Environment -----------------\n";
    pp_environment Format.std_formatter env;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n-------------------- Actual -------------------\n";
    pp_res Format.std_formatter res;
    Format.pp_print_flush Format.std_formatter ();
    print_string "\n-----------------------------------------------\n";
    flush stdout;
    false
;;

(* -------------------- Variable -------------------- *)

let succ_ev_var ?(env = empty_env) = succ_ev ~env pp_var Format.pp_print_string ev_var

let%test _ = succ_ev_var ("ABC", "0") ""
let%test _ = succ_ev_var ("ABC", "0") ""

let%test _ =
  succ_ev_var
    ~env:{ empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "2")) }
    ("ABC", "0")
    "2"
;;

let%test _ =
  succ_ev_var
    ~env:
      { empty_env with
        vars = SMap.singleton "ABC" (IndArray (IMap.of_list [ 0, "a"; 1, "b"; 2, "c" ]))
      }
    ("ABC", "0")
    "a"
;;

let%test _ =
  succ_ev_var
    ~env:
      { empty_env with
        vars = SMap.singleton "ABC" (IndArray (IMap.of_list [ 0, "a"; 1, "b"; 2, "c" ]))
      }
    ("ABC", "1")
    "b"
;;

let%test _ =
  succ_ev_var
    ~env:
      { empty_env with
        vars = SMap.singleton "ABC" (IndArray (IMap.of_list [ 0, "a"; 1, "b"; 2, "c" ]))
      }
    ("ABC", "3")
    ""
;;

let%test _ =
  succ_ev_var
    ~env:
      { empty_env with
        vars =
          SMap.singleton
            "ABC"
            (AssocArray (SMap.of_list [ "a", "a1"; "b", "b1"; "0", "01" ]))
      }
    ("ABC", "0")
    "01"
;;

let%test _ =
  succ_ev_var
    ~env:
      { empty_env with
        vars =
          SMap.singleton
            "ABC"
            (AssocArray (SMap.of_list [ "a", "a1"; "b", "b1"; "0", "01" ]))
      }
    ("ABC", "b")
    "b1"
;;

let%test _ =
  succ_ev_var
    ~env:
      { empty_env with
        vars =
          SMap.singleton
            "ABC"
            (AssocArray (SMap.of_list [ "a", "a1"; "b", "b1"; "0", "01" ]))
      }
    ("ABC", "!")
    ""
;;

(* -------------------- Arithmetic -------------------- *)

let succ_ev_arithm ?(env = empty_env) =
  succ_ev ~env pp_arithm Format.pp_print_int ev_arithm
;;

let fail_ev_arithm ?(env = empty_env) =
  fail_ev ~env pp_arithm Format.pp_print_int ev_arithm
;;

let%test _ = succ_ev_arithm (Plus (Num 1, Num 2)) 3
let%test _ = succ_ev_arithm (Div (Num 1, Num 3)) 0
let%test _ = succ_ev_arithm (Div (Num 2, Num 3)) 0
let%test _ = succ_ev_arithm (Div (NEqual (Num 1, Num 2), Greater (Num 3, Num 1))) 1
let%test _ = fail_ev_arithm (Div (Num 1, Num 0)) "Division by 0"

(* -------------------- Parameter expansion -------------------- *)

let succ_ev_param_exp ?(env = empty_env) =
  succ_ev ~env pp_param_exp Format.pp_print_string ev_param_exp
;;

let fail_ev_param_exp ?(env = empty_env) =
  fail_ev ~env pp_param_exp Format.pp_print_string ev_param_exp
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "abc")) }
    (Param ("ABC", "0"))
    "abc"
;;

let%test _ = succ_ev_param_exp (Param ("ABC", "0")) ""

let%test _ =
  succ_ev_param_exp
    ~env:{ empty_env with vars = SMap.singleton "3" (IndArray (IMap.singleton 0 "123")) }
    (PosParam 3)
    "123"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "12345")) }
    (Length ("ABC", "0"))
    "5"
;;

let%test _ =
  succ_ev_param_exp
    ~env:{ empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "")) }
    (Length ("ABC", "0"))
    "0"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 0, Some (Num 3)))
    "012"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 0, Some (Num 5)))
    "01234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 0, Some (Num 7)))
    "01234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 2, Some (Num 2)))
    "23"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 2, Some (Num 0)))
    ""
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 2, None))
    "234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num (-3), Some (Num 2)))
    "23"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num (-1), Some (Num 2)))
    "4"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num (-6), Some (Num 3)))
    ""
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num (-3), Some (Num (-2))))
    "2"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num (-3), Some (Num (-3))))
    ""
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 0, Some (Num (-5))))
    ""
;;

let%test _ =
  fail_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 4, Some (Num (-3))))
    "substring expression < 0"
;;

let%test _ =
  fail_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Num 0, Some (Num (-6))))
    "substring expression < 0"
;;

let%test _ =
  fail_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (Substring (("ABC", "0"), Div (Num 1, Num 0), None))
    "Division by 0"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMinBeg (("ABC", "0"), "*"))
    "01234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMinBeg (("ABC", "0"), "?"))
    "1234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMinBeg (("ABC", "0"), "[0-9][0-9]"))
    "234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMinBeg (("ABC", "0"), "23"))
    "01234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMinBeg (("ABC", "0"), "01"))
    "234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMaxBeg (("ABC", "0"), "*"))
    ""
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMinEnd (("ABC", "0"), "?"))
    "0123"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMinEnd (("ABC", "0"), "*"))
    "01234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMaxEnd (("ABC", "0"), "?"))
    "0123"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (CutMaxEnd (("ABC", "0"), "*"))
    ""
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (SubstOne (("ABC", "0"), "?", "a"))
    "a1234"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (SubstOne (("ABC", "0"), "*", "a"))
    "a"
;;

let%test _ =
  succ_ev_param_exp
    ~env:{ empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "")) }
    (SubstOne (("ABC", "0"), "*", "a"))
    "a"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (SubstAll (("ABC", "0"), "?", "a"))
    "aaaaa"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (SubstAll (("ABC", "0"), "*", "a"))
    "a"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with
        vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "abacab"))
      }
    (SubstAll (("ABC", "0"), "a", "heh"))
    "hehbhehchehb"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (SubstBeg (("ABC", "0"), "*", "a"))
    "a"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with
        vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "abcabab"))
      }
    (SubstBeg (("ABC", "0"), "ab", "!"))
    "!cabab"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "01234")) }
    (SubstEnd (("ABC", "0"), "*", "a"))
    "a"
;;

let%test _ =
  succ_ev_param_exp
    ~env:
      { empty_env with
        vars = SMap.singleton "ABC" (IndArray (IMap.singleton 0 "abcabab"))
      }
    (SubstEnd (("ABC", "0"), "ab", "!"))
    "abcab!"
;;

(* -------------------- Filename expansion -------------------- *)

let succ_ev_filename_exp ?(env = empty_env) =
  succ_ev
    ~env
    Format.pp_print_string
    (Format.pp_print_list ~pp_sep:Format.pp_print_newline Format.pp_print_string)
    ev_filename_exp
;;

let cwd_satisfy c =
  let cwd = Sys.getcwd () in
  cwd
  |> Sys.readdir
  |> Array.to_list
  |> List.filter (fun f ->
         Sys.file_exists (Filename.concat cwd f) && (not (f.[0] = '.')) && c f)
  |> List.sort String.compare
;;

let%test _ =
  succ_ev_filename_exp "*.ml" (cwd_satisfy (fun f -> Filename.check_suffix f ".ml"))
;;

(* -------------------- Word -------------------- *)

let succ_ev_word ?(env = empty_env) =
  succ_ev
    ~env
    pp_word
    (fun fmt (env, ss) ->
      pp_environment fmt env;
      Format.pp_print_list ~pp_sep:Format.pp_print_newline Format.pp_print_string fmt ss)
    ev_word
;;

let fail_ev_word ?(env = empty_env) =
  fail_ev
    ~env
    pp_word
    (fun fmt (env, ss) ->
      pp_environment fmt env;
      Format.pp_print_list ~pp_sep:Format.pp_print_newline Format.pp_print_string fmt ss)
    ev_word
;;

let%test _ =
  succ_ev_word
    (BraceExp [ ParamExp (Param ("X", "0")); Word "y" ])
    (empty_env, [ ""; "y" ])
;;

let%test _ =
  let env =
    { empty_env with vars = SMap.singleton "M" (IndArray (IMap.singleton 0 "meow")) }
  in
  succ_ev_word ~env (ParamExp (Param ("M", "0"))) (env, [ "meow" ])
;;

let%test _ = succ_ev_word (ArithmExp (Num 5)) (empty_env, [ "5" ])
let%test _ = fail_ev_word (ArithmExp (Div (Num 5, Num 0))) "Division by 0"

let%test _ =
  succ_ev_word
    (FilenameExp "*.*")
    (empty_env, cwd_satisfy (fun f -> String.contains f '.'))
;;

let%test _ = succ_ev_word (Word "hey") (empty_env, [ "hey" ])

(* -------------------- Assignment -------------------- *)

let succ_ev_assignt ?(env = empty_env) = succ_ev ~env pp_assignt pp_environment ev_assignt
let fail_ev_assignt ?(env = empty_env) = fail_ev ~env pp_assignt pp_environment ev_assignt

let%test _ =
  succ_ev_assignt
    (SimpleAssignt (("X", "0"), Word "x"))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
;;

let%test _ =
  fail_ev_assignt
    (SimpleAssignt (("X", "0"), BraceExp [ Word "x"; Word "y" ]))
    "Illegal expansion in simple assignment"
;;

let%test _ =
  succ_ev_assignt
    (SimpleAssignt (("X", "1"), Word "x"))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 1 "x")) }
;;

let%test _ =
  succ_ev_assignt
    (SimpleAssignt (("X", "a"), Word "x"))
    { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "a" "x")) }
;;

let%test _ =
  fail_ev_assignt
    (SimpleAssignt (("X", "1"), BraceExp [ Word "x"; Word "y" ]))
    "Illegal expansion in simple assignment"
;;

let%test _ =
  succ_ev_assignt
    (IndArrAssignt ("X", [ Word "x" ]))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
;;

let%test _ =
  succ_ev_assignt
    (IndArrAssignt ("X", [ Word "x"; BraceExp [ Word "y"; Word "z" ] ]))
    { empty_env with
      vars = SMap.singleton "X" (IndArray (IMap.of_list [ 0, "x"; 1, "y"; 2, "z" ]))
    }
;;

let%test _ =
  succ_ev_assignt
    (AssocArrAssignt ("X", [ "x", Word "y" ]))
    { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "x" "y")) }
;;

let%test _ =
  fail_ev_assignt
    (AssocArrAssignt ("X", [ "x", BraceExp [ Word "y"; Word "z" ] ]))
    "Illegal expansion in associative array assignment"
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
    (SimpleAssignt (("X", "0"), Word "y"))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "y")) }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
    (SimpleAssignt (("X", "0"), Word "y"))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "y")) }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 1 "x")) }
    (SimpleAssignt (("X", "0"), Word "y"))
    { empty_env with
      vars = SMap.singleton "X" (IndArray (IMap.of_list [ 1, "x"; 0, "y" ]))
    }
;;

let%test _ =
  succ_ev_assignt
    ~env:
      { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "0" "x")) }
    (SimpleAssignt (("X", "0"), Word "y"))
    { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "0" "y")) }
;;

let%test _ =
  succ_ev_assignt
    ~env:
      { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "a" "x")) }
    (SimpleAssignt (("X", "0"), Word "y"))
    { empty_env with
      vars = SMap.singleton "X" (AssocArray (SMap.of_list [ "a", "x"; "0", "y" ]))
    }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
    (SimpleAssignt (("X", "1"), Word "y"))
    { empty_env with
      vars = SMap.singleton "X" (IndArray (IMap.of_list [ 0, "x"; 1, "y" ]))
    }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 1 "x")) }
    (SimpleAssignt (("X", "1"), Word "y"))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 1 "y")) }
;;

let%test _ =
  succ_ev_assignt
    ~env:
      { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "1" "x")) }
    (SimpleAssignt (("X", "1"), Word "y"))
    { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "1" "y")) }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
    (SimpleAssignt (("X", "a"), Word "y"))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "y")) }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 1 "x")) }
    (SimpleAssignt (("X", "a"), Word "y"))
    { empty_env with
      vars = SMap.singleton "X" (IndArray (IMap.of_list [ 1, "x"; 0, "y" ]))
    }
;;

let%test _ =
  succ_ev_assignt
    ~env:
      { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "1" "x")) }
    (SimpleAssignt (("X", "a"), Word "y"))
    { empty_env with
      vars = SMap.singleton "X" (AssocArray (SMap.of_list [ "1", "x"; "a", "y" ]))
    }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
    (IndArrAssignt ("X", [ Word "x" ]))
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
;;

let%test _ =
  succ_ev_assignt
    ~env:{ empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "x")) }
    (AssocArrAssignt ("X", [ "x", Word "y" ]))
    { empty_env with vars = SMap.singleton "X" (AssocArray (SMap.singleton "x" "y")) }
;;

(* -------------------- Simple command -------------------- *)

let succ_ev_cmd ?(env = empty_env) = succ_ev ~env pp_cmd pp_environment ev_cmd
let fail_ev_cmd ?(env = empty_env) = fail_ev ~env pp_cmd pp_environment ev_cmd

(* TODO: add tests for user-defined functions and sourced scripts *)

let%test _ =
  succ_ev_cmd
    (Assignt [ SimpleAssignt (("X", "0"), Word "a") ])
    { empty_env with vars = SMap.singleton "X" (IndArray (IMap.singleton 0 "a")) }
;;

let%test _ =
  succ_ev_cmd
    (Command ([], [ Word "echo"; Word "123" ]))
    { empty_env with stdout = "123" }
;;

let%test _ =
  succ_ev_cmd
    (Command ([], [ Word "echo"; Word "1"; BraceExp [ ArithmExp (Num 2); Word "3" ] ]))
    { empty_env with stdout = "1 2 3" }
;;
