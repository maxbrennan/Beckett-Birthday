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
      -- Carries the personalized win text, delivered by the server at win time (never
      -- bundled into the client). The text is dropped on serialization so it never lands
      -- in persisted state — see encodeScreen/decodeScreen in Sync.elm.
    | WinScreen String
    | TimedOutScreen
    | CheckingAnswerScreen Screen
    | ConfirmingAnswerScreen Screen


-- A message scheduled to fire at an absolute timestamp (ms since Unix epoch).
type alias PendingEvent =
    { fireAt : Float
    , msg : Msg
    }


type alias Model =
    { isBeginScreen : Bool
    , screen : Screen

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
