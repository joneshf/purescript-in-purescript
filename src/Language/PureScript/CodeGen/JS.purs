module Language.PureScript.CodeGen.JS
  ( RequirePathType(..)
  , ModuleType(..)
  , declToJs
  , moduleToJs
  ) where

import Control.Apply
import Control.Monad (replicateM)
import Data.Array
import Data.Either
import Data.Function (on)
import Data.Maybe
import Data.Maybe.Unsafe (fromJust)
import Data.Tuple
import Data.Tuple3
import Data.Tuple5
import Data.Traversable (for, traverse)
import qualified Data.Map as M

import Language.PureScript.CodeGen.Common
import Language.PureScript.CodeGen.JS.AST
import Language.PureScript.Declarations
import Language.PureScript.Environment
import Language.PureScript.Errors
import Language.PureScript.Names
import Language.PureScript.Options
import Language.PureScript.Optimizer
import Language.PureScript.Supply
import Language.PureScript.Traversals (sndM)
import Language.PureScript.Types

-- |
-- Different ways of referencing a module in a require(...) statement - absolute paths, and module name only.
--
data RequirePathType = RequireAbsolute (String -> String) | RequireLocal

-- |
-- Different types of modules which are supported
--
data ModuleType = CommonJS RequirePathType | Globals

-- |
-- Generate code in the simplified Javascript intermediate representation for all declarations in a
-- module.
--
moduleToJs :: forall m. (Monad m) => ModuleType -> Options -> Module -> Environment -> SupplyT m [JS]
moduleToJs mt opts@(Options o) (Module name decls (Just exps)) env = do
  let jsImports = map (importToJs mt opts) $ (\x -> x \\ [name]) $ nub $ concatMap imports decls
  jsDecls <- traverse (\decl -> declToJs opts name decl env) decls
  let optimized = concat $ map (map $ optimize opts) $ catMaybes jsDecls
  let isModuleEmpty = null optimized
  let moduleBody = JSStringLiteral "use strict" : jsImports ++ optimized
  let moduleExports = JSObjectLiteral $ concatMap exportToJs exps
  return $ case mt of
    CommonJS _ -> moduleBody ++ [JSAssignment (JSAccessor "exports" (JSVar "module")) moduleExports]
    Globals | not isModuleEmpty ->
      [ JSVariableIntroduction (fromJust o.browserNamespace)
                               (Just (JSBinary Or (JSVar (fromJust o.browserNamespace)) (JSObjectLiteral [])) )
      , JSAssignment (JSAccessor (moduleNameToJs name) (JSVar (fromJust o.browserNamespace)))
                     (JSApp (JSFunction Nothing [] (JSBlock (moduleBody ++ [JSReturn moduleExports]))) [])
      ]
    _ -> []
moduleToJs _ _ _ _ = theImpossibleHappened "Exports should have been elaborated in name desugaring"

importToJs :: ModuleType -> Options -> ModuleName -> JS
importToJs mt (Options opts) mn = JSVariableIntroduction (moduleNameToJs mn) (Just moduleBody)
  where
  moduleBody = case mt of
    CommonJS rpt -> JSApp (JSVar "require") [JSStringLiteral (requireModule rpt mn)]
    Globals -> JSAccessor (moduleNameToJs mn) (JSVar (fromJust opts.browserNamespace))

requireModule :: RequirePathType -> ModuleName -> String
requireModule RequireLocal mn = runModuleName mn
requireModule (RequireAbsolute f) mn = f (runModuleName mn)

imports :: Declaration -> [ModuleName]
imports =
  case everythingOnValues (++) (const []) collect (const []) (const []) (const []) of
    Tuple5 f _ _ _ _ -> f
  where
  collect :: Value -> [ModuleName]
  collect (Var (Qualified (Just mn) _)) = [mn]
  collect (Constructor (Qualified (Just mn) _)) = [mn]
  collect _ = []

