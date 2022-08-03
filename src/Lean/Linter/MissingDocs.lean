/-
Copyright (c) 2022 Mario Carneiro. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.

Authors: Mario Carneiro
-/
import Lean.Elab.Command
import Lean.Elab.Tactic.Config
import Lean.Linter.Util

namespace Lean.Linter
open Elab.Command Parser.Command
open Parser.Term hiding «set_option»

register_builtin_option linter.missingDocs : Bool := {
  defValue := false
  descr := "enable the 'missing documentation' linter"
}

def getLinterMissingDocs (o : Options) : Bool := getLinterValue linter.missingDocs o


namespace MissingDocs

abbrev SimpleHandler := Syntax → CommandElabM Unit
abbrev Handler := Bool → SimpleHandler

unsafe def mkHandlerUnsafe (constName : Name) : ImportM Handler := do
  let env  := (← read).env
  let opts := (← read).opts
  match env.find? constName with
  | none      => throw ↑s!"unknown constant '{constName}'"
  | some info => match info.type with
    | Expr.const ``SimpleHandler _ => do
      let h ← IO.ofExcept $ env.evalConst SimpleHandler opts constName
      pure fun enabled stx => if enabled then h stx else pure ()
    | Expr.const ``Handler _ =>
      IO.ofExcept $ env.evalConst Handler opts constName
    | _ => throw ↑s!"unexpected missing docs handler at '{constName}', `MissingDocs.Handler` or `MissingDocs.SimpleHandler` expected"

@[implementedBy mkHandlerUnsafe]
opaque mkHandler (constName : Name) : ImportM Handler

builtin_initialize missingDocsExt :
  PersistentEnvExtension (Name × Name) (Name × Name × Handler) (List (Name × Name) × NameMap Handler) ←
  registerPersistentEnvExtension {
    name            := "missing docs extension"
    mkInitial       := pure ([], {})
    addImportedFn   := fun as =>
      ([], ·) <$> as.foldlM (init := {}) fun s as =>
        as.foldlM (init := s) fun s (n, k) => s.insert k <$> mkHandler n
    addEntryFn      := fun (entries, s) (n, k, h) => ((n, k)::entries, s.insert k h)
    exportEntriesFn := fun s => s.1.reverse.toArray
    statsFn := fun s => format "number of local entries: " ++ format s.1.length
  }

def addHandler (env : Environment) (declName key : Name) (h : Handler) : Environment :=
  missingDocsExt.addEntry env (declName, key, h)

def getHandlers (env : Environment) : NameMap Handler := (missingDocsExt.getState env).2

partial def missingDocs : Linter := fun stx => do
  if let some h := (getHandlers (← getEnv)).find? stx.getKind then
    h (getLinterMissingDocs (← getOptions)) stx

