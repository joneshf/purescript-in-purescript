module Interactive where

import Data.Tuple
import Data.Maybe
import Data.Either
import Data.Array (map)
import Data.Foldable (foldl)
import Data.Traversable (for)
import Data.String (joinWith, indexOf, drop)

import qualified Data.Map as M

import Debug.Trace

import Control.Apply
import Control.Monad
import Control.Monad.Eff
import Control.Monad.Eff.Ref
import Control.Monad.Eff.Process
import Control.Monad.Eff.FS
import Control.Monad.Application
import Control.Monad.Error.Class

import Node.Args
import Node.ReadLine

import Language.PureScript
import Language.PureScript.Names
import Language.PureScript.Options
import Language.PureScript.Prelude
import Language.PureScript.Environment
import Language.PureScript.Pretty.Types (prettyPrintType)
import Language.PureScript.CodeGen.JS (RequirePathType(..))
import qualified Language.PureScript.Declarations as D

import qualified Text.Parsing.Parser as P
import qualified Text.Parsing.Parser.Combinators as P
import qualified Language.PureScript.Parser.Lexer as P
import qualified Language.PureScript.Parser.Common as P
import qualified Language.PureScript.Parser.Declarations as P

-- |
-- Valid Meta-commands for PSCI
--
data Command
  -- |
  -- A purescript expression
  --
  = Eval D.Value
  -- |
  -- Show the help command
  --
  | Help
  -- |
  -- Import a module from a loaded file
  --
  | Import ModuleName
  -- |
  -- Load a file for use with importing
  --
  | LoadFile String
  -- |
  -- Exit PSCI
  --
  | Quit
  -- |
  -- Reset the state of the REPL
  --
  | Reset
  -- |
  -- Binds a value to a name
  --
  | Let (D.Value -> D.Value)
  -- |
  -- Find the type of an expression
  --
  | TypeOf D.Value
  
parse :: forall a. P.Parser P.TokenStream a -> String -> Either String a
parse p s = P.lex s >>= P.runTokenParser (p <* P.eof)

parseLet :: P.Parser P.TokenStream Command
parseLet = Let <$> (D.Let <$> (P.reserved "let" *> P.braces (P.many1 P.parseDeclaration)))
  
parseCommand :: String -> Either String Command
parseCommand ":?" = Right Help
parseCommand ":q" = Right Quit
parseCommand ":r" = Right Reset
parseCommand cmd | indexOf ":i " cmd == 0 = Import <$> parse P.moduleName (drop 3 cmd)
parseCommand cmd | indexOf ":m " cmd == 0 = Right $ LoadFile (drop 3 cmd)
parseCommand cmd | indexOf ":t " cmd == 0 = TypeOf <$> parse (P.parseValue {}) (drop 3 cmd)
parseCommand cmd | indexOf ":" cmd == 0 = Left "Unknown command. Type :? for help."
parseCommand cmd = parse (parseLet <|> (Eval <$> P.parseValue {})) cmd
  
-- |
-- The PSCI state.
-- Holds a list of imported modules, loaded files, and partial let bindings.
-- The let bindings are partial,
-- because it makes more sense to apply the binding to the final evaluated expression.
--
type PSCIState = { loadedModules       :: [String]
                 , importedModuleNames :: [ModuleName]
                 , letBindings         :: [D.Value -> D.Value]
                 }
  
emptyPSCIState :: [String] -> PSCIState
emptyPSCIState files = { loadedModules       : files
                       , importedModuleNames : [ModuleName [ProperName "Prelude"]]
                       , letBindings         : []
                       }
                 
defaultImports :: [ModuleName]
defaultImports = [ModuleName [ProperName "Prelude"]]

-- |
-- The help menu.
--
help :: String
help = 
  "  :?            Show this help menu\n\
  \  :i <module>   Import <module> for use in PSCi\n\
  \  :m <file>     Load <file> for importing\n\
  \  :q            Quit PSCi\n\
  \  :r            Reset\n\
  \  :t <expr>     Show the type of <expr>"
 
moduleFromText :: String -> Either String D.Module
moduleFromText text = do
  tokens <- P.lex text
  P.runTokenParser P.parseModule tokens
  
-- |
-- Load a module from a file
--
loadModule :: forall eff. String -> Eff (fs :: FS | eff) (Either String D.Module)
loadModule filename = readFile filename moduleFromText (Left <<< getStackTrace)

loadModules :: [String] -> Application [Tuple String D.Module]
loadModules input = 
  for input (\inputFile -> do
    text <- readFileApplication inputFile
    case moduleFromText text of
      Left err -> throwError err
      Right m -> return (Tuple inputFile m))

-- |
-- Makes a temporary module for the purposes of executing an expression
--
createTemporaryModule :: Boolean -> PSCIState -> D.Value -> D.Module
createTemporaryModule exec st value =
  let
    moduleName :: ModuleName
    moduleName = ModuleName [ProperName "Main"]
    
    replModule :: ModuleName
    replModule = ModuleName [ProperName "REPL"]
    
    evalPrint :: D.Value
    evalPrint = D.Var (Qualified (Just replModule) (Ident "evalPrint"))
    
    itValue :: D.Value
    itValue = foldl (\x f -> f x) value st.letBindings
    
    mainValue :: D.Value
    mainValue = D.App evalPrint (D.Var (Qualified Nothing (Ident "it")))
    
    importDecl :: ModuleName -> D.Declaration
    importDecl m = D.ImportDeclaration m Nothing Nothing
    
    itDecl :: D.Declaration
    itDecl = D.ValueDeclaration (Ident "it") Value [] Nothing itValue
    
    mainDecl :: D.Declaration
    mainDecl = D.ValueDeclaration (Ident "main") Value [] Nothing mainValue
    
    decls :: [D.Declaration]
    decls = if exec then [itDecl, mainDecl] else [itDecl]
    
    moduleBody :: [D.Declaration]
    moduleBody = map importDecl (replModule : st.importedModuleNames) ++ decls
  in
    D.Module moduleName moduleBody Nothing

