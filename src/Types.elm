module Types exposing (..)

import Game.IQTest exposing (..)
import Json.Decode as Decode


type alias PausedState =
    { screen : Screen
    , pending : List PendingEvent
    , savedAt : Float
    , songResumeTime : Maybe Float
    , videoResumeTime : Maybe Float
    }


type Screen
    = WsConnectingScreen
    | WsErrorScreen
    | WsLoadingScreen
    | BeginScreen
    | BlankScreen Int
    | VideoScreen Int String
    | QuestionScreen Int String
    | WrongAnswerScreen Int
    | IQTestScreen IQTestScreenState
    | IQTestCountdownScreen IQTestCountdownState
    | IQTestActiveScreen IQTestState
    | FakeFlashCaughtScreen FakeFlashCaughtState
    | WinScreen
    | TimedOutScreen
    | CheckingAnswerScreen Screen
    | ConfirmingAnswerScreen Screen


-- A message scheduled to fire at an absolute timestamp (ms since Unix epoch).
type alias PendingEvent =
    { fireAt : Float
    , msg : Msg
    }


type alias Model =
    { screen : Screen
    , jeopardyPlaying : Bool
    , now : Float
    , pending : List PendingEvent
    , savedState : Maybe PausedState
    , dingKey : Int
    , pendingStartTime : Maybe Float
    , wsClientId : Maybe String
    , timerEndsAt : Float
    , myUuid : Maybe String
    , wsUrl : String
    }


type Msg
    = Tick Float
    | BeginPressed
    | PlaySong Int
    | TrackEnded String
    | ShowQuestion Int
    | AnswerChanged String
    | AnswerSubmitted
    | ContinuePressed
    | IQTestBeginPressed
    | IQTestStarted IQTestInit
    | CountdownTick
    | DingOccurred
    | DingFlashEnd
    | DingWindowExpired
    | SpaceBarPressed
    | ScheduleNextDing DingSchedule
    | StartLoudMusic
    | FakeFlashNextPhase
    | FakeFlashCounterTick
    | FakeFlashWindowExpired
    | SongMetadataLoaded
    | DomPropertyReceived { elementId : String, property : String, value : Decode.Value }
    | DomPropertyError String
    | WsClientReady String
    | WsDataReceived String
    | WsSyncTick
    | WsDisconnected String
    | WsReconnect
    | UuidLoaded (Maybe String)
    | NoOp
