{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
module Stack.Setup.Installed
    ( getCompilerVersion
    , markInstalled
    , unmarkInstalled
    , listInstalled
    , Tool (..)
    , toolString
    , toolNameString
    , parseToolText
    , ExtraDirs (..)
    , extraDirs
    , installDir
    ) where

import           Control.Applicative
import           Control.Monad.Catch
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Logger
import           Control.Monad.Reader (MonadReader, asks)
import           Control.Monad.Trans.Control
import qualified Data.ByteString.Char8 as S8
import           Data.List hiding (concat, elem, maximumBy)
import           Data.Maybe
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text as T
import           Distribution.System (Platform (..))
import qualified Distribution.System as Cabal
import           Path
import           Path.IO
import           Prelude hiding (concat, elem) -- Fix AMP warning
import           Stack.Types
import qualified System.FilePath as FP
import           System.Process.Read

data Tool
    = Tool PackageIdentifier -- ^ e.g. ghc-7.8.4, msys2-20150512
    | ToolGhcjs CompilerVersion -- ^ e.g. ghcjs-0.1.0_ghc-7.10.2

toolString :: Tool -> String
toolString (Tool ident) = packageIdentifierString ident
toolString (ToolGhcjs cv) = compilerVersionString cv

toolNameString :: Tool -> String
toolNameString (Tool ident) = packageNameString $ packageIdentifierName ident
toolNameString ToolGhcjs{} = "ghcjs"

parseToolText :: Text -> Maybe Tool
parseToolText (parseCompilerVersion -> Just (cv@GhcjsVersion{})) = Just (ToolGhcjs cv)
parseToolText (parsePackageIdentifierFromString . T.unpack -> Just pkgId) = Just (Tool pkgId)
parseToolText _ = Nothing

markInstalled :: (MonadIO m, MonadReader env m, HasConfig env, MonadThrow m)
              => Tool
              -> m ()
markInstalled tool = do
    dir <- asks $ configLocalPrograms . getConfig
    fpRel <- parseRelFile $ toolString tool ++ ".installed"
    liftIO $ writeFile (toFilePath $ dir </> fpRel) "installed"

unmarkInstalled :: (MonadIO m, MonadReader env m, HasConfig env, MonadThrow m)
                => Tool
                -> m ()
unmarkInstalled tool = do
    dir <- asks $ configLocalPrograms . getConfig
    fpRel <- parseRelFile $ toolString tool ++ ".installed"
    removeFileIfExists $ dir </> fpRel

listInstalled :: (MonadIO m, MonadReader env m, HasConfig env, MonadThrow m)
              => m [Tool]
listInstalled = do
    dir <- asks $ configLocalPrograms . getConfig
    createTree dir
    (_, files) <- listDirectory dir
    return $ mapMaybe toTool files
  where
    toTool fp = do
        x <- T.stripSuffix ".installed" $ T.pack $ toFilePath $ filename fp
        parseToolText x

getCompilerVersion :: (MonadLogger m, MonadCatch m, MonadBaseControl IO m, MonadIO m)
              => EnvOverride -> WhichCompiler -> m CompilerVersion
getCompilerVersion menv wc =
    case wc of
        Ghc -> do
            bs <- readProcessStdout Nothing menv "ghc" ["--numeric-version"]
            let (_, ghcVersion) = versionFromEnd bs
            GhcVersion <$> parseVersion ghcVersion
        Ghcjs -> do
            -- Output looks like
            --
            -- The Glorious Glasgow Haskell Compilation System for JavaScript, version 0.1.0 (GHC 7.10.2)
            bs <- readProcessStdout Nothing menv "ghcjs" ["--version"]
            let (rest, ghcVersion) = versionFromEnd bs
                (_, ghcjsVersion) = versionFromEnd rest
            GhcjsVersion <$> parseVersion ghcjsVersion <*> parseVersion ghcVersion
  where
    versionFromEnd = S8.spanEnd isValid . fst . S8.breakEnd isValid
    isValid c = c == '.' || ('0' <= c && c <= '9')

-- | Binary directories for the given installed package
extraDirs :: (MonadReader env m, HasConfig env, MonadThrow m, MonadLogger m)
          => Tool
          -> m ExtraDirs
extraDirs tool = do
    platform <- asks getPlatform
    dir <- installDir tool
    case (platform, toolNameString tool) of
        (Platform _ Cabal.Windows, isGHC -> True) -> return mempty
            { edBins = goList
                [ dir </> $(mkRelDir "bin")
                , dir </> $(mkRelDir "mingw") </> $(mkRelDir "bin")
                ]
            }
        (Platform _ Cabal.Windows, "msys2") -> return mempty
            { edBins = goList
                [ dir </> $(mkRelDir "usr") </> $(mkRelDir "bin")
                ]
            , edInclude = goList
                [ dir </> $(mkRelDir "mingw64") </> $(mkRelDir "include")
                , dir </> $(mkRelDir "mingw32") </> $(mkRelDir "include")
                ]
            , edLib = goList
                [ dir </> $(mkRelDir "mingw64") </> $(mkRelDir "lib")
                , dir </> $(mkRelDir "mingw32") </> $(mkRelDir "lib")
                ]
            }
        (_, isGHC -> True) -> return mempty
            { edBins = goList
                [ dir </> $(mkRelDir "bin")
                ]
            }
        (_, isGHCJS -> True) -> return mempty
            { edBins = goList
                [ dir </> $(mkRelDir "bin")
                ]
            }
        (Platform _ x, toolName) -> do
            $logWarn $ "binDirs: unexpected OS/tool combo: " <> T.pack (show (x, toolName))
            return mempty
  where
    goList = map toFilePathNoTrailingSlash
    isGHC n = "ghc" == n || "ghc-" `isPrefixOf` n
    isGHCJS n = "ghcjs" == n

data ExtraDirs = ExtraDirs
    { edBins :: ![FilePath]
    , edInclude :: ![FilePath]
    , edLib :: ![FilePath]
    }
instance Monoid ExtraDirs where
    mempty = ExtraDirs [] [] []
    mappend (ExtraDirs a b c) (ExtraDirs x y z) = ExtraDirs
        (a ++ x)
        (b ++ y)
        (c ++ z)

installDir :: (MonadReader env m, HasConfig env, MonadThrow m, MonadLogger m)
           => Tool
           -> m (Path Abs Dir)
installDir tool = do
    config <- asks getConfig
    reldir <- parseRelDir $ toolString tool
    return $ configLocalPrograms config </> reldir

toFilePathNoTrailingSlash :: Path loc Dir -> FilePath
toFilePathNoTrailingSlash = FP.dropTrailingPathSeparator . toFilePath