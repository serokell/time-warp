{-# LANGUAGE ScopedTypeVariables #-}

-- | Command line options of pos-node.

module SenderOptions
       ( Args (..)
       , argsParser
       ) where

import           Control.TimeWarp.Rpc       (NetworkAddress)
import           Data.Monoid                ((<>))
import           Data.String                (fromString)
import           Data.Word                  (Word16)
import           Options.Applicative.Simple (Parser, auto, help, long, many, metavar,
                                             option, optional, short, showDefault,
                                             strOption, switch, value)
import           Serokell.Util.OptParse     (fromParsec)
import           Serokell.Util.Parse        (connection)

data Args = Args
    { logConfig  :: !FilePath
    , logsPrefix :: !(Maybe FilePath)
    , recipients :: ![NetworkAddress]
    , threadNum  :: !Int
    , msgNum     :: !Int
    , msgRate    :: !(Maybe Int)
    , duration   :: !Int
    }
  deriving Show

--TODO introduce subcommands
argsParser :: Parser Args
argsParser =
    Args <$>
    strOption
         (long "log-config"
          <> metavar "FILEPATH"
          <> value "logging.yaml"
          <> showDefault <>
         help "Path to logger configuration")
    <*>
    optional
        (strOption $
         long "logs-prefix" <> metavar "FILEPATH" <> help "Prefix to logger output path")
    <*>
    many
        (option (fromParsec recipient) $
         long "peer" <> metavar "HOST:PORT" <> help "Recipient's ip:port")
    <*>
    option
        auto
        (short 't'
          <> long "thread-num"
          <> metavar "INTEGER"
          <> value 5
          <> showDefault <>
         help "Number of threads to use")
    <*>
    option
        auto
        (short 'm'
          <> long "msg-num"
          <> metavar "INTEGER"
          <> value 1000
          <> showDefault <>
         help "Number of messages to send")
    <*>
    optional
        (option
            auto
            (short 'r'
              <> long "msg-rate"
              <> metavar "INTEGER" <>
             help "Number of messages to send per second")
        )
    <*>
    option
        auto
        (short 'd'
          <> long "duration"
          <> metavar "INTEGER"
          <> value 10
          <> showDefault <>
         help "Time to run before stopping, seconds")
  where
    recipient = connection >>= \(h, mp) ->
        case mp of
            Just p -> return (fromString h, p)
            _      -> fail $ "No port specified for host " <> h
