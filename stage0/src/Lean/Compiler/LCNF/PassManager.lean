/-
Copyright (c) 2022 Henrik Böving. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Henrik Böving
-/
import Lean.Attributes
import Lean.Environment
import Lean.Meta.Basic

import Lean.Compiler.LCNF.CompilerM

namespace Lean.Compiler.LCNF

structure Pass where
  name : Name
  run : Array Decl → CompilerM (Array Decl)
  deriving Inhabited

structure PassInstaller where
  install : Array Pass → CompilerM (Array Pass)
  deriving Inhabited

structure PassManager where
  passes : Array Pass
  deriving Inhabited

namespace Pass

def mkPerDeclaration (name : Name) (run : Decl → CompilerM Decl) : Pass where
  name := name
  run := fun xs => xs.mapM run

end Pass

namespace PassInstaller

def installAtEnd (p : Pass) : PassInstaller where
  install passes := return passes.push p

def append (passesNew : Array Pass) : PassInstaller where
  install passes := return passes ++ passesNew

def installAfter (targetName : Name) (p : Pass) : PassInstaller where
  install passes :=
    if let some idx := passes.findIdx? (·.name == targetName) then
      return passes.insertAt (idx + 1) p
    else
      throwError s!"Tried to insert pass {p.name} after {targetName} but {targetName} is not in the pass list"

def installBefore (targetName : Name) (p : Pass) : PassInstaller where
  install passes :=
    if let some idx := passes.findIdx? (·.name == targetName) then
      return passes.insertAt idx p
    else
      throwError s!"Tried to insert pass {p.name} after {targetName} but {targetName} is not in the pass list"

def replacePass (targetName : Name) (p : Pass → CompilerM Pass) : PassInstaller where
  install passes := do
    let some idx := passes.findIdx? (·.name == targetName) | throwError s!"Tried to replace {targetName} but {targetName} is not in the pass list"
    let target := passes[idx]!
    let replacement ← p target
    return passes.set! idx replacement

def run (manager : PassManager) (installer : PassInstaller) : CompilerM PassManager := do
  return { manager with passes := (←installer.install manager.passes) }

builtin_initialize passInstallerExt : SimplePersistentEnvExtension Name (Array Name) ←
  registerSimplePersistentEnvExtension {
    name := `cpass,
    addImportedFn := fun imported => imported.foldl (init := #[]) fun acc a => acc.append a
    addEntryFn := fun is i => is.push i,
  }

def addPass (declName : Name) : CoreM Unit := do
  let info ← getConstInfo declName
  match info.type with
  | .const `Lean.Compiler.LCNF.PassInstaller .. =>
    modifyEnv fun env => passInstallerExt.addEntry env declName
  | _ =>
    throwError "invalid 'cpass' only 'PassInstaller's can be added via the 'cpass' attribute: {info.type}"

builtin_initialize
  registerBuiltinAttribute {
    name  := `cpass
    descr := "compiler passes for the code generator"
    add   := fun declName stx kind => do
      Attribute.Builtin.ensureNoArgs stx
      unless kind == AttributeKind.global do throwError "invalid attribute 'cpass', must be global"
      discard <| addPass declName
    applicationTime := .afterCompilation
  }

private unsafe def getPassInstallerUnsafe (declName : Name) : MetaM PassInstaller := do
  ofExcept <| (← getEnv).evalConstCheck PassInstaller (← getOptions) ``PassInstaller declName

@[implementedBy getPassInstallerUnsafe]
private opaque getPassInstaller (declName : Name) : MetaM PassInstaller

def runFromDecl (manager : PassManager) (declName : Name) : CompilerM PassManager := do
  let installer ← getPassInstaller declName |>.run'
  installer.run manager

end PassInstaller

namespace PassManager

end PassManager

end Lean.Compiler.LCNF
