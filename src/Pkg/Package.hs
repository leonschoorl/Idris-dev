{-# LANGUAGE CPP #-}
module Pkg.Package where

import System.Process
import System.Directory
import System.Exit
import System.IO
import System.FilePath ((</>), addTrailingPathSeparator, takeFileName,
                        takeDirectory, normalise, addExtension, hasExtension)
import System.Directory (createDirectoryIfMissing, copyFile)

import Util.System

import Control.Monad
import Control.Monad.Trans.State.Strict (execStateT)
import Control.Monad.Trans.Except (runExceptT)

import Data.List
import Data.List.Split(splitOn)
import Data.Maybe(fromMaybe)
import Data.Either(partitionEithers)

import Idris.Core.TT
import Idris.REPL
import Idris.Parser (loadModule)
import Idris.Output (pshow)
import Idris.AbsSyntax
import Idris.IdrisDoc
import Idris.IBC
import Idris.Output
import Idris.Imports
import Idris.Error (ifail)

import Pkg.PParser

import IRTS.System

-- To build a package:
-- * read the package description
-- * check all the library dependencies exist
-- * invoke the makefile if there is one
-- * invoke idris on each module, with idris_opts
-- * install everything into datadir/pname, if install flag is set

--  --------------------------------------------------------- [ Build Packages ]

-- | Run the package through the idris compiler.
buildPkg :: [Opt]            -- ^ Command line options
         -> Bool             -- ^ Provide Warnings
         -> (Bool, FilePath) -- ^ (Should we install, Location of iPKG file)
         -> IO ()
buildPkg copts warnonly (install, fp) = do
  pkgdesc <- parseDesc fp
  dir <- getCurrentDirectory
  let idx = PkgIndex (pkgIndex (pkgname pkgdesc))
  oks <- mapM (testLib warnonly (pkgname pkgdesc)) (libdeps pkgdesc)
  when (and oks) $ do
    m_ist <- inPkgDir pkgdesc $ do

      make (makefile pkgdesc)
      case (execout pkgdesc) of
        Nothing -> do
          case mergeOptions copts (idx : NoREPL : Verbose : idris_opts pkgdesc) of
            Left emsg -> do
              putStrLn emsg
              exitWith (ExitFailure 1)
            Right opts -> buildMods opts (modules pkgdesc)
        Just o -> do
          let exec = dir </> o
          case mergeOptions copts (idx : NoREPL : Verbose : Output exec : idris_opts pkgdesc) of
            Left emsg -> do
              putStrLn emsg
              exitWith (ExitFailure 1)
            Right opts -> buildMods opts [idris_main pkgdesc]
    case m_ist of
      Nothing  -> exitWith (ExitFailure 1)
      Just ist -> do
        -- Quit with error code if there was a problem
        case errSpan ist of
          Just _ -> exitWith (ExitFailure 1)
          _      -> return ()
        when install $ installPkg (opt getIBCSubDir copts) pkgdesc

--  --------------------------------------------------------- [ Check Packages ]

-- | Type check packages only
--
-- This differs from build in that executables are not built, if the
-- package contains an executable.
checkPkg :: [Opt]     -- ^ Command line Options
         -> Bool      -- ^ Show Warnings
         -> Bool      -- ^ quit on failure
         -> FilePath  -- ^ Path to ipkg file.
         -> IO ()
checkPkg copts warnonly quit fpath = do
  pkgdesc <- parseDesc fpath
  oks <- mapM (testLib warnonly (pkgname pkgdesc)) (libdeps pkgdesc)
  when (and oks) $ do
    res <- inPkgDir pkgdesc $ do
      make (makefile pkgdesc)

      case mergeOptions copts (NoREPL : Verbose : idris_opts pkgdesc) of
        Left emsg -> do
          putStrLn emsg
          exitWith (ExitFailure 1)
        Right opts -> do
          buildMods opts (modules pkgdesc)
    when quit $ case res of
                  Nothing -> exitWith (ExitFailure 1)
                  Just res' -> do
                    case errSpan res' of
                      Just _ -> exitWith (ExitFailure 1)
                      _      -> return ()

--  ------------------------------------------------------------------- [ REPL ]

-- | Check a package and start a REPL.
--
-- This function only works with packages that have a main module.
--
replPkg :: [Opt]    -- ^ Command line Options
        -> FilePath -- ^ Path to ipkg file.
        -> Idris ()
replPkg copts fp = do
    orig <- getIState
    runIO $ checkPkg copts False False fp
    pkgdesc <- runIO $ parseDesc fp -- bzzt, repetition!

    case mergeOptions copts (idris_opts pkgdesc) of
      Left emsg  -> ifail emsg
      Right opts -> do
        let mod = idris_main pkgdesc
        let f = toPath (showCG mod)
        putIState orig
        dir <- runIO $ getCurrentDirectory
        runIO $ setCurrentDirectory $ dir </> sourcedir pkgdesc

        if (f /= "")
          then idrisMain ((Filename f) : opts)
          else iputStrLn "Can't start REPL: no main module given"
        runIO $ setCurrentDirectory dir

  where
    toPath n = foldl1' (</>) $ splitOn "." n

--  --------------------------------------------------------------- [ Cleaning ]

-- | Clean Package build files
cleanPkg :: [Opt]    -- ^ Command line options.
         -> FilePath -- ^ Path to ipkg file.
         -> IO ()
cleanPkg copts fp = do
  pkgdesc <- parseDesc fp
  dir <- getCurrentDirectory
  inPkgDir pkgdesc $ do
    clean (makefile pkgdesc)
    mapM_ rmIBC (modules pkgdesc)
    rmIdx (pkgname pkgdesc)
    case execout pkgdesc of
      Nothing -> return ()
      Just s -> rmExe $ dir </> s

--  ------------------------------------------------------ [ Generate IdrisDoc ]


-- | Generate IdrisDoc for package
-- TODO: Handle case where module does not contain a matching namespace
--       E.g. from prelude.ipkg: IO, Prelude.Chars, Builtins
--
-- Issue number #1572 on the issue tracker
--       https://github.com/idris-lang/Idris-dev/issues/1572
documentPkg :: [Opt]    -- ^ Command line options.
            -> FilePath -- ^ Path to ipkg file.
            -> IO ()
documentPkg copts fp = do
  pkgdesc        <- parseDesc fp
  cd             <- getCurrentDirectory
  let pkgDir      = cd </> takeDirectory fp
      outputDir   = cd </> pkgname pkgdesc ++ "_doc"
      popts       = NoREPL : Verbose : idris_opts pkgdesc
      mods        = modules pkgdesc
      fs          = map (foldl1' (</>) . splitOn "." . showCG) mods
  setCurrentDirectory $ pkgDir </> sourcedir pkgdesc
  make (makefile pkgdesc)
  setCurrentDirectory pkgDir
  case mergeOptions copts popts of
    Left emsg -> do
      putStrLn emsg
      exitWith (ExitFailure 1)
    Right opts -> do
      let run l       = runExceptT . execStateT l
          load []     = return ()
          load (f:fs) = do loadModule f IBC_Building; load fs
          loader      = do
            idrisMain opts
            addImportDir (sourcedir pkgdesc)
            load fs
      idrisInstance  <- run loader idrisInit
      setCurrentDirectory cd
      case idrisInstance of
        Left  err -> do
          putStrLn $ pshow idrisInit err
          exitWith (ExitFailure 1)
        Right ist -> do
          docRes <- generateDocs ist mods outputDir
          case docRes of
            Right _  -> return ()
            Left msg -> do
              putStrLn msg
              exitWith (ExitFailure 1)

--  ------------------------------------------------------------------- [ Test ]

-- | Build a package with a sythesized main function that runs the tests
testPkg :: [Opt]     -- ^ Command line options.
        -> FilePath  -- ^ Path to ipkg file.
        -> IO ()
testPkg copts fp = do
  pkgdesc <- parseDesc fp
  ok <- mapM (testLib True (pkgname pkgdesc)) (libdeps pkgdesc)
  when (and ok) $ do
    m_ist <- inPkgDir pkgdesc $ do
      make (makefile pkgdesc)
      -- Get a temporary file to save the tests' source in
      (tmpn, tmph) <- tempfile ".idr"
      hPutStrLn tmph $
          "module Test_______\n" ++
          concat ["import " ++ show m ++ "\n" | m <- modules pkgdesc]
              ++ "namespace Main\n"
              ++ "  main : IO ()\n"
              ++ "  main = do "
              ++ concat [ show t ++ "\n            "
                        | t <- idris_tests pkgdesc]
      hClose tmph
      (tmpn', tmph') <- tempfile ""
      hClose tmph'
      let popts = (Filename tmpn : NoREPL : Verbose : Output tmpn' : idris_opts pkgdesc)
      case mergeOptions copts popts of
        Left emsg -> do
          putStrLn emsg
          exitWith (ExitFailure 1)
        Right opts -> do
          m_ist <- idris opts
          rawSystem tmpn' []
          return m_ist
    case m_ist of
      Nothing  -> exitWith (ExitFailure 1)
      Just ist -> do
        -- Quit with error code if problem building
        case errSpan ist of
          Just _ -> exitWith (ExitFailure 1)
          _      -> return ()

--  ----------------------------------------------------------- [ Installation ]

-- | Install package
installPkg :: [String]  -- ^ Alternate install location
           -> PkgDesc   -- ^ iPKG file.
           -> IO ()
installPkg altdests pkgdesc = inPkgDir pkgdesc $ do
  d <- getTargetDir
  let destdir = case altdests of
                  []     -> d
                  (d':_) -> d'
  case (execout pkgdesc) of
    Nothing -> do
      mapM_ (installIBC destdir (pkgname pkgdesc)) (modules pkgdesc)
      installIdx destdir (pkgname pkgdesc)
    Just o -> return () -- do nothing, keep executable locally, for noe

  mapM_ (installObj destdir (pkgname pkgdesc)) (objs pkgdesc)

-- ---------------------------------------------------------- [ Helper Methods ]
-- Methods for building, testing, installing, and removal of idris
-- packages.

buildMods :: [Opt] -> [Name] -> IO (Maybe IState)
buildMods opts ns = do let f = map (toPath . showCG) ns
                       idris (map Filename f ++ opts)
    where toPath n = foldl1' (</>) $ splitOn "." n

testLib :: Bool -> String -> String -> IO Bool
testLib warn p f
    = do d <- getDataDir
         gcc <- getCC
         (tmpf, tmph) <- tempfile ""
         hClose tmph
         let libtest = d </> "rts" </> "libtest.c"
         e <- rawSystem gcc [libtest, "-l" ++ f, "-o", tmpf]
         case e of
            ExitSuccess -> return True
            _ -> do if warn
                       then do putStrLn $ "Not building " ++ p ++
                                          " due to missing library " ++ f
                               return False
                       else fail $ "Missing library " ++ f

rmIBC :: Name -> IO ()
rmIBC m = rmFile $ toIBCFile m

rmIdx :: String -> IO ()
rmIdx p = do let f = pkgIndex p
             ex <- doesFileExist f
             when ex $ rmFile f

rmExe :: String -> IO ()
rmExe p = do
            fn <- return $ if isWindows && not (hasExtension p)
                                then addExtension p ".exe" else p
            rmFile fn

toIBCFile (UN n) = str n ++ ".ibc"
toIBCFile (NS n ns) = foldl1' (</>) (reverse (toIBCFile n : map str ns))

installIBC :: String -> String -> Name -> IO ()
installIBC dest p m = do
    let f = toIBCFile m
    let destdir = dest </> p </> getDest m
    putStrLn $ "Installing " ++ f ++ " to " ++ destdir
    createDirectoryIfMissing True destdir
    copyFile f (destdir </> takeFileName f)
    return ()
  where
    getDest (UN n) = ""
    getDest (NS n ns) = foldl1' (</>) (reverse (getDest n : map str ns))

installIdx :: String -> String -> IO ()
installIdx dest p = do
  let f = pkgIndex p
  let destdir = dest </> p
  putStrLn $ "Installing " ++ f ++ " to " ++ destdir
  createDirectoryIfMissing True destdir
  copyFile f (destdir </> takeFileName f)
  return ()

installObj :: String -> String -> String -> IO ()
installObj dest p o = do
  let destdir = addTrailingPathSeparator (dest </> p)
  putStrLn $ "Installing " ++ o ++ " to " ++ destdir
  createDirectoryIfMissing True destdir
  copyFile o (destdir </> takeFileName o)
  return ()

#ifdef mingw32_HOST_OS
mkDirCmd = "mkdir "
#else
mkDirCmd = "mkdir -p "
#endif

inPkgDir :: PkgDesc -> IO a -> IO a
inPkgDir pkgdesc action =
  do dir <- getCurrentDirectory
     when (sourcedir pkgdesc /= "") $
       do putStrLn $ "Entering directory `" ++ ("." </> sourcedir pkgdesc) ++ "'"
          setCurrentDirectory $ dir </> sourcedir pkgdesc
     res <- action
     when (sourcedir pkgdesc /= "") $
       do putStrLn $ "Leaving directory `" ++ ("." </> sourcedir pkgdesc) ++ "'"
          setCurrentDirectory dir
     return res

-- ------------------------------------------------------- [ Makefile Commands ]
-- | Invoke a Makefile's default target.
make :: Maybe String -> IO ()
make Nothing = return ()
make (Just s) = do rawSystem "make" ["-f", s]
                   return ()

-- | Invoke a Makefile's clean target.
clean :: Maybe String -> IO ()
clean Nothing = return ()
clean (Just s) = do rawSystem "make" ["-f", s, "clean"]
                    return ()

-- | Merge an option list representing the command line options into
-- those specified for a package description.
--
-- This is not a complete union between the two options sets. First,
-- to prevent important package specified options from being
-- overwritten. Second, the semantics for this merge are not fully
-- defined.
--
-- A discussion for this is on the issue tracker:
--     https://github.com/idris-lang/Idris-dev/issues/1448
--
mergeOptions :: [Opt] -- ^ The command line options
             -> [Opt] -- ^ The package options
             -> Either String [Opt]
mergeOptions copts popts =
    case partitionEithers (map chkOpt (normaliseOpts copts)) of
      ([], copts') -> Right $ copts' ++ popts
      (es, _)      -> Left  $ genErrMsg es
  where
    normaliseOpts :: [Opt] -> [Opt]
    normaliseOpts = filter filtOpt

    filtOpt :: Opt -> Bool
    filtOpt (PkgBuild   _) = False
    filtOpt (PkgInstall _) = False
    filtOpt (PkgClean   _) = False
    filtOpt (PkgCheck   _) = False
    filtOpt (PkgREPL    _) = False
    filtOpt (PkgMkDoc   _) = False
    filtOpt (PkgTest    _) = False
    filtOpt _              = True

    chkOpt :: Opt -> Either String Opt
    chkOpt o@(OLogging _)     = Right o
    chkOpt o@(OLogCats _)     = Right o
    chkOpt o@(DefaultTotal)   = Right o
    chkOpt o@(DefaultPartial) = Right o
    chkOpt o@(WarnPartial)    = Right o
    chkOpt o@(WarnReach)      = Right o
    chkOpt o@(IBCSubDir _)    = Right o
    chkOpt o@(ImportDir _ )   = Right o
    chkOpt o@(UseCodegen _)   = Right o
    chkOpt o                  = Left (unwords ["\t", show o, "\n"])

    genErrMsg :: [String] -> String
    genErrMsg es = unlines
        [ "Not all command line options can be used to override package options."
        , "\nThe only changeable options are:"
        , "\t--log <lvl>, --total, --warnpartial, --warnreach"
        , "\t--ibcsubdir <path>, -i --idrispath <path>"
        , "\t--logging-categories <cats>"
        , "\nThe options need removing are:"
        , unlines es
        ]

-- --------------------------------------------------------------------- [ EOF ]
