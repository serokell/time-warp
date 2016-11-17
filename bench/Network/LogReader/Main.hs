{-# LANGUAGE TypeApplications #-}

import           Control.Applicative          ((<|>))
import           Control.Exception            (Exception)
import           Control.Lens                 (at, singular, (%=), (<<.=), _Just, (^.))
import           Control.Monad                (forM_)
import           Control.Monad.Catch          (handle, throwM)
import           Control.Monad.State          (StateT (..), execStateT)
import           Control.Monad.Trans          (lift)
import           Control.Monad.Trans.Resource (runResourceT)
import           Data.Conduit                 (Source, ($$), (=$=), yield)
import           Data.Conduit.Binary          (sourceFile, sinkFile)
import qualified Data.Conduit.Binary          as CB
import qualified Data.Conduit.List            as CL
import           Data.Conduit.Text            (decode, utf8, encode)
import qualified Data.Map                     as M
import           Data.Text                    (Text)
import           Data.Text.Buildable          (Buildable (..))
import           Data.Typeable                (Typeable)
import           Data.List (intersperse)
import           Formatting                   (sformat, (%), bprint, right, int)
import qualified Formatting                   as F
import           System.IO                    (FilePath)

import           Data.Attoparsec.Text         (parseOnly)

import           Bench.Network.Commons        (LogMessage (..), MeasureEvent (..),
                                               MeasureInfo (..), MsgId, Timestamp,
                                               logMessageParser, measureInfoParser)
import           Control.TimeWarp.Logging     (LoggerNameBox, Severity (Info),
                                               initLogging, logError, logWarning,
                                               usingLoggerName, usingLoggerName)


type Measures = M.Map MsgId (M.Map MeasureEvent Timestamp)

newtype MeasureInfoDuplicateError = MeasureInfoDuplicateError (Timestamp, MeasureInfo)
    deriving (Show, Typeable)

instance Buildable MeasureInfoDuplicateError where
    build (MeasureInfoDuplicateError (was, new)) = mconcat
        ["Duplicate measure: was "
        , build was
        , " but meet "
        , build new
        ]

instance Exception MeasureInfoDuplicateError

analyze :: FilePath -> StateT Measures (LoggerNameBox IO) ()
analyze file = catchE . runResourceT $
    sourceFile file =$= CB.lines =$= decode utf8 $$ CL.mapM_ (lift . saveMeasure)
  where
    saveMeasure :: Text -> StateT Measures (LoggerNameBox IO) ()
    saveMeasure row = do
        case parseOnly (logMessageParser measureInfoParser) row of
            Left err -> logWarning $ sformat ("Some error occured: "%F.build) err
            Right (LogMessage mi@MeasureInfo{..}) -> do
                at miId %= (<|> Just M.empty)
                mwas <- singular (at miId . _Just) . at miEvent <<.= Just miTime
                forM_ mwas $ \was -> throwM $ MeasureInfoDuplicateError (was, mi)

    catchE = handle @_ @MeasureInfoDuplicateError $ logError . sformat F.build


printMeasures :: FilePath -> Measures -> LoggerNameBox IO ()
printMeasures file measures = runResourceT $
    source $$ encode utf8 =$= sinkFile file
  where
    source = printHeader >> mapM_ printMeasure (M.toList measures)

    printRow :: Monad m => [Text] -> Source m Text
    printRow = yield
             . sformat (F.build%"\n")
             . mconcat
             . intersperse ","
             . map (bprint $ right 10 ' ')

    printHeader = printRow $ "MsgId" : map (sformat F.build) eventsUniverse

    printMeasure :: Monad m => (MsgId, M.Map MeasureEvent Timestamp) -> Source m Text
    printMeasure (mid, mm) = printRow $
        sformat int mid : map (\e -> maybe "-" (sformat int) $ mm ^. at e) eventsUniverse

    eventsUniverse = [minBound .. maxBound]


main :: IO ()
main = usingLoggerName mempty $ do
    initLogging Info
    measures <- flip execStateT M.empty $
        forM_ logFiles analyze
    printMeasures "measures.csv" measures
  where
    logFiles :: [FilePath]
    logFiles =
        [ "sender.log"
        , "receiver.log"
        ]
