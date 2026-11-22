/-
Text forms of the kernel: a program as s-expressions, printed and parsed.
Used for hand-written kernel programs in the checks and for diagnostics;
the vector files name programs in the Roc generator's terms instead
(`Turns.Structure`).
-/
import Turns.Kernel
namespace Turns

def Ref.sx : Ref → String
  | .layer i => s!"(L {i})"
  | .cell c => s!"(C {c})"

def Expr.sx : Expr → String
  | .lit n => toString n
  | .rd r => r.sx
  | .add a b => s!"(+ {a.sx} {b.sx})"
  | .mul a b => s!"(* {a.sx} {b.sx})"
  | .mod a b => s!"(% {a.sx} {b.sx})"
  | .div a b => s!"(/ {a.sx} {b.sx})"
  | .eq a b => s!"(= {a.sx} {b.sx})"

mutual
partial def Node.sx : Node → String
  | .show e => s!"(show {e.sx})"
  | .joined es => "(joined" ++ String.join (es.map fun e => s!" {e.sx}") ++ ")"
  | .keyed e => s!"(keyed {e.sx})"
  | .bump h => "(bump" ++ String.join (h.map fun (r, e) => s!" ({r.sx} {e.sx})") ++ ")"
  | .state init body => s!"(state {init}{blockSx body})"
  | .derive e body => s!"(derive {e.sx}{blockSx body})"
  | .when sel yes no => s!"(when {sel.sx} ({listSx yes}) ({listSx no}))"
  | .switch sel a b c => s!"(switch {sel.sx} ({listSx a}) ({listSx b}) ({listSx c}))"
  | .each src body => s!"(each {src.sx}{blockSx body})"
partial def blockSx (ns : List Node) : String := String.join (ns.map fun n => " " ++ n.sx)
partial def listSx (ns : List Node) : String := " ".intercalate (ns.map Node.sx)
end

inductive Sx where
  | atom (s : String)
  | list (xs : List Sx)

instance : Inhabited Sx := ⟨.atom ""⟩

def words (s : String) : List String := (s.splitOn " ").filter (· ≠ "")

def tokens (s : String) : List String := words ((s.replace "(" " ( ").replace ")" " ) ")

mutual
partial def parseSx : List String → Option (Sx × List String)
  | "(" :: ts => parseSxs ts []
  | ")" :: _ => none
  | t :: ts => some (.atom t, ts)
  | [] => none
partial def parseSxs : List String → List Sx → Option (Sx × List String)
  | ")" :: ts, acc => some (.list acc.reverse, ts)
  | ts, acc =>
      match parseSx ts with
      | some (x, ts') => parseSxs ts' (x :: acc)
      | none => none
end

def toRef : Sx → Option Ref
  | .list [.atom "L", .atom i] => i.toNat?.map .layer
  | .list [.atom "C", .atom i] => i.toNat?.map .cell
  | _ => none

partial def toExpr : Sx → Option Expr
  | .atom s => s.toInt?.map .lit
  | .list [.atom "+", a, b] => do pure (.add (← toExpr a) (← toExpr b))
  | .list [.atom "*", a, b] => do pure (.mul (← toExpr a) (← toExpr b))
  | .list [.atom "%", a, b] => do pure (.mod (← toExpr a) (← toExpr b))
  | .list [.atom "/", a, b] => do pure (.div (← toExpr a) (← toExpr b))
  | .list [.atom "=", a, b] => do pure (.eq (← toExpr a) (← toExpr b))
  | x => (toRef x).map .rd

partial def toNode : Sx → Option Node
  | .list [.atom "show", e] => do pure (.show (← toExpr e))
  | .list (.atom "joined" :: es) => do pure (.joined (← es.mapM toExpr))
  | .list [.atom "keyed", e] => do pure (.keyed (← toExpr e))
  | .list (.atom "bump" :: ws) => do
      pure (.bump (← ws.mapM fun
        | .list [r, e] => do pure (← toRef r, ← toExpr e)
        | _ => none))
  | .list (.atom "state" :: .atom i :: body) => do pure (.state (← i.toInt?) (← body.mapM toNode))
  | .list (.atom "derive" :: e :: body) => do pure (.derive (← toExpr e) (← body.mapM toNode))
  | .list [.atom "when", e, .list yes, .list no] => do
      pure (.when (← toExpr e) (← yes.mapM toNode) (← no.mapM toNode))
  | .list [.atom "switch", e, .list a, .list b, .list c] => do
      pure (.switch (← toExpr e) (← a.mapM toNode) (← b.mapM toNode) (← c.mapM toNode))
  | .list (.atom "each" :: e :: body) => do pure (.each (← toExpr e) (← body.mapM toNode))
  | _ => none

def parseBody (s : String) : Option (List Node) :=
  match parseSx (tokens ("(" ++ s ++ ")")) with
  | some (.list xs, []) => xs.mapM toNode
  | _ => none

end Turns