-- |
-- Require statements use absolute paths to modules cached in the current directory
--
requireMode :: RequirePathType
requireMode = RequireAbsolute modulePath

modulePath :: String -> String
modulePath mn = modulesDir ++ "/" ++ mn ++ "/index.js"

foreign import homeDirectory
  "var homeDirectory = process.env['HOME'] || process.env['HOMEPATH'] || process.env['USERPROFILE'];" :: String

-- |
-- Directory which holds compiled modules
--
modulesDir :: String
modulesDir = homeDirectory ++ "/.purescript/psci/cache"

-- |
-- The REPL support module
--
replModule :: String
replModule = homeDirectory ++ "/.purescript/psci/modules/REPL.purs"
    
-- | 
-- Compilation options
--
options :: Options
options = mkOptions false true false true Nothing true Nothing [] [] false    
    
-- |
-- Takes a value and prints its type
--
handleTypeOf :: forall eff. PSCIState -> D.Value -> Eff (fs :: FS, trace :: Trace, process :: Process | eff) {}
handleTypeOf st value = do
  let m = createTemporaryModule false st value
  e <- runApplication' do
    ms <- loadModules st.loadedModules
    make requireMode modulesDir options (ms ++ [Tuple "Main.purs" m])
  case e of
    Left err -> trace err
    Right (Environment env') ->
      case M.lookup (Tuple (ModuleName [ProperName "Main"]) (Ident "it")) env'.names of
        Just (Tuple ty _) -> trace $ prettyPrintType ty
        Nothing -> trace "Could not find type"

-- |
-- An effect for the 'eval' function
--
foreign import data Eval :: !

-- |
-- Evaluate some Javascript
--
foreign import evaluate
  "function evaluate(js) {\
  \  return function() {\
  \    eval(js);\
  \  };\
  \}" :: forall eff. String -> Eff (eval :: Eval | eff) {}
        
-- |
-- Takes a value declaration and evaluates it with the current state.
--
handleEval :: forall eff. PSCIState -> D.Value -> Eff (fs :: FS, trace :: Trace, process :: Process, eval :: Eval | eff) {}
handleEval st value = do
  let m = createTemporaryModule true st value
  e <- runApplication' do
    ms <- loadModules st.loadedModules
    make requireMode modulesDir options (ms ++ [Tuple "Main.purs" m])
  case e of
    Left err -> trace err
    Right _ -> evaluate $ "(function() { require('" ++ modulePath "Main" ++ "').main(); })()"

prologueMessage :: String
prologueMessage = 
  " ____                 ____            _       _   \n\
  \|  _ \\ _   _ _ __ ___/ ___|  ___ _ __(_)_ __ | |_ \n\
  \| |_) | | | | '__/ _ \\___ \\ / __| '__| | '_ \\| __|\n\
  \|  __/| |_| | | |  __/___) | (__| |  | | |_) | |_ \n\
  \|_|    \\__,_|_|  \\___|____/ \\___|_|  |_| .__/ \\__|\n\
  \                                       |_|        \n\
  \\n\
  \:? shows help\n\
  \\n\
  \Expressions are terminated using Ctrl+D"
  
completion :: forall eff. RefVal PSCIState -> Completer (ref :: Ref | eff)
completion state s = return $ Tuple [] s

handleCommand :: [String] -> RefVal PSCIState -> Command -> Eff (fs :: FS, trace :: Trace, process :: Process, console :: Console, ref :: Ref, eval :: Eval) {}
handleCommand _ _ Help = trace help
handleCommand _ _ Quit = trace "See ya!" *> exit 0
handleCommand _ state (TypeOf v) = do
  st <- readRef state
  handleTypeOf st v
handleCommand _ state (Eval v) = do
  st <- readRef state
  handleEval st v
handleCommand _ state (LoadFile filename) = do
  modifyRef state (\st -> st { loadedModules = st.loadedModules ++ [filename] })
  -- TODO: parse the module and store it
handleCommand _ state (Import mn) =
  modifyRef state (\st -> st { importedModuleNames = st.importedModuleNames ++ [mn] })
handleCommand initialFiles state Reset = writeRef state (emptyPSCIState initialFiles)
handleCommand _ state (Let f) =
  modifyRef state (\st -> st { letBindings = st.letBindings ++ [f] })

lineHandler :: [String] -> RefVal PSCIState -> String -> Eff (fs :: FS, trace :: Trace, process :: Process, console :: Console, ref :: Ref, eval :: Eval) {}
lineHandler initialFiles state input = 
  case parseCommand input of
    Left msg -> trace msg
    Right cmd -> handleCommand initialFiles state cmd

loop :: [String] -> Eff (fs :: FS, trace :: Trace, process :: Process, console :: Console, ref :: Ref, eval :: Eval) {}
loop inputFiles = do
  let allModules = preludeFiles ++ [replModule] ++ inputFiles
  state <- newRef (emptyPSCIState allModules)
  interface <- createInterface process.stdin process.stdout (completion state)
  setPrompt "> " 2 interface
  prompt interface
  setLineHandler (\s -> lineHandler allModules state s <* prompt interface) interface
  return {}
  
inputFiles :: Args [String]
inputFiles = many argOnly  
  
term :: Args (Eff (fs :: FS, trace :: Trace, process :: Process, console :: Console, ref :: Ref, eval :: Eval) {})
term = loop <$> inputFiles

main = do
  trace prologueMessage
  result <- readArgs' term
  case result of
    Left err -> print err
    _ -> return {}