-- |
-- Generate code in the simplified Javascript intermediate representation for a declaration
--
declToJs :: forall m. (Monad m) => Options -> ModuleName -> Declaration -> Environment -> SupplyT m (Maybe [JS])
declToJs opts mp (ValueDeclaration ident _ _ _ val) e = do
  js <- valueToJs opts mp e val
  return $ Just [JSVariableIntroduction (identToJs ident) (Just js)]
declToJs opts mp (BindingGroupDeclaration vals) e = do
  jss <- for vals $ \(Tuple3 ident _ val) -> do
    js <- valueToJs opts mp e val
    return $ JSVariableIntroduction (identToJs ident) (Just js)
  return $ Just jss
declToJs _ mp (DataDeclaration _ _ ctors) _ = do
  return $ Just $ flip concatMap ctors $ \(Tuple pn@(ProperName ctor) tys) ->
    [JSVariableIntroduction ctor (Just (go pn 0 tys []))]
    where
    go :: ProperName -> Number -> [Type] -> [JS] -> JS
    go pn _ [] values =
      JSObjectLiteral [ Tuple "ctor" (JSStringLiteral $ show $ Qualified (Just mp) pn)
                      , Tuple "values" (JSArrayLiteral $ reverse values) ]
    go pn index (_ : tys') values =
      JSFunction Nothing ["value" ++ show index]
        (JSBlock [JSReturn (go pn (index + 1) tys' (JSVar ("value" ++ show index) : values))])
declToJs opts mp (DataBindingGroupDeclaration ds) e = do
  jss <- traverse (\decl -> declToJs opts mp decl e) ds
  return $ Just $ concat $ catMaybes jss
declToJs _ _ (ExternDeclaration _ _ (Just js) _) _ = return $ Just [js]
declToJs opts mp (PositionedDeclaration _ d) e = declToJs opts mp d e
declToJs _ _ _ _ = return Nothing

-- |
-- Generate key//value pairs for an object literal exporting values from a module.
--
exportToJs :: DeclarationRef -> [Tuple String JS]
exportToJs (TypeRef _ (Just dctors)) = map (\(ProperName n) -> Tuple n (var (Ident n))) dctors
exportToJs (ValueRef name) = [Tuple (runIdent name) (var name)]
exportToJs (TypeInstanceRef name) = [Tuple (runIdent name) (var name)]
exportToJs _ = []

-- |
-- Generate code in the simplified Javascript intermediate representation for a variable based on a
-- PureScript identifier.
--
var :: Ident -> JS
var = JSVar <<< identToJs

-- |
-- Generate code in the simplified Javascript intermediate representation for an accessor based on
-- a PureScript identifier. If the name is not valid in Javascript (symbol based, reserved name) an
-- indexer is returned.
--
accessor :: Ident -> JS -> JS
accessor (Ident prop) = accessorString prop
accessor (Op op) = JSIndexer (JSStringLiteral op)

accessorString :: String -> JS -> JS
accessorString prop | isIdent prop = JSAccessor prop
accessorString prop                = JSIndexer (JSStringLiteral prop)

-- |
-- Generate code in the simplified Javascript intermediate representation for a value or expression.
--
valueToJs :: forall m. (Monad m) => Options -> ModuleName -> Environment -> Value -> SupplyT m JS
valueToJs _ _ _ (NumericLiteral n) = return $ JSNumericLiteral n
valueToJs _ _ _ (StringLiteral s) = return $ JSStringLiteral s
valueToJs _ _ _ (BooleanLiteral b) = return $ JSBooleanLiteral b
valueToJs opts m e (ArrayLiteral xs) = JSArrayLiteral <$> traverse (valueToJs opts m e) xs
valueToJs opts m e (ObjectLiteral ps) = JSObjectLiteral <$> traverse (sndM (valueToJs opts m e)) ps
valueToJs opts m e (ObjectUpdate o ps) = do
  obj <- valueToJs opts m e o
  sts <- traverse (sndM (valueToJs opts m e)) ps
  extendObj obj sts
valueToJs _ m _ (Constructor name) = return $ qualifiedToJS m (Ident <<< runProperName) name
valueToJs opts m e (Case values binders) = do
  vals <- traverse (valueToJs opts m e) values
  bindersToJs opts m e binders vals
valueToJs opts m e (IfThenElse cond th el) = JSConditional <$> valueToJs opts m e cond <*> valueToJs opts m e th <*> valueToJs opts m e el
valueToJs opts m e (Accessor prop val) = accessorString prop <$> valueToJs opts m e val
valueToJs opts m e (App val arg) = JSApp <$> valueToJs opts m e val <*> (return <$> valueToJs opts m e arg)
valueToJs opts m e (Let ds val) = do
  decls <- concat <<< catMaybes <$> traverse (flip (declToJs opts m) e) ds
  ret <- valueToJs opts m e val
  return $ JSApp (JSFunction Nothing [] (JSBlock (decls ++ [JSReturn ret]))) []
valueToJs opts m e (Abs (Left arg) val) = do
  ret <- valueToJs opts m e val
  return $ JSFunction Nothing [identToJs arg] (JSBlock [JSReturn ret])
valueToJs opts@(Options o) m e (TypedValue _ (Abs (Left arg) val) ty) | o.performRuntimeTypeChecks = do
  let arg' = identToJs arg
  ret <- valueToJs opts m e val
  return $ JSFunction Nothing [arg'] (JSBlock $ runtimeTypeChecks arg' ty ++ [JSReturn ret])
valueToJs _ m _ (Var ident) = return $ varToJs m ident
valueToJs opts m e (TypedValue _ val _) = valueToJs opts m e val
valueToJs opts m e (PositionedValue _ val) = valueToJs opts m e val
valueToJs _ _ _ (TypeClassDictionary _ _ _) = theImpossibleHappened "Type class dictionary was not replaced"
valueToJs _ _ _ _ = theImpossibleHappened "Invalid argument to valueToJs"

-- |
-- Shallow copy an object.
--
extendObj :: forall m. (Monad m) => JS -> [Tuple String JS] -> SupplyT m JS
extendObj obj sts = do
  newObj <- freshName
  key <- freshName
  let
    jsKey = JSVar key
    jsNewObj = JSVar newObj
    block = JSBlock (objAssign:copy:extend ++ [JSReturn jsNewObj])
    objAssign = JSVariableIntroduction newObj (Just $ JSObjectLiteral [])
    copy = JSForIn key obj $ JSBlock [JSIfElse cond assign Nothing]
    cond = JSApp (JSAccessor "hasOwnProperty" obj) [jsKey]
    assign = JSBlock [JSAssignment (JSIndexer jsKey jsNewObj) (JSIndexer jsKey obj)]
    stToAssign (Tuple s js) = JSAssignment (JSAccessor s jsNewObj) js
    extend = map stToAssign sts
  return $ JSApp (JSFunction Nothing [] block) []

-- |
-- Generate code in the simplified Javascript intermediate representation for runtime type checks.
--
runtimeTypeChecks :: String -> Type -> [JS]
runtimeTypeChecks arg ty =
  let
    argTy = getFunctionArgumentType ty
  in
    maybe [] (argumentCheck (JSVar arg)) argTy
  where
  getFunctionArgumentType :: Type -> Maybe Type
  getFunctionArgumentType (TypeApp (TypeApp t funArg) _) | t == tyFunction = Just funArg
  getFunctionArgumentType (ForAll _ ty' _) = getFunctionArgumentType ty'
  getFunctionArgumentType _ = Nothing
  argumentCheck :: JS -> Type -> [JS]
  argumentCheck val t | t == tyNumber = [typeCheck val "number"]
  argumentCheck val t | t == tyString = [typeCheck val "string"]
  argumentCheck val t | t == tyBoolean = [typeCheck val "boolean"]
  argumentCheck val (TypeApp t _) | t == tyArray = [arrayCheck val]
  argumentCheck val (TypeApp t row) | t == tyObject =
    case rowToList row of
      Tuple pairs _ -> typeCheck val "object" : concatMap (\(Tuple prop ty') -> argumentCheck (accessorString prop val) ty') pairs
  argumentCheck val (TypeApp (TypeApp t _) _) | t == tyFunction = [typeCheck val "function"]
  argumentCheck val (ForAll _ ty' _) = argumentCheck val ty'
  argumentCheck _ _ = []
  typeCheck :: JS -> String -> JS
  typeCheck js ty' = JSIfElse (JSBinary NotEqualTo (JSTypeOf js) (JSStringLiteral ty')) (JSBlock [JSThrow (JSStringLiteral $ ty' ++ " expected")]) Nothing
  arrayCheck :: JS -> JS
  arrayCheck js = JSIfElse (JSUnary Not (JSApp (JSAccessor "isArray" (JSVar "Array")) [js])) (JSBlock [JSThrow (JSStringLiteral "Array expected")]) Nothing

-- |
-- Generate code in the simplified Javascript intermediate representation for a reference to a
-- variable.
--
varToJs :: ModuleName -> Qualified Ident -> JS
varToJs _ (Qualified Nothing ident) = var ident
varToJs m qual = qualifiedToJS m id qual

-- |
-- Generate code in the simplified Javascript intermediate representation for a reference to a
-- variable that may have a qualified name.
--
qualifiedToJS :: forall a. ModuleName -> (a -> Ident) -> Qualified a -> JS
qualifiedToJS m f (Qualified (Just m') a) | m /= m' = accessor (f a) (JSVar (moduleNameToJs m'))
qualifiedToJS _ f (Qualified _ a) = JSVar $ identToJs (f a)

-- |
-- Generate code in the simplified Javascript intermediate representation for pattern match binders
-- and guards.
--
bindersToJs :: forall m. (Monad m) => Options -> ModuleName -> Environment -> [CaseAlternative] -> [JS] -> SupplyT m JS
bindersToJs opts m e binders vals = do
  valNames <- replicateM (length vals) freshName
  let assignments = zipWith JSVariableIntroduction valNames (map Just vals)
  jss <- for binders $ \(CaseAlternative { binders = bs, guard = grd, result = result }) -> do
    ret <- valueToJs opts m e result
    go valNames [JSReturn ret] bs grd
  return $ JSApp (JSFunction Nothing [] (JSBlock (assignments ++ concat jss ++ [JSThrow (JSStringLiteral "Failed pattern match")])))
                 []
  where
    go :: forall m. (Monad m) => [String] -> [JS] -> [Binder] -> Maybe Guard -> SupplyT m [JS]
    go _ done [] Nothing = return done
    go _ done [] (Just cond) = do
      cond' <- valueToJs opts m e cond
      return [JSIfElse cond' (JSBlock done) Nothing]
    go (v:vs) done' (b:bs) grd = do
      done'' <- go vs done' bs grd
      binderToJs m e v done'' b
    go _ _ _ _ = theImpossibleHappened "Invalid arguments to bindersToJs"

-- |
-- Generate code in the simplified Javascript intermediate representation for a pattern match
-- binder.
--
binderToJs :: forall m. (Monad m) => ModuleName -> Environment -> String -> [JS] -> Binder -> SupplyT m [JS]
binderToJs _ _ _ done NullBinder = return done
binderToJs _ _ varName done (StringBinder str) =
  return [JSIfElse (JSBinary EqualTo (JSVar varName) (JSStringLiteral str)) (JSBlock done) Nothing]
binderToJs _ _ varName done (NumberBinder num) =
  return [JSIfElse (JSBinary EqualTo (JSVar varName) (JSNumericLiteral num)) (JSBlock done) Nothing]
binderToJs _ _ varName done (BooleanBinder true) =
  return [JSIfElse (JSVar varName) (JSBlock done) Nothing]
binderToJs _ _ varName done (BooleanBinder false) =
  return [JSIfElse (JSUnary Not (JSVar varName)) (JSBlock done) Nothing]
binderToJs _ _ varName done (VarBinder ident) =
  return (JSVariableIntroduction (identToJs ident) (Just (JSVar varName)) : done)
binderToJs m e varName done (ConstructorBinder ctor bs) = do
  js <- go 0 done bs
  return
    if isOnlyConstructor e ctor
    then js
    else [ JSIfElse (JSBinary EqualTo (JSAccessor "ctor" (JSVar varName))
                                      (JSStringLiteral (show ctor)))
                    (JSBlock js)
                    Nothing
         ]
  where
  go :: forall m. (Monad m) => Number -> [JS] -> [Binder] -> SupplyT m [JS]
  go _ done' [] = return done'
  go index done' (binder:bs') = do
    argVar <- freshName
    done'' <- go (index + 1) done' bs'
    js <- binderToJs m e argVar done'' binder
    return (JSVariableIntroduction argVar (Just (JSIndexer (JSNumericLiteral index) (JSAccessor "values" (JSVar varName)))) : js)
binderToJs m e varName done (ObjectBinder bs) = go done bs
  where
  go :: forall m. (Monad m) => [JS] -> [Tuple String Binder] -> SupplyT m [JS]
  go done' [] = return done'
  go done' ((Tuple prop binder):bs') = do
    propVar <- freshName
    done'' <- go done' bs'
    js <- binderToJs m e propVar done'' binder
    return (JSVariableIntroduction propVar (Just (accessorString prop (JSVar varName))) : js)
binderToJs m e varName done (ArrayBinder bs) = do
  js <- go done 0 bs
  return [JSIfElse (JSBinary EqualTo (JSAccessor "length" (JSVar varName)) (JSNumericLiteral (length bs))) (JSBlock js) Nothing]
  where
  go :: forall m. (Monad m) => [JS] -> Number -> [Binder] -> SupplyT m [JS]
  go done' _ [] = return done'
  go done' index (binder:bs') = do
    elVar <- freshName
    done'' <- go done' (index + 1) bs'
    js <- binderToJs m e elVar done'' binder
    return (JSVariableIntroduction elVar (Just (JSIndexer (JSNumericLiteral index) (JSVar varName))) : js)
binderToJs m e varName done (ConsBinder headBinder tailBinder) = do
  headVar <- freshName
  tailVar <- freshName
  js1 <- binderToJs m e headVar done headBinder
  js2 <- binderToJs m e tailVar js1 tailBinder
  return [JSIfElse (JSBinary GreaterThan (JSAccessor "length" (JSVar varName)) (JSNumericLiteral 0)) (JSBlock
    ( JSVariableIntroduction headVar (Just (JSIndexer (JSNumericLiteral 0) (JSVar varName))) :
      JSVariableIntroduction tailVar (Just (JSApp (JSAccessor "slice" (JSVar varName)) [JSNumericLiteral 1])) :
      js2
    )) Nothing]
binderToJs m e varName done (NamedBinder ident binder) = do
  js <- binderToJs m e varName done binder
  return (JSVariableIntroduction (identToJs ident) (Just (JSVar varName)) : js)
binderToJs m e varName done (PositionedBinder _ binder) =
  binderToJs m e varName done binder

-- |
-- Checks whether a data constructor is the only constructor for that type, used to simplify the
-- check when generating code for binders.
--
isOnlyConstructor :: Environment -> Qualified ProperName -> Boolean
isOnlyConstructor (Environment e) ctor =
  let ty = assertDataConstructorExists $ ctor `M.lookup` e.dataConstructors
  in numConstructors (Tuple ctor ty) == 1
  where
  assertDataConstructorExists (Just dc) = dc
  assertDataConstructorExists Nothing = theImpossibleHappened "Data constructor not found"
  numConstructors ty = length $ filter (((==) `on` typeConstructor) ty) $ M.toList $ e.dataConstructors
  typeConstructor (Tuple (Qualified (Just moduleName) _) (Tuple tyCtor _)) = Tuple moduleName tyCtor
  typeConstructor _ = theImpossibleHappened "Invalid argument to isOnlyConstructor"
