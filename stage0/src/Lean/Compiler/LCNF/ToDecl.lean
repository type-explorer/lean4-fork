/-
Copyright (c) 2022 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
import Lean.Meta.Transform
import Lean.Meta.Match.MatcherInfo
import Lean.Compiler.ImplementedByAttr
import Lean.Compiler.LCNF.ToLCNF

namespace Lean.Compiler.LCNF
/--
Inline constants tagged with the `[macroInline]` attribute occurring in `e`.
-/
def macroInline (e : Expr) : CoreM Expr :=
  Core.transform e fun e => do
    let .const declName us := e.getAppFn | return .continue
    unless hasMacroInlineAttribute (← getEnv) declName do return .continue
    let val ← Core.instantiateValueLevelParams (← getConstInfo declName) us
    return .visit <| val.beta e.getAppArgs

private def normalizeAlt (e : Expr) (numParams : Nat) : MetaM Expr :=
  Meta.lambdaTelescope e fun xs body => do
    if xs.size == numParams then
      return e
    else if xs.size > numParams then
      let body ← Meta.mkLambdaFVars xs[numParams:] body
      let body ← Meta.withLetDecl (← mkFreshUserName `_k) (← Meta.inferType body) body fun x => Meta.mkLetFVars #[x] x
      Meta.mkLambdaFVars xs[:numParams] body
    else
      Meta.forallBoundedTelescope (← Meta.inferType e) (numParams - xs.size) fun ys _ =>
        Meta.mkLambdaFVars (xs ++ ys) (mkAppN e ys)

/--
Inline auxiliary `matcher` applications.
-/
partial def inlineMatchers (e : Expr) : CoreM Expr :=
  Meta.MetaM.run' <| Meta.transform e fun e => do
    let .const declName us := e.getAppFn | return .continue
    let some info ← Meta.getMatcherInfo? declName | return .continue
    let numArgs := e.getAppNumArgs
    if numArgs > info.arity then
      return .continue
    else if numArgs < info.arity then
      Meta.forallBoundedTelescope (← Meta.inferType e) (info.arity - numArgs) fun xs _ =>
        return .visit (← Meta.mkLambdaFVars xs (mkAppN e xs))
    else
      let mut args := e.getAppArgs
      let numAlts := info.numAlts
      let altNumParams := info.altNumParams
      let rec inlineMatcher (i : Nat) (args : Array Expr) (letFVars : Array Expr) : MetaM Expr := do
        if i < numAlts then
          let altIdx := i + info.getFirstAltPos
          let numParams := altNumParams[i]!
          let alt ← normalizeAlt args[altIdx]! numParams
          Meta.withLetDecl (← mkFreshUserName `_alt) (← Meta.inferType alt) alt fun altFVar =>
            inlineMatcher (i+1) (args.set! altIdx altFVar) (letFVars.push altFVar)
        else
          let info ← getConstInfo declName
          let value := (← Core.instantiateValueLevelParams info us).beta args
          Meta.mkLetFVars letFVars value
      return .visit (← inlineMatcher 0 args #[])

/--
Apply `[implementedBy]` to `casesOn`.

We apply them eagerly because we have a `cases` constructor in LCNF.
We do not replace other `[implementedBy]` annotations because they disrupt
the effectiveness of theorems provided by users (this feature has not been implemented yet).
This is not an issue for `casesOn` since it is very unlikely an user will define
a theorem / rewriting rule with `casesOn` on the right-hand side.
-/
def applyCasesOnImplementedBy (e : Expr) : CoreM Expr := do
  let env ← getEnv
  if !hasImplementedByCasesOn env e then
    return e
  else
    Meta.MetaM.run' <| Meta.transform e fun e => do
      let .const declName us := e | return .continue
      unless isCasesOnRecursor env declName do return .continue
      let some declName' := getImplementedBy? env declName | return .continue
      return .done (.const declName' us)
where
  hasImplementedByCasesOn (env : Environment) (e : Expr) : Bool :=
    Option.isSome <| e.find? fun
      | .const declName _ => isCasesOnRecursor env declName || (getImplementedBy? env declName).isSome
      | _ => false

/--
Replace nested occurrences of `unsafeRec` names with the safe ones.
-/
private def replaceUnsafeRecNames (value : Expr) : CoreM Expr :=
  Core.transform value fun e =>
    match e with
    | .const declName us =>
      if let some safeDeclName := isUnsafeRecName? declName then
        return .done (.const safeDeclName us)
      else
        return .done e
    | _ => return .continue

/--
Convert the given declaration from the Lean environment into `Decl`.
The steps for this are roughly:
- partially erasing type information of the declaration
- eta-expanding the declaration value.
- if the declaration has an unsafe-rec version, use it.
- expand declarations tagged with the `[macroInline]` attribute
- turn the resulting term into LCNF declaration
-/
def toDecl (declName : Name) : CompilerM Decl := do
  let env ← getEnv
  let some info := env.find? (mkUnsafeRecName declName) <|> env.find? declName | throwError "declaration `{declName}` not found"
  let some value := info.value? | throwError "declaration `{declName}` does not have a value"
  let (type, value) ← Meta.MetaM.run' do
    let type  ← toLCNFType info.type
    let value ← Meta.lambdaTelescope value fun xs body => do Meta.mkLambdaFVars xs (← Meta.etaExpand body)
    let value ← replaceUnsafeRecNames value
    let value ← macroInline value
    let value ← inlineMatchers value
    let value ← applyCasesOnImplementedBy value
    return (type, value)
  let value ← toLCNF value
  if let .fun decl (.return _) := value then
    eraseFVar decl.fvarId (recursive := false)
    return { name := declName, params := decl.params, type, value := decl.value, levelParams := info.levelParams }
  else
    return { name := declName, params := #[], type, value, levelParams := info.levelParams }

end Lean.Compiler.LCNF