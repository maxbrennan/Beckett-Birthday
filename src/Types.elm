module Types exposing (..)

import Game.IQTest exposing (..)
import Game.Quiz exposing (..)
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
      -- idx, and the correct answer's display text, delivered by the server
      -- in QuizAnswerResult (never bundled into the client -- see #54). The
      -- text is dropped on serialization, same as WinScreen's -- see
      -- encodeScreen/decodeScreen in Sync.elm.
    | WrongAnswerScreen Int String
    | IQTestScreen IQTestScreenState
    | IQTestCountdownScreen IQTestCountdownState
    | IQTestActiveScreen IQTestState
    | FakeFlashCaughtScreen FakeFlashCaughtState
    | IQTestSkipOfferScreen IQTestScreenState
    | IQTestSkipAnimScreen IQSkipAnimState
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
    , questions : List String
    , awaitingAnswerResult : Bool
    , iqOfferMade : Bool

    -- This build's config-time choice (see RegistryEntry.iqOfferDisabled), delivered
    -- once via ServerIqOfferGate on the initial stateRequest. Defaults True (offer
    -- enabled) so a client that hasn't heard from the server yet behaves like the
    -- pre-config-flag behavior. Never round-tripped through encodeModel/decodeModel --
    -- restored across a WsDataReceived decode the same way myUuid/wsUrl/questions are.
    , iqOfferEnabled : Bool
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
    | IQSkipOfferAccepted
    | IQSkipOfferDeclined
    | IQSkipAnimNextPhase
    | IQSkipCounterTick
    | SongMetadataLoaded
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
