module Types exposing (..)

import Game.IQTest exposing (..)
import Game.Quiz exposing (..)
import Json.Decode as Decode


type Screen
    = WsConnectingScreen
    | WsErrorScreen
    | WsLoadingScreen
    | BlankScreen Int
    | VideoScreen Int String
    | QuestionScreen Int String
      -- idx, and the correct answer's display text, delivered by the server
      -- in QuizAnswerResult (never bundled into the client -- see #54). The
      -- text is dropped on serialization, same as WinScreen's -- see
      -- encodeScreen/decodeScreen in Sync.elm.
    | WrongAnswerScreen Int String
    | IQTestScreen IQTestScreenState
    | IQTestCountdownScreen IQTestCountdownState
    | IQTestActiveScreen IQTestState
    | FakeFlashCaughtScreen FakeFlashCaughtState
      -- Carries the personalized win text, delivered live by the server via a
      -- standalone winText message at win time. Also derived server-side
      -- (embedding the real, already-verified text) so it persists/round-trips
      -- normally through encodeScreen/decodeScreen for the reconnect path.
    | WinScreen String
    | TimedOutScreen
    | CheckingAnswerScreen Screen
    | ConfirmingAnswerScreen Screen
      -- Wraps the real underlying screen the player will resume into. The server
      -- derives and delivers this exact wrapping on connect/reconnect while the
      -- player hasn't pressed Begin yet; pressing Begin unwraps it locally with
      -- no additional round-trip (see Main.elm's BeginPressed).
    | BeginScreen Screen


-- A message scheduled to fire at an absolute timestamp (ms since Unix epoch).
type alias PendingEvent =
    { fireAt : Float
    , msg : Msg
    }


type alias Model =
    { screen : Screen

    -- Local-only from here down: never encoded/decoded (see Sync.elm's
    -- encodeModel/decodeModel). `pending`/`dingKey` drive live scheduling and
    -- the ding-slot DOM-restart animation trick and reset fresh on every
    -- connect/resume rather than surviving a disconnect with any precision.
    , now : Float
    , pending : List PendingEvent
    , dingKey : Int
    , wsClientId : Maybe String
    , timerEndsAt : Float
    , myUuid : Maybe String
    , wsUrl : String
    , questions : List String
    , awaitingAnswerResult : Bool

    -- Rendezvous flags for the current BlankScreen: the answer screen is only
    -- revealed once both the local 1s pause has elapsed and the server's
    -- quizSongEndedAck has arrived, whichever comes second. Reset whenever a
    -- new BlankScreen starts (see Main.elm's TrackEnded); not persisted, same
    -- treatment as awaitingAnswerResult.
    , songTimerElapsed : Bool
    , songEndAcked : Bool
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
    | DingFlashEnd
    | DingWindowExpired
    | SpaceBarPressed
    | StartLoudMusic
    | FakeFlashNextPhase
    | FakeFlashCounterTick
    | FakeFlashWindowExpired
    | DomPropertyReceived { elementId : String, property : String, value : Decode.Value }
    | DomPropertyError String
    | WsClientReady String
    | WsDataReceived String
    | WsSyncTick
    | WsDisconnected String
    | WsReconnect
    | UuidLoaded (Maybe String)
    | QuestionsLoaded (List String)
    | NoOp