builtin_initialize
  let name := `missingDocsHandler
  registerBuiltinAttribute {
    name
    descr := "adds a syntax traversal for the missing docs linter"
    applicationTime := .afterCompilation
    add := fun declName stx kind => do
      unless kind == AttributeKind.global do throwError "invalid attribute '{name}', must be global"
      let env ← getEnv
      unless (env.getModuleIdxFor? declName).isNone do
        throwError "invalid attribute '{name}', declaration is in an imported module"
      let decl ← getConstInfo declName
      let fnNameStx ← Attribute.Builtin.getIdent stx
      let key ← Elab.resolveGlobalConstNoOverloadWithInfo fnNameStx
      unless decl.levelParams.isEmpty && (decl.type == .const ``Handler [] || decl.type == .const ``SimpleHandler []) do
        throwError "unexpected missing docs handler at '{declName}', `MissingDocs.Handler` or `MissingDocs.SimpleHandler` expected"
      setEnv <| missingDocsExt.addEntry env (declName, key, ← mkHandler declName)
  }

def lint (stx : Syntax) (msg : String) : CommandElabM Unit :=
  logWarningAt stx s!"missing doc string for {msg} [linter.missingDocs]"

def lintNamed (stx : Syntax) (msg : String) : CommandElabM Unit :=
  lint stx s!"{msg} {stx.getId}"

def lintField (parent stx : Syntax) (msg : String) : CommandElabM Unit :=
  lint stx s!"{msg} {parent.getId}.{stx.getId}"

def lintDeclHead (k : SyntaxNodeKind) (id : Syntax) : CommandElabM Unit := do
  if k == ``«abbrev» then lintNamed id s!"public abbrev"
  else if k == ``«def» then lintNamed id "public def"
  else if k == ``«opaque» then lintNamed id "public opaque"
  else if k == ``«axiom» then lintNamed id "public axiom"
  else if k == ``«inductive» then lintNamed id "public inductive"
  else if k == ``classInductive then lintNamed id "public inductive"
  else if k == ``«structure» then lintNamed id "public structure"

def checkDecl (args : Array Syntax) : CommandElabM Unit := do
  let #[head, rest] := args | return
  if head[2][0].getKind == ``«private» then return -- not private
  let k := rest.getKind
  if head[0].isNone then -- no doc string
    lintDeclHead k rest[1][0]
  if k == ``«inductive» || k == ``classInductive then
    for stx in rest[4].getArgs do
      let head := stx[1]
      if head[2][0].getKind != ``«private» && head[0].isNone then
        lintField rest[1][0] stx[2] "public constructor"
    unless rest[5].isNone do
      for stx in rest[5][0][1].getArgs do
        let head := stx[0]
        if head[2][0].getKind == ``«private» then return -- not private
        if head[0].isNone then -- no doc string
          lintField rest[1][0] stx[1] "computed field"
  else if rest.getKind == ``«structure» then
    unless rest[5].isNone || rest[5][2].isNone do
      for stx in rest[5][2][0].getArgs do
        let head := stx[0]
        if head[2][0].getKind != ``«private» && head[0].isNone then
          if stx.getKind == ``structSimpleBinder then
            lintField rest[1][0] stx[1] "public field"
          else
            for stx in stx[2].getArgs do
              lintField rest[1][0] stx "public field"

def main (stx : Syntax) (k : SyntaxNodeKind) (args : Array Syntax) : CommandElabM Unit := do
  if k == ``declaration then
    checkDecl args
  else if k == ``«initialize» then
    let #[head, _, rest, _] := args | return
    if rest.isNone then return
    if head[2][0].getKind != ``«private» && head[0].isNone then
      lintNamed rest[0] "initializer"
  else if k == ``«syntax» then
    if stx[0].isNone && stx[2][0][0].getKind != ``«local» then
      if stx[5].isNone then lint stx[3] "syntax"
      else lintNamed stx[5][0][3] "syntax"
  else if k == ``syntaxAbbrev then
    if stx[0].isNone then
      lintNamed stx[2] "syntax"
  else if k == ``syntaxCat then
    if stx[0].isNone then
      lintNamed stx[2] "syntax category"
  else if k == ``«macro» then
    if stx[0].isNone && stx[1][0][0].getKind != ``«local» then
      if stx[4].isNone then lint stx[2] "macro"
      else lintNamed stx[4][0][3] "macro"
  else if k == ``«elab» then
    if stx[0].isNone && stx[1][0][0].getKind != ``«local» then
      if stx[4].isNone then lint stx[2] "elab"
      else lintNamed stx[4][0][3] "elab"
  else if k == ``classAbbrev then
    let head := stx[0]
    if head[2][0].getKind != ``«private» && head[0].isNone then
      lintNamed stx[3] "class abbrev"
  else if k == ``Parser.Tactic.declareSimpLikeTactic then
    if stx[0].isNone then
      lintNamed stx[3] "simp-like tactic"
  else if k == ``Option.registerBuiltinOption then
    if stx[0].isNone then
      lintNamed stx[2] "option"
  else if k == ``Option.registerOption then
    if stx[0].isNone then
      lintNamed stx[2] "option"
  else if k == ``registerSimpAttr then
    if stx[0].isNone then
      lintNamed stx[2] "simp attr"
  else if k == ``Elab.Tactic.configElab then
    if stx[0].isNone then
      lintNamed stx[2] "config elab"
  else return

def handleIn : Handler := fun _ stx => do
  if stx[0].getKind == ``«set_option» then
    let opts ← Elab.elabSetOption stx[0][1] stx[0][2]
    withScope (fun scope => { scope with opts }) do
      missingDocs stx[2]

def handleMutual : Handler := fun _ stx => do
  stx[1].getArgs.forM missingDocs

builtin_initialize addLinter missingDocs