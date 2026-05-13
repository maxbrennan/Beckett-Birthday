port module Main exposing (main)

import Browser
import Browser.Dom
import Browser.Events
import Char
import Html exposing (Html, audio, button, div, img, input, p, text, video)
import Html.Attributes exposing (autoplay, id, loop, placeholder, property, src, style, type_, value)
import Html.Events exposing (on, onClick, onInput)
import Html.Keyed
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Random
import Task
import Time


port pauseMusic : String -> Cmd msg

port setDomProperty : { elementId : String, property : String, value : Encode.Value } -> Cmd msg

port domPropertyError : (String -> msg) -> Sub msg

port getDomProperty : { elementId : String, property : String } -> Cmd msg

port receiveDomProperty : ({ elementId : String, property : String, value : Decode.Value } -> msg) -> Sub msg

port logToFile : String -> Cmd msg

wsUrl : String
wsUrl =
    "ws://localhost:5270"


port initWebSocketClient : String -> Cmd msg

port wsClientReady : (String -> msg) -> Sub msg

port sendToWs : { wsId : String, data : String } -> Cmd msg

port receiveFromWs : (String -> msg) -> Sub msg

port wsClientFailed : (String -> msg) -> Sub msg


-- Set to True to enable debug mode (smaller counts, faster delays, no AirPods required).
debug : Bool
debug =
    True


-- Total correct ding presses required to pass the IQ test.
-- Debug: 10  |  Production: 100
iqQuestionCount : Int
iqQuestionCount =
    if debug then
        10

    else
        100


-- Lower bound (as a fraction of iqQuestionCount) for the fake-flash trap position.
-- Debug: 0.65  |  Production: 0.85
fakeFlashRangeLo : Float
fakeFlashRangeLo =
    if debug then
        0.65

    else
        0.85


-- Upper bound (as a fraction of iqQuestionCount) for the fake-flash trap position.
-- Debug: 0.75  |  Production: 0.95
fakeFlashRangeHi : Float
fakeFlashRangeHi =
    if debug then
        0.75

    else
        0.95


-- Minimum milliseconds between successive dings.
-- Debug: 100  |  Production: 2000
minDingDelay : Float
minDingDelay =
    if debug then
        2000

    else
        2000


-- Maximum milliseconds between successive dings.
-- Debug: 500  |  Production: 15000
maxDingDelay : Float
maxDingDelay =
    if debug then
        5000

    else
        15000


-- Duration (ms) of the green flash visual.
iqFlashDuration : Float
iqFlashDuration =
    250


-- Duration (ms) of the window in which a space-bar press counts as a ding response.
iqWindowDuration : Float
iqWindowDuration =
    2000


-- Volume (0–1) for the ding sound effect.
iqDingVolume : Float
iqDingVolume =
    0.8


-- Milliseconds per tick for the counter animation on the fake-flash penalty screen.
counterTickMs : Float
counterTickMs =
    80


-- Total time allowed to complete the quiz.
-- Debug: 10 minutes  |  Production: 7 days
timeLimitMs : Float
timeLimitMs =
    if debug then
        600000

    else
        7 * 24 * 60 * 60 * 1000


type alias Question =
    { song : String
    , answers : List String
    }


questions : List Question
questions =
    [ { song = "golden.mp3", answers = [ "Golden" ] }
    , { song = "im-just-ken.mp3", answers = [ "I'm Just Ken" ] }
    , { song = "espresso.mp3", answers = [ "Espresso" ] }
    , { song = "revenge.mp4", answers = [ "Revenge", "Revenge Parody", "Revenge a Minecraft Parody" ] }
    , { song = "chest-pain.mp3", answers = [ "Chest Pain", "I Love", "Chest Pain I Love" ] }
    , { song = "i-saw-your-face.mp3", answers = [ "I Saw Your Face" ] }
    , { song = "dracula.mp3", answers = [ "Dracula" ] }
    , { song = "borderline.mp3", answers = [ "Borderline" ] }
    , { song = "cant-stop.mp3", answers = [ "Can't Stop" ] }
    , { song = "korean.mp3", answers = [ "천 번 차이는 남자" ] }
    ]


getQuestion : Int -> Maybe Question
getQuestion idx =
    List.head (List.drop idx questions)


normalize : String -> String
normalize s =
    s
        |> String.toLower
        |> String.filter (\c -> Char.isAlpha c || c == ' ')
        |> String.words
        |> String.join " "


capitalize : String -> String
capitalize s =
    case String.uncons s of
        Just ( first, rest ) ->
            String.fromChar (Char.toUpper first) ++ rest

        Nothing ->
            s


isVideo : String -> Bool
isVideo filename =
    String.endsWith ".mp4" filename


type alias DingSchedule =
    { delay : Float, nextRandom : Bool }


type alias IQTestInit =
    { delay : Float, nextRandom : Bool, fakeFlashPoint : Int }


type alias PausedState =
    { screen : Screen
    , pending : List PendingEvent
    , savedAt : Float
    , songResumeTime : Maybe Float
    , videoResumeTime : Maybe Float
    }


type alias IQTestScreenState =
    { questionIdx : Int
    , totalDings : Int
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    }


-- State for the countdown shown between pressing "Begin" and the test starting.
type alias IQTestCountdownState =
    { questionIdx : Int
    , totalDings : Int
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    , countdown : Int
    , initData : IQTestInit
    }


type alias IQTestState =
    { questionIdx : Int
    , dingCount : Int
    , totalDings : Int
    , isFlashing : Bool
    , dingActive : Bool
    , fakeFlashActive : Bool
    , loudPlaying : Bool
    , fakeFlashUsed : Bool
    , fakeFlashPoint : Int
    , nextRandom : Bool
    , in50PercentPhase : Bool
    }


type FakeFlashPhase
    = FfDelay
    | FfText1In
    | FfText1Hold
    | FfText1Out
    | FfText2In
    | FfText2Hold
    | FfText2Out
    | FfCounterIn
    | FfTickNumerator
    | FfTickDelay
    | FfTickDenominator
    | FfCounterOut


type alias FakeFlashCaughtState =
    { questionIdx : Int
    , originalTotal : Int
    , displayNumerator : Int
    , displayDenominator : Int
    , phase : FakeFlashPhase
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
    , hasSeenFakeFlashPunishment : Bool
    , savedState : Maybe PausedState
    , dingKey : Int
    , pendingStartTime : Maybe Float
    , wsClientId : Maybe String
    , timerEndsAt : Float
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
    | NoOp


init : () -> ( Model, Cmd Msg )
init _ =
    ( { screen = WsConnectingScreen
      , jeopardyPlaying = False
      , now = 0
      , pending = []
      , hasSeenFakeFlashPunishment = False
      , savedState = Nothing
      , dingKey = 0
      , pendingStartTime = Nothing
      , wsClientId = Nothing
      , timerEndsAt = 0
      }
    , Cmd.batch
        [ initWebSocketClient wsUrl
        , Task.perform (\posix -> Tick (toFloat (Time.posixToMillis posix))) Time.now
        ]
    )


-- Queue a message to fire `delay` ms from now.
schedule : Float -> Msg -> Model -> Model
schedule delay msg model =
    { model | pending = { fireAt = model.now + delay, msg = msg } :: model.pending }


-- Drop all pending events (use on major screen transitions to avoid stale firings).
clearPending : Model -> Model
clearPending model =
    { model | pending = [] }


dingScheduleGen : Random.Generator DingSchedule
dingScheduleGen =
    Random.map2 (\d r -> { delay = d, nextRandom = r })
        (Random.float minDingDelay maxDingDelay)
        (Random.map (\n -> n < 0.5) (Random.float 0 1))


iqTestInitGen : Int -> Random.Generator IQTestInit
iqTestInitGen total =
    let
        lo =
            Basics.max 0 (floor (fakeFlashRangeLo * toFloat total))

        hi =
            Basics.max lo (Basics.min (total - 1) (floor (fakeFlashRangeHi * toFloat total)))
    in
    Random.map3 (\d r fp -> { delay = d, nextRandom = r, fakeFlashPoint = fp })
        (Random.float minDingDelay maxDingDelay)
        (Random.map (\n -> n < 0.5) (Random.float 0 1))
        (Random.int lo hi)


iqFail : Model -> IQTestState -> ( Model, Cmd Msg )
iqFail model state =
    ( clearPending
        { model
            | screen =
                IQTestScreen
                    { questionIdx = state.questionIdx
                    , totalDings = state.totalDings
                    , fakeFlashUsed = state.fakeFlashUsed
                    , in50PercentPhase = state.in50PercentPhase
                    }
        }
    , Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Advance the clock. Fire any events whose fireAt has passed.
        -- The first Tick (model.now == 0) just initialises the clock without firing.
        Tick t ->
            if model.now == 0 then
                ( { model | now = t, timerEndsAt = t + timeLimitMs }, Cmd.none )

            else
                let
                    ( due, stillPending ) =
                        List.partition (\e -> e.fireAt <= t) model.pending

                    baseModel =
                        { model | now = t, pending = stillPending }

                    ( finalModel, finalCmd ) =
                        List.foldl
                            (\event ( m, cmd ) ->
                                let
                                    ( m2, cmd2 ) =
                                        update event.msg m
                                in
                                ( m2, Cmd.batch [ cmd, cmd2 ] )
                            )
                            ( baseModel, Cmd.none )
                            due

                    timedOut =
                        finalModel.timerEndsAt > 0 && t >= finalModel.timerEndsAt &&
                            (case finalModel.screen of
                                WsConnectingScreen -> False
                                WsErrorScreen -> False
                                WsLoadingScreen -> False
                                TimedOutScreen -> False
                                _ -> True
                            )
                in
                if timedOut then
                    ( { finalModel | screen = TimedOutScreen }, finalCmd )
                else
                    ( finalModel, finalCmd )

        
        BeginPressed ->
            case model.savedState of
                Just saved ->
                    let
                        -- Update pending events to fire at the same intervals from now as they would have from the savedAt time.
                        rebasedPending =
                            List.map
                                (\e -> { e | fireAt = model.now + max 500 (e.fireAt - saved.savedAt) })
                                saved.pending

                        videoCmd =
                            case saved.videoResumeTime of
                                Just t ->
                                    case saved.screen of
                                        VideoScreen _ _ ->
                                            setDomProperty { elementId = "playing-video", property = "currentTime", value = Encode.float t }

                                        IQTestActiveScreen state ->
                                            if state.loudPlaying then
                                                setDomProperty { elementId = "playing-video", property = "currentTime", value = Encode.float t }

                                            else
                                                Cmd.none

                                        _ ->
                                            Cmd.none

                                Nothing ->
                                    Cmd.none
                    in
                    ( { model
                        | screen = saved.screen
                        , pending = rebasedPending
                        , savedState = Nothing
                        , jeopardyPlaying = False
                        , pendingStartTime = saved.songResumeTime
                      }
                    , Cmd.batch [ pauseMusic "jeopardy-audio", videoCmd ]
                    )

                Nothing ->
                    ( { model | screen = BlankScreen 0, jeopardyPlaying = False, savedState = Nothing }
                        |> clearPending
                        |> schedule 1000 (PlaySong 0)
                    , pauseMusic "jeopardy-audio"
                    )

        PlaySong idx ->
            let
                innerBlankIdx s =
                    case s of
                        BlankScreen i ->
                            Just i

                        CheckingAnswerScreen inner ->
                            innerBlankIdx inner

                        ConfirmingAnswerScreen inner ->
                            innerBlankIdx inner

                        _ ->
                            Nothing
            in
            case innerBlankIdx model.screen of
                Just blankIdx ->
                    if blankIdx == idx then
                        case getQuestion idx of
                            Just q ->
                                if isVideo q.song then
                                    ( { model | screen = VideoScreen idx q.song }, Cmd.none )

                                else
                                    ( model, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        TrackEnded name ->
            if name == "jeopardy-theme.mp3" then
                case model.screen of
                    BeginScreen ->
                        ( model, Cmd.none )

                    _ ->
                        ( { model | jeopardyPlaying = False }, Cmd.none )

            else
                case model.screen of
                    BlankScreen idx ->
                        case getQuestion idx of
                            Just q ->
                                if q.song == name then
                                    ( schedule 1000 (ShowQuestion idx) model, Cmd.none )

                                else
                                    ( model, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )

                    VideoScreen idx _ ->
                        ( { model | screen = BlankScreen idx }
                            |> schedule 1000 (ShowQuestion idx)
                        , Cmd.none
                        )

                    _ ->
                        ( model, Cmd.none )

        ShowQuestion idx ->
            case model.screen of
                BlankScreen blankIdx ->
                    if blankIdx == idx then
                        ( { model | screen = QuestionScreen idx "" }
                        , Task.attempt (\_ -> NoOp) (Browser.Dom.focus "answer-input")
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        AnswerChanged typed ->
            case model.screen of
                QuestionScreen idx _ ->
                    ( { model | screen = QuestionScreen idx typed }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        AnswerSubmitted ->
            case model.screen of
                QuestionScreen idx answer ->
                    case getQuestion idx of
                        Just q ->
                            if List.any (\a -> normalize answer == normalize a) q.answers then
                                let
                                    nextIdx =
                                        idx + 1
                                in
                                case getQuestion nextIdx of
                                    Just _ ->
                                        ( { model | screen = CheckingAnswerScreen (BlankScreen nextIdx) }
                                            |> clearPending
                                            |> schedule 1000 (PlaySong nextIdx)
                                        , Cmd.none
                                        )

                                    Nothing ->
                                        ( clearPending { model | screen = CheckingAnswerScreen WinScreen }, Cmd.none )

                            else
                                ( { model | screen = CheckingAnswerScreen (WrongAnswerScreen idx) }, Cmd.none )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        ContinuePressed ->
            case model.screen of
                WrongAnswerScreen idx ->
                    ( clearPending
                        { model
                            | screen =
                                IQTestScreen
                                    { questionIdx = idx
                                    , totalDings = iqQuestionCount
                                    , fakeFlashUsed = False
                                    , in50PercentPhase = False
                                    }
                        }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        IQTestBeginPressed ->
            case model.screen of
                IQTestScreen iqScreen ->
                    ( model
                    , Random.generate IQTestStarted (iqTestInitGen iqScreen.totalDings)
                    )

                _ ->
                    ( model, Cmd.none )

        IQTestStarted initData ->
            case model.screen of
                IQTestScreen iqScreen ->
                    ( { model
                        | screen =
                            IQTestCountdownScreen
                                { questionIdx = iqScreen.questionIdx
                                , totalDings = iqScreen.totalDings
                                , fakeFlashUsed = iqScreen.fakeFlashUsed
                                , in50PercentPhase = iqScreen.in50PercentPhase
                                , countdown = iqScreen.totalDings
                                , initData = initData
                                }
                      }
                        |> schedule 1000 CountdownTick
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        CountdownTick ->
            case model.screen of
                IQTestCountdownScreen state ->
                    if state.countdown > 1 then
                        ( { model | screen = IQTestCountdownScreen { state | countdown = state.countdown - 1 } }
                            |> schedule 1000 CountdownTick
                        , Cmd.none
                        )

                    else
                        let
                            { delay, nextRandom, fakeFlashPoint } =
                                state.initData
                        in
                        ( clearPending
                            { model
                                | screen =
                                    IQTestActiveScreen
                                        { questionIdx = state.questionIdx
                                        , dingCount = 0
                                        , totalDings = state.totalDings
                                        , isFlashing = False
                                        , dingActive = False
                                        , fakeFlashActive = False
                                        , loudPlaying = False
                                        , fakeFlashUsed = state.fakeFlashUsed
                                        , fakeFlashPoint = fakeFlashPoint
                                        , nextRandom = nextRandom
                                        , in50PercentPhase = state.in50PercentPhase
                                        }
                            }
                            |> schedule delay DingOccurred
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        ScheduleNextDing { delay, nextRandom } ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | nextRandom = nextRandom } }
                        |> schedule delay DingOccurred
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        DingOccurred ->
            case model.screen of
                IQTestActiveScreen state ->
                    let
                        isFakeFlashPoint =
                            not state.fakeFlashUsed
                                && not state.in50PercentPhase
                                && state.dingCount == state.fakeFlashPoint

                        isFake =
                            isFakeFlashPoint || (state.in50PercentPhase && state.nextRandom)
                    in
                    if isFake then
                        ( { model | screen = IQTestActiveScreen { state | isFlashing = True, fakeFlashActive = True } }
                            |> schedule iqFlashDuration DingFlashEnd
                            |> schedule iqWindowDuration FakeFlashWindowExpired
                        , Cmd.none
                        )

                    else
                        ( { model
                            | screen = IQTestActiveScreen { state | isFlashing = True, dingActive = True }
                            , dingKey = model.dingKey + 1
                          }
                            |> schedule iqFlashDuration DingFlashEnd
                            |> schedule iqWindowDuration DingWindowExpired
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        DingFlashEnd ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | isFlashing = False } }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        DingWindowExpired ->
            case model.screen of
                IQTestActiveScreen state ->
                    if state.dingActive then
                        iqFail model state

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        FakeFlashWindowExpired ->
            case model.screen of
                IQTestActiveScreen state ->
                    if state.fakeFlashActive then
                        ( { model | screen = IQTestActiveScreen { state | fakeFlashActive = False, fakeFlashUsed = True } }
                        , Random.generate ScheduleNextDing dingScheduleGen
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SpaceBarPressed ->
            case model.screen of
                IQTestActiveScreen state ->
                    if state.fakeFlashActive then
                        if not model.hasSeenFakeFlashPunishment then
                            ( clearPending
                                { model
                                    | hasSeenFakeFlashPunishment = True
                                    , screen =
                                        FakeFlashCaughtScreen
                                            { questionIdx = state.questionIdx
                                            , originalTotal = state.totalDings
                                            , displayNumerator = state.dingCount
                                            , displayDenominator = state.totalDings
                                            , phase = FfDelay
                                            }
                                }
                                |> schedule 1000 FakeFlashNextPhase
                            , Cmd.none
                            )

                        else
                            iqFail model state

                    else if state.dingActive then
                        let
                            stillPunished =
                                state.totalDings > iqQuestionCount

                            newDingCount =
                                if stillPunished then state.dingCount else state.dingCount + 1

                            newTotalDings =
                                if stillPunished then state.totalDings - 1 else state.totalDings

                            newIn50Percent =
                                state.in50PercentPhase || (stillPunished && newTotalDings == iqQuestionCount)

                            completed =
                                not stillPunished && newDingCount >= state.totalDings

                            -- Trigger the loud loop on the 4th legitimate ding (only once per session).
                            triggerLoud =
                                not stillPunished && not state.loudPlaying && newDingCount == 4

                            nextIdx =
                                state.questionIdx + 1
                        in
                        if completed then
                            ( clearPending { model | screen = BlankScreen nextIdx, hasSeenFakeFlashPunishment = False }
                                |> schedule 1000 (PlaySong nextIdx)
                            , Cmd.none
                            )

                        else
                            let
                                newState =
                                    { state
                                        | dingCount = newDingCount
                                        , totalDings = newTotalDings
                                        , dingActive = False
                                        , in50PercentPhase = newIn50Percent
                                    }

                                newModel =
                                    if triggerLoud then
                                        { model | screen = IQTestActiveScreen newState }
                                            |> schedule 3000 StartLoudMusic

                                    else
                                        { model | screen = IQTestActiveScreen newState }
                            in
                            ( newModel
                            , Random.generate ScheduleNextDing dingScheduleGen
                            )

                    else
                        iqFail model state

                _ ->
                    ( model, Cmd.none )

        StartLoudMusic ->
            case model.screen of
                IQTestActiveScreen state ->
                    ( { model | screen = IQTestActiveScreen { state | loudPlaying = True } }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        FakeFlashNextPhase ->
            case model.screen of
                FakeFlashCaughtScreen state ->
                    let
                        advance newPhase delay =
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = newPhase } }
                                |> schedule delay FakeFlashNextPhase
                            , Cmd.none
                            )
                    in
                    case state.phase of
                        FfDelay ->
                            advance FfText1In 1000

                        FfText1In ->
                            advance FfText1Hold 2500

                        FfText1Hold ->
                            advance FfText1Out 1000

                        FfText1Out ->
                            advance FfText2In 800

                        FfText2In ->
                            advance FfText2Hold 2500

                        FfText2Hold ->
                            advance FfText2Out 1000

                        FfText2Out ->
                            advance FfCounterIn 700

                        FfCounterIn ->
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = FfTickNumerator } }
                                |> schedule counterTickMs FakeFlashCounterTick
                            , Cmd.none
                            )

                        FfTickDelay ->
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = FfTickDenominator } }
                                |> schedule counterTickMs FakeFlashCounterTick
                            , Cmd.none
                            )

                        FfCounterOut ->
                            ( clearPending
                                { model
                                    | screen =
                                        IQTestScreen
                                            { questionIdx = state.questionIdx
                                            , totalDings = state.originalTotal * 2
                                            , fakeFlashUsed = True
                                            , in50PercentPhase = False
                                            }
                                }
                            , Cmd.none
                            )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        WsClientReady wsId ->
            ( { model | wsClientId = Just wsId, screen = WsLoadingScreen }, Cmd.none )

        WsDataReceived json ->
            case model.screen of
                WsLoadingScreen ->
                    if String.trim json == "{}" then
                        ( { model | screen = BeginScreen, jeopardyPlaying = True }, Cmd.none )

                    else
                        case Decode.decodeString decodeModel json of
                            Ok newModel ->
                                let
                                    videoCmd =
                                        newModel.savedState
                                            |> Maybe.andThen .videoResumeTime
                                            |> Maybe.map (\t -> setDomProperty { elementId = "playing-video", property = "currentTime", value = Encode.float t })
                                            |> Maybe.withDefault Cmd.none
                                in
                                ( { newModel
                                    | wsClientId = model.wsClientId
                                    , dingKey = model.dingKey
                                    , hasSeenFakeFlashPunishment = model.hasSeenFakeFlashPunishment
                                  }
                                , videoCmd
                                )

                            Err _ ->
                                ( model, Cmd.none )

                ConfirmingAnswerScreen nextScreen ->
                    if isAck json then
                        ( { model | screen = nextScreen }, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        WsDisconnected _ ->
            let
                _ = Debug.log "WebSocket disconnected"
            in
            case model.screen of
                WsConnectingScreen ->
                    ( model |> schedule 3000 WsReconnect, Cmd.none )

                WsLoadingScreen ->
                    ( { model | screen = WsConnectingScreen, wsClientId = Nothing } |> schedule 3000 WsReconnect, Cmd.none )

                _ ->
                    ( { model | wsClientId = Nothing, screen = WsConnectingScreen }
                    , initWebSocketClient wsUrl
                    )

        WsReconnect ->
            case model.screen of
                WsErrorScreen ->
                    ( { model | screen = WsConnectingScreen }, initWebSocketClient wsUrl )

                WsConnectingScreen ->
                    ( model, initWebSocketClient wsUrl )

                _ ->
                    ( model, Cmd.none )

        WsSyncTick ->
            case model.wsClientId of
                Just wsId ->
                    let
                        newModel =
                            case model.screen of
                                CheckingAnswerScreen nextScreen ->
                                    { model | screen = ConfirmingAnswerScreen nextScreen }

                                _ ->
                                    model
                    in
                    ( newModel, sendToWs { wsId = wsId, data = Encode.encode 0 (encodeModel newModel) } )

                Nothing ->
                    let
                        newModel =
                            case model.screen of
                                CheckingAnswerScreen nextScreen ->
                                    { model | screen = nextScreen }

                                _ ->
                                    model
                    in
                    ( newModel, Cmd.none )

        NoOp ->
            ( model, Cmd.none )

        SongMetadataLoaded ->
            case model.pendingStartTime of
                Just t ->
                    ( { model | pendingStartTime = Nothing }
                    , setDomProperty { elementId = "quiz-audio", property = "currentTime", value = Encode.float t }
                    )

                Nothing ->
                    ( model, Cmd.none )

        DomPropertyReceived _ ->
            ( model, Cmd.none )

        DomPropertyError _ ->
            ( model, Cmd.none )

        FakeFlashCounterTick ->
            case model.screen of
                FakeFlashCaughtScreen state ->
                    case state.phase of
                        FfTickNumerator ->
                            if state.displayNumerator > 0 then
                                ( { model
                                    | screen = FakeFlashCaughtScreen { state | displayNumerator = state.displayNumerator - 1 }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , setDomProperty { elementId = "ding-audio", property = "volume", value = Encode.float 0.15 }
                                )

                            else
                                ( { model | screen = FakeFlashCaughtScreen { state | phase = FfTickDelay } }
                                    |> schedule 500 FakeFlashNextPhase
                                , Cmd.none
                                )

                        FfTickDenominator ->
                            let
                                target =
                                    state.originalTotal * 2
                            in
                            if state.displayDenominator < target then
                                ( { model
                                    | screen = FakeFlashCaughtScreen { state | displayDenominator = state.displayDenominator + 1 }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , setDomProperty { elementId = "ding-audio", property = "volume", value = Encode.float 0.3 }
                                )

                            else
                                ( { model | screen = FakeFlashCaughtScreen { state | phase = FfCounterOut } }
                                    |> schedule 1500 FakeFlashNextPhase
                                , Cmd.none
                                )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )


screenBg : String -> List (Html Msg) -> Html Msg
screenBg bg children =
    div
        [ style "height" "100vh"
        , style "background-color" bg
        , style "display" "flex"
        , style "flex-direction" "column"
        , style "align-items" "center"
        , style "justify-content" "center"
        , style "gap" "36px"
        ]
        children


screen : List (Html Msg) -> Html Msg
screen =
    screenBg "#a8c8e0"


headphones : Html Msg
headphones =
    img
        [ src "assets/airpods.png"
        , style "width" "340px"
        ]
        []


isCounterBig : FakeFlashPhase -> Bool
isCounterBig phase =
    case phase of
        FfCounterIn ->
            True

        FfTickNumerator ->
            True

        FfTickDelay ->
            True

        FfTickDenominator ->
            True

        FfCounterOut ->
            True

        _ ->
            False


-- ── JSON Encoders ────────────────────────────────────────────────────────────


encodeMaybeString : Maybe String -> Encode.Value
encodeMaybeString =
    Maybe.map Encode.string >> Maybe.withDefault Encode.null


encodeMaybeFloat : Maybe Float -> Encode.Value
encodeMaybeFloat =
    Maybe.map Encode.float >> Maybe.withDefault Encode.null


isAck : String -> Bool
isAck json =
    Decode.decodeString (Decode.field "tag" Decode.string) json
        |> Result.map ((==) "ack")
        |> Result.withDefault False


encodeFakeFlashPhase : FakeFlashPhase -> Encode.Value
encodeFakeFlashPhase phase =
    Encode.string
        (case phase of
            FfDelay -> "FfDelay"
            FfText1In -> "FfText1In"
            FfText1Hold -> "FfText1Hold"
            FfText1Out -> "FfText1Out"
            FfText2In -> "FfText2In"
            FfText2Hold -> "FfText2Hold"
            FfText2Out -> "FfText2Out"
            FfCounterIn -> "FfCounterIn"
            FfTickNumerator -> "FfTickNumerator"
            FfTickDelay -> "FfTickDelay"
            FfTickDenominator -> "FfTickDenominator"
            FfCounterOut -> "FfCounterOut"
        )


encodeIQTestScreenState : IQTestScreenState -> Encode.Value
encodeIQTestScreenState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "totalDings", Encode.int s.totalDings )
        , ( "fakeFlashUsed", Encode.bool s.fakeFlashUsed )
        , ( "in50PercentPhase", Encode.bool s.in50PercentPhase )
        ]


encodeIQTestInit : IQTestInit -> Encode.Value
encodeIQTestInit s =
    Encode.object
        [ ( "delay", Encode.float s.delay )
        , ( "nextRandom", Encode.bool s.nextRandom )
        , ( "fakeFlashPoint", Encode.int s.fakeFlashPoint )
        ]


encodeIQTestCountdownState : IQTestCountdownState -> Encode.Value
encodeIQTestCountdownState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "totalDings", Encode.int s.totalDings )
        , ( "fakeFlashUsed", Encode.bool s.fakeFlashUsed )
        , ( "in50PercentPhase", Encode.bool s.in50PercentPhase )
        , ( "countdown", Encode.int s.countdown )
        , ( "initData", encodeIQTestInit s.initData )
        ]


encodeIQTestState : IQTestState -> Encode.Value
encodeIQTestState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "dingCount", Encode.int s.dingCount )
        , ( "totalDings", Encode.int s.totalDings )
        , ( "isFlashing", Encode.bool s.isFlashing )
        , ( "dingActive", Encode.bool s.dingActive )
        , ( "fakeFlashActive", Encode.bool s.fakeFlashActive )
        , ( "loudPlaying", Encode.bool s.loudPlaying )
        , ( "fakeFlashUsed", Encode.bool s.fakeFlashUsed )
        , ( "fakeFlashPoint", Encode.int s.fakeFlashPoint )
        , ( "nextRandom", Encode.bool s.nextRandom )
        , ( "in50PercentPhase", Encode.bool s.in50PercentPhase )
        ]


encodeFakeFlashCaughtState : FakeFlashCaughtState -> Encode.Value
encodeFakeFlashCaughtState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "originalTotal", Encode.int s.originalTotal )
        , ( "displayNumerator", Encode.int s.displayNumerator )
        , ( "displayDenominator", Encode.int s.displayDenominator )
        , ( "phase", encodeFakeFlashPhase s.phase )
        ]


encodeScreen : Screen -> Encode.Value
encodeScreen scr =
    case scr of
        WsConnectingScreen ->
            Encode.object [ ( "tag", Encode.string "WsConnectingScreen" ) ]

        WsErrorScreen ->
            Encode.object [ ( "tag", Encode.string "WsErrorScreen" ) ]

        WsLoadingScreen ->
            Encode.object [ ( "tag", Encode.string "WsLoadingScreen" ) ]

        BeginScreen ->
            Encode.object [ ( "tag", Encode.string "BeginScreen" ) ]

        BlankScreen idx ->
            Encode.object [ ( "tag", Encode.string "BlankScreen" ), ( "idx", Encode.int idx ) ]

        VideoScreen idx s ->
            Encode.object [ ( "tag", Encode.string "VideoScreen" ), ( "idx", Encode.int idx ), ( "s", Encode.string s ) ]

        QuestionScreen idx s ->
            Encode.object [ ( "tag", Encode.string "QuestionScreen" ), ( "idx", Encode.int idx ), ( "s", Encode.string s ) ]

        WrongAnswerScreen idx ->
            Encode.object [ ( "tag", Encode.string "WrongAnswerScreen" ), ( "idx", Encode.int idx ) ]

        IQTestScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestScreen" ), ( "state", encodeIQTestScreenState state ) ]

        IQTestCountdownScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestCountdownScreen" ), ( "state", encodeIQTestCountdownState state ) ]

        IQTestActiveScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestActiveScreen" ), ( "state", encodeIQTestState state ) ]

        FakeFlashCaughtScreen state ->
            Encode.object [ ( "tag", Encode.string "FakeFlashCaughtScreen" ), ( "state", encodeFakeFlashCaughtState state ) ]

        WinScreen ->
            Encode.object [ ( "tag", Encode.string "WinScreen" ) ]

        TimedOutScreen ->
            Encode.object [ ( "tag", Encode.string "TimedOutScreen" ) ]

        CheckingAnswerScreen nextScreen ->
            Encode.object [ ( "tag", Encode.string "CheckingAnswerScreen" ), ( "nextScreen", encodeScreen nextScreen ) ]

        ConfirmingAnswerScreen nextScreen ->
            Encode.object [ ( "tag", Encode.string "ConfirmingAnswerScreen" ), ( "nextScreen", encodeScreen nextScreen ) ]


encodeMsg : Msg -> Encode.Value
encodeMsg msg =
    case msg of
        Tick t ->
            Encode.object [ ( "tag", Encode.string "Tick" ), ( "t", Encode.float t ) ]

        PlaySong idx ->
            Encode.object [ ( "tag", Encode.string "PlaySong" ), ( "idx", Encode.int idx ) ]

        ShowQuestion idx ->
            Encode.object [ ( "tag", Encode.string "ShowQuestion" ), ( "idx", Encode.int idx ) ]

        TrackEnded filename ->
            Encode.object [ ( "tag", Encode.string "TrackEnded" ), ( "filename", Encode.string filename ) ]

        ScheduleNextDing s ->
            Encode.object [ ( "tag", Encode.string "ScheduleNextDing" ), ( "delay", Encode.float s.delay ), ( "nextRandom", Encode.bool s.nextRandom ) ]

        IQTestStarted s ->
            Encode.object [ ( "tag", Encode.string "IQTestStarted" ), ( "initData", encodeIQTestInit s ) ]

        DingFlashEnd ->
            Encode.object [ ( "tag", Encode.string "DingFlashEnd" ) ]

        DingWindowExpired ->
            Encode.object [ ( "tag", Encode.string "DingWindowExpired" ) ]

        FakeFlashWindowExpired ->
            Encode.object [ ( "tag", Encode.string "FakeFlashWindowExpired" ) ]

        FakeFlashCounterTick ->
            Encode.object [ ( "tag", Encode.string "FakeFlashCounterTick" ) ]

        FakeFlashNextPhase ->
            Encode.object [ ( "tag", Encode.string "FakeFlashNextPhase" ) ]

        CountdownTick ->
            Encode.object [ ( "tag", Encode.string "CountdownTick" ) ]

        StartLoudMusic ->
            Encode.object [ ( "tag", Encode.string "StartLoudMusic" ) ]

        DingOccurred ->
            Encode.object [ ( "tag", Encode.string "DingOccurred" ) ]

        WsReconnect ->
            Encode.object [ ( "tag", Encode.string "WsReconnect" ) ]

        _ ->
            Encode.object [ ( "tag", Encode.string "NoOp" ) ]


encodePendingEvent : PendingEvent -> Encode.Value
encodePendingEvent e =
    Encode.object
        [ ( "fireAt", Encode.float e.fireAt )
        , ( "msg", encodeMsg e.msg )
        ]


encodePausedState : PausedState -> Encode.Value
encodePausedState s =
    Encode.object
        [ ( "screen", encodeScreen s.screen )
        , ( "pending", Encode.list encodePendingEvent s.pending )
        , ( "savedAt", Encode.float s.savedAt )
        , ( "songResumeTime", encodeMaybeFloat s.songResumeTime )
        , ( "videoResumeTime", encodeMaybeFloat s.videoResumeTime )
        ]


encodeModel : Model -> Encode.Value
encodeModel model =
    Encode.object
        [ ( "screen", encodeScreen model.screen )
        , ( "jeopardyPlaying", Encode.bool model.jeopardyPlaying )
        , ( "now", Encode.float model.now )
        , ( "pending", Encode.list encodePendingEvent model.pending )
        , ( "savedState", model.savedState |> Maybe.map encodePausedState |> Maybe.withDefault Encode.null )
        , ( "hasSeenFakeFlashPunishment", Encode.bool model.hasSeenFakeFlashPunishment )
        , ( "dingKey", Encode.int model.dingKey )
        , ( "pendingStartTime", encodeMaybeFloat model.pendingStartTime )
        , ( "wsClientId", encodeMaybeString model.wsClientId )
        , ( "timerEndsAt", Encode.float model.timerEndsAt )
        ]


-- ── JSON Decoders ─────────────────────────────────────────────────────────────


decodeFakeFlashPhase : Decoder FakeFlashPhase
decodeFakeFlashPhase =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "FfDelay" -> Decode.succeed FfDelay
                    "FfText1In" -> Decode.succeed FfText1In
                    "FfText1Hold" -> Decode.succeed FfText1Hold
                    "FfText1Out" -> Decode.succeed FfText1Out
                    "FfText2In" -> Decode.succeed FfText2In
                    "FfText2Hold" -> Decode.succeed FfText2Hold
                    "FfText2Out" -> Decode.succeed FfText2Out
                    "FfCounterIn" -> Decode.succeed FfCounterIn
                    "FfTickNumerator" -> Decode.succeed FfTickNumerator
                    "FfTickDelay" -> Decode.succeed FfTickDelay
                    "FfTickDenominator" -> Decode.succeed FfTickDenominator
                    "FfCounterOut" -> Decode.succeed FfCounterOut
                    _ -> Decode.fail ("Unknown FakeFlashPhase: " ++ s)
            )


decodeIQTestScreenState : Decoder IQTestScreenState
decodeIQTestScreenState =
    Decode.map4
        (\qi td ffu i50 -> { questionIdx = qi, totalDings = td, fakeFlashUsed = ffu, in50PercentPhase = i50 })
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "totalDings" Decode.int)
        (Decode.field "fakeFlashUsed" Decode.bool)
        (Decode.field "in50PercentPhase" Decode.bool)


decodeIQTestInit : Decoder IQTestInit
decodeIQTestInit =
    Decode.map3
        (\d nr fp -> { delay = d, nextRandom = nr, fakeFlashPoint = fp })
        (Decode.field "delay" Decode.float)
        (Decode.field "nextRandom" Decode.bool)
        (Decode.field "fakeFlashPoint" Decode.int)


decodeIQTestCountdownState : Decoder IQTestCountdownState
decodeIQTestCountdownState =
    Decode.map6
        (\qi td ffu i50 cd initData ->
            { questionIdx = qi, totalDings = td, fakeFlashUsed = ffu
            , in50PercentPhase = i50, countdown = cd, initData = initData
            }
        )
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "totalDings" Decode.int)
        (Decode.field "fakeFlashUsed" Decode.bool)
        (Decode.field "in50PercentPhase" Decode.bool)
        (Decode.field "countdown" Decode.int)
        (Decode.field "initData" decodeIQTestInit)


decodeIQTestState : Decoder IQTestState
decodeIQTestState =
    Decode.map8
        (\qi dc td isF dA ffA lP ffU ->
            \ffP nr i50 ->
                { questionIdx = qi, dingCount = dc, totalDings = td, isFlashing = isF
                , dingActive = dA, fakeFlashActive = ffA, loudPlaying = lP, fakeFlashUsed = ffU
                , fakeFlashPoint = ffP, nextRandom = nr, in50PercentPhase = i50
                }
        )
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "dingCount" Decode.int)
        (Decode.field "totalDings" Decode.int)
        (Decode.field "isFlashing" Decode.bool)
        (Decode.field "dingActive" Decode.bool)
        (Decode.field "fakeFlashActive" Decode.bool)
        (Decode.field "loudPlaying" Decode.bool)
        (Decode.field "fakeFlashUsed" Decode.bool)
        |> Decode.andThen
            (\partial ->
                Decode.map3 partial
                    (Decode.field "fakeFlashPoint" Decode.int)
                    (Decode.field "nextRandom" Decode.bool)
                    (Decode.field "in50PercentPhase" Decode.bool)
            )


decodeFakeFlashCaughtState : Decoder FakeFlashCaughtState
decodeFakeFlashCaughtState =
    Decode.map5
        (\qi ot dn dd ph ->
            { questionIdx = qi, originalTotal = ot, displayNumerator = dn, displayDenominator = dd, phase = ph }
        )
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "originalTotal" Decode.int)
        (Decode.field "displayNumerator" Decode.int)
        (Decode.field "displayDenominator" Decode.int)
        (Decode.field "phase" decodeFakeFlashPhase)


decodeScreen : Decoder Screen
decodeScreen =
    Decode.field "tag" Decode.string
        |> Decode.andThen
            (\tag ->
                case tag of
                    "WsConnectingScreen" ->
                        Decode.succeed WsConnectingScreen

                    "WsErrorScreen" ->
                        Decode.succeed WsErrorScreen

                    "WsLoadingScreen" ->
                        Decode.succeed WsLoadingScreen

                    "BeginScreen" ->
                        Decode.succeed BeginScreen

                    "BlankScreen" ->
                        Decode.map BlankScreen (Decode.field "idx" Decode.int)

                    "VideoScreen" ->
                        Decode.map2 VideoScreen
                            (Decode.field "idx" Decode.int)
                            (Decode.field "s" Decode.string)

                    "QuestionScreen" ->
                        Decode.map2 QuestionScreen
                            (Decode.field "idx" Decode.int)
                            (Decode.field "s" Decode.string)

                    "WrongAnswerScreen" ->
                        Decode.map WrongAnswerScreen (Decode.field "idx" Decode.int)

                    "IQTestScreen" ->
                        Decode.map IQTestScreen (Decode.field "state" decodeIQTestScreenState)

                    "IQTestCountdownScreen" ->
                        Decode.map IQTestCountdownScreen (Decode.field "state" decodeIQTestCountdownState)

                    "IQTestActiveScreen" ->
                        Decode.map IQTestActiveScreen (Decode.field "state" decodeIQTestState)

                    "FakeFlashCaughtScreen" ->
                        Decode.map FakeFlashCaughtScreen (Decode.field "state" decodeFakeFlashCaughtState)

                    "WinScreen" ->
                        Decode.succeed WinScreen

                    "TimedOutScreen" ->
                        Decode.succeed TimedOutScreen

                    "CheckingAnswerScreen" ->
                        Decode.map CheckingAnswerScreen (Decode.field "nextScreen" decodeScreen)

                    "ConfirmingAnswerScreen" ->
                        Decode.map ConfirmingAnswerScreen (Decode.field "nextScreen" decodeScreen)

                    _ ->
                        Decode.fail ("Unknown screen: " ++ tag)
            )


decodeMsg : Decoder Msg
decodeMsg =
    Decode.field "tag" Decode.string
        |> Decode.andThen
            (\tag ->
                case tag of
                    "Tick" ->
                        Decode.map Tick (Decode.field "t" Decode.float)

                    "PlaySong" ->
                        Decode.map PlaySong (Decode.field "idx" Decode.int)

                    "ShowQuestion" ->
                        Decode.map ShowQuestion (Decode.field "idx" Decode.int)

                    "TrackEnded" ->
                        Decode.map TrackEnded (Decode.field "filename" Decode.string)

                    "ScheduleNextDing" ->
                        Decode.map2 (\d nr -> ScheduleNextDing { delay = d, nextRandom = nr })
                            (Decode.field "delay" Decode.float)
                            (Decode.field "nextRandom" Decode.bool)

                    "IQTestStarted" ->
                        Decode.map IQTestStarted (Decode.field "initData" decodeIQTestInit)

                    "DingFlashEnd" ->
                        Decode.succeed DingFlashEnd

                    "DingWindowExpired" ->
                        Decode.succeed DingWindowExpired

                    "FakeFlashWindowExpired" ->
                        Decode.succeed FakeFlashWindowExpired

                    "FakeFlashCounterTick" ->
                        Decode.succeed FakeFlashCounterTick

                    "FakeFlashNextPhase" ->
                        Decode.succeed FakeFlashNextPhase

                    "CountdownTick" ->
                        Decode.succeed CountdownTick

                    "StartLoudMusic" ->
                        Decode.succeed StartLoudMusic

                    "DingOccurred" ->
                        Decode.succeed DingOccurred

                    "WsReconnect" ->
                        Decode.succeed WsReconnect

                    _ ->
                        Decode.succeed NoOp
            )


decodePendingEvent : Decoder PendingEvent
decodePendingEvent =
    Decode.map2 PendingEvent
        (Decode.field "fireAt" Decode.float)
        (Decode.field "msg" decodeMsg)


decodePausedState : Decoder PausedState
decodePausedState =
    Decode.map5
        (\scr pending savedAt songResumeTime videoResumeTime ->
            { screen = scr, pending = pending, savedAt = savedAt
            , songResumeTime = songResumeTime, videoResumeTime = videoResumeTime
            }
        )
        (Decode.field "screen" decodeScreen)
        (Decode.field "pending" (Decode.list decodePendingEvent))
        (Decode.field "savedAt" Decode.float)
        (Decode.field "songResumeTime" (Decode.nullable Decode.float))
        (Decode.field "videoResumeTime" (Decode.nullable Decode.float))


decodeModel : Decoder Model
decodeModel =
    Decode.map8
        (\scr jp n pend hsf ss dk pst ->
            \wci tea ->
                { screen = scr
                , jeopardyPlaying = jp
                , now = n
                , pending = pend
                , hasSeenFakeFlashPunishment = hsf
                , savedState = ss
                , dingKey = dk
                , pendingStartTime = pst
                , wsClientId = wci
                , timerEndsAt = tea
                }
        )
        (Decode.field "screen" decodeScreen)
        (Decode.field "jeopardyPlaying" Decode.bool)
        (Decode.field "now" Decode.float)
        (Decode.field "pending" (Decode.list decodePendingEvent))
        (Decode.field "hasSeenFakeFlashPunishment" Decode.bool)
        (Decode.field "savedState" (Decode.nullable decodePausedState))
        (Decode.field "dingKey" Decode.int)
        (Decode.field "pendingStartTime" (Decode.nullable Decode.float))
        |> Decode.andThen
            (\partial ->
                Decode.map2 partial
                    (Decode.field "wsClientId" (Decode.nullable Decode.string))
                    (Decode.field "timerEndsAt" Decode.float)
            )


formatTimer : Float -> String
formatTimer ms =
    let
        totalSecs =
            floor (ms / 1000)

        days =
            totalSecs // 86400

        hours =
            (totalSecs - days * 86400) // 3600

        minutes =
            (totalSecs - days * 86400 - hours * 3600) // 60

        secs =
            modBy 60 totalSecs
    in
    String.fromInt days
        ++ "d "
        ++ String.fromInt hours
        ++ "h "
        ++ String.fromInt minutes
        ++ "m "
        ++ String.fromInt secs
        ++ "s"


timerBar : Model -> Html Msg
timerBar model =
    let
        showTimer =
            case model.screen of
                WsConnectingScreen ->
                    False

                WsErrorScreen ->
                    False

                WsLoadingScreen ->
                    False

                _ ->
                    True

        remaining =
            max 0 (model.timerEndsAt - model.now)
    in
    if showTimer then
        div
            [ style "position" "fixed"
            , style "top" "0"
            , style "left" "0"
            , style "right" "0"
            , style "background-color" "rgba(0,0,0,0.18)"
            , style "color" "white"
            , style "font-size" "14px"
            , style "font-weight" "bold"
            , style "text-align" "center"
            , style "padding" "6px 0"
            , style "letter-spacing" "0.05em"
            , style "pointer-events" "none"
            ]
            [ text (formatTimer remaining ++ " remaining") ]

    else
        text ""


currentQuizSong : Model -> Maybe String
currentQuizSong model =
    case model.screen of
        BlankScreen idx ->
            getQuestion idx
                |> Maybe.andThen
                    (\q ->
                        if isVideo q.song then
                            Nothing

                        else
                            Just q.song
                    )

        _ ->
            Nothing


viewAudio : Model -> Html Msg
viewAudio model =
    let
        jeopardyAudio =
            if model.jeopardyPlaying then
                audio
                    [ id "jeopardy-audio"
                    , src "assets/jeopardy-theme.mp3"
                    , autoplay True
                    , loop True
                    ]
                    []

            else
                text ""

        quizAudio =
            case currentQuizSong model of
                Just songSrc ->
                    audio
                        [ id "quiz-audio"
                        , src ("assets/" ++ songSrc)
                        , autoplay True
                        , on "loadedmetadata" (Decode.succeed SongMetadataLoaded)
                        , on "ended" (Decode.succeed (TrackEnded songSrc))
                        ]
                        []

                Nothing ->
                    text ""

        dingAudio =
            if model.dingKey > 0 then
                Html.Keyed.node "div"
                    []
                    [ ( "ding-" ++ String.fromInt model.dingKey
                      , audio
                            [ id "ding-audio"
                            , src "assets/ding.mp3"
                            , autoplay True
                            , property "volume" (Encode.float iqDingVolume)
                            ]
                            []
                      )
                    ]

            else
                text ""
    in
    div [] [ jeopardyAudio, quizAudio, dingAudio ]


view : Model -> Html Msg
view model =
    div []
        [ viewScreen model
        , viewAudio model
        , timerBar model
        ]


viewScreen : Model -> Html Msg
viewScreen model =
    case model.screen of
        WsConnectingScreen ->
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Connecting to server..." ]
                ]

        WsErrorScreen ->
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#c0392b"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "480px"
                    , style "line-height" "1.5"
                    ]
                    [ text "Something is wrong with the internet connection. Reconnecting..." ]
                ]

        WsLoadingScreen ->
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Loading..." ]
                ]

        BeginScreen ->
            screen
                [ headphones
                , p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "480px"
                    , style "line-height" "1.5"
                    ]
                    [ text "Press Begin once you can hear the music." ]
                , button
                    [ onClick BeginPressed
                    , style "padding" "20px 64px"
                    , style "font-size" "24px"
                    , style "cursor" "pointer"
                    , style "border-radius" "12px"
                    , style "border" "none"
                    , style "background-color" "#4a9eca"
                    , style "color" "white"
                    , style "font-weight" "bold"
                    ]
                    [ text "Begin" ]
                ]

        BlankScreen idx ->
            let
                bg =
                    case getQuestion idx of
                        Just q ->
                            if isVideo q.song then
                                "#000000"

                            else
                                "#a8c8e0"

                        Nothing ->
                            "#a8c8e0"
            in
            screenBg bg []

        VideoScreen _ filename ->
            div
                [ style "position" "fixed"
                , style "top" "0"
                , style "left" "0"
                , style "width" "100vw"
                , style "height" "100vh"
                , style "background-color" "#000000"
                ]
                [ video
                    [ id "playing-video"
                    , src ("assets/" ++ filename)
                    , autoplay True
                    , on "ended" (Decode.succeed (TrackEnded filename))
                    , style "position" "absolute"
                    , style "top" "50%"
                    , style "left" "50%"
                    , style "transform" "translate(-50%, -50%)"
                    , style "width" "100%"
                    , style "height" "100%"
                    , style "object-fit" "contain"
                    ]
                    []
                ]

        QuestionScreen idx answer ->
            let
                prompt =
                    if idx == 0 then
                        "Let's start with an easy one. What song just played?"

                    else
                        "What song just played?"

                total =
                    List.length questions

                progress =
                    "Question " ++ String.fromInt (idx + 1) ++ " of " ++ String.fromInt total
            in
            div []
                [ p
                    [ style "position" "fixed"
                    , style "top" "20px"
                    , style "left" "0"
                    , style "width" "100%"
                    , style "text-align" "center"
                    , style "font-size" "16px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    ]
                    [ text progress ]
                , screen
                    [ p
                        [ style "font-size" "26px"
                        , style "color" "#2c4a5a"
                        , style "text-align" "center"
                        , style "margin" "0"
                        , style "max-width" "560px"
                        , style "line-height" "1.5"
                        ]
                        [ text prompt ]
                    , input
                        [ id "answer-input"
                        , type_ "text"
                        , value answer
                        , onInput AnswerChanged
                        , on "keydown"
                            (Decode.field "key" Decode.string
                                |> Decode.andThen
                                    (\key ->
                                        if key == "Enter" then
                                            Decode.succeed AnswerSubmitted

                                        else
                                            Decode.fail "not enter"
                                    )
                            )
                        , placeholder "Type your answer..."
                        , style "font-size" "22px"
                        , style "padding" "12px 20px"
                        , style "border-radius" "8px"
                        , style "border" "1px solid #4a9eca"
                        , style "outline" "none"
                        , style "width" "400px"
                        , style "box-sizing" "border-box"
                        ]
                        []
                    , button
                        [ onClick AnswerSubmitted
                        , style "padding" "16px 48px"
                        , style "font-size" "22px"
                        , style "cursor" "pointer"
                        , style "border-radius" "12px"
                        , style "border" "none"
                        , style "background-color" "#4a9eca"
                        , style "color" "white"
                        , style "font-weight" "bold"
                        ]
                        [ text "Submit" ]
                    ]
                ]

        WrongAnswerScreen idx ->
            let
                correctAnswer =
                    case getQuestion idx of
                        Just q ->
                            List.head q.answers
                                |> Maybe.map capitalize
                                |> Maybe.withDefault "Unknown"

                        Nothing ->
                            "Unknown"
            in
            screen
                [ p
                    [ style "font-size" "26px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "560px"
                    , style "line-height" "1.5"
                    ]
                    [ text ("The song was \"" ++ correctAnswer ++ "\".") ]
                , button
                    [ onClick ContinuePressed
                    , style "padding" "16px 48px"
                    , style "font-size" "22px"
                    , style "cursor" "pointer"
                    , style "border-radius" "12px"
                    , style "border" "none"
                    , style "background-color" "#4a9eca"
                    , style "color" "white"
                    , style "font-weight" "bold"
                    ]
                    [ text "Continue" ]
                ]

        IQTestScreen _ ->
            screen
                [ p
                    [ style "font-size" "36px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    ]
                    [ text "IQ Test 2.0" ]
                , p
                    [ style "font-size" "22px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "560px"
                    , style "line-height" "1.6"
                    ]
                    [ text "You are so dumb that you don't know what song was playing. You must prove your IQ to keep playing." ]
                , p
                    [ style "font-size" "20px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "520px"
                    , style "line-height" "1.6"
                    ]
                    [ text "Listen carefully for a faint ding. Every time you hear it, press the space bar." ]
                , button
                    [ onClick IQTestBeginPressed
                    , style "padding" "16px 48px"
                    , style "font-size" "22px"
                    , style "cursor" "pointer"
                    , style "border-radius" "12px"
                    , style "border" "none"
                    , style "background-color" "#4a9eca"
                    , style "color" "white"
                    , style "font-weight" "bold"
                    ]
                    [ text "Begin" ]
                ]

        IQTestCountdownScreen state ->
            let
                secondsWord =
                    if state.countdown == 1 then
                        "second"

                    else
                        "seconds"
            in
            screen
                [ p
                    [ style "font-size" "28px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "max-width" "560px"
                    , style "line-height" "1.6"
                    ]
                    [ text ("You may start the IQ test in " ++ String.fromInt state.countdown ++ " " ++ secondsWord ++ ".") ]
                ]

        IQTestActiveScreen state ->
            let
                bg =
                    if state.loudPlaying then
                        "#000000"

                    else
                        "#a8c8e0"

                counter =
                    String.fromInt state.dingCount ++ " / " ++ String.fromInt state.totalDings
            in
            div []
                [ if state.isFlashing then
                    div
                        [ style "position" "fixed"
                        , style "top" "0"
                        , style "left" "0"
                        , style "width" "100vw"
                        , style "height" "100vh"
                        , style "background-color" "#00cc44"
                        , style "z-index" "9999"
                        , style "pointer-events" "none"
                        ]
                        []

                  else
                    text ""
                , if state.loudPlaying then
                    video
                        [ id "playing-video"
                        , src "assets/loud.mp4"
                        , autoplay True
                        , loop True
                        , style "position" "fixed"
                        , style "top" "50%"
                        , style "left" "50%"
                        , style "transform" "translate(-50%, -50%)"
                        , style "width" "100vw"
                        , style "height" "100vh"
                        , style "object-fit" "contain"
                        , style "z-index" "0"
                        ]
                        []

                  else
                    text ""
                , p
                    [ style "position" "fixed"
                    , style "top" "20px"
                    , style "left" "0"
                    , style "width" "100%"
                    , style "text-align" "center"
                    , style "font-size" "20px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "z-index" "10"
                    ]
                    [ text counter ]
                , screenBg bg []
                ]

        FakeFlashCaughtScreen state ->
            let
                big =
                    isCounterBig state.phase

                counterTop =
                    if big then "50%" else "20px"

                counterTransform =
                    if big then "translate(-50%, -50%)" else "translate(-50%, 0)"

                counterFontSize =
                    if big then "96px" else "20px"

                counterOpacity =
                    if state.phase == FfCounterOut then "0" else "1"

                text1Opacity =
                    case state.phase of
                        FfText1In ->
                            "1"

                        FfText1Hold ->
                            "1"

                        _ ->
                            "0"

                text2Opacity =
                    case state.phase of
                        FfText2In ->
                            "1"

                        FfText2Hold ->
                            "1"

                        _ ->
                            "0"

                counterText =
                    String.fromInt state.displayNumerator ++ " / " ++ String.fromInt state.displayDenominator

                text2Transition =
                    case state.phase of
                        FfDelay ->
                            "none"

                        _ ->
                            "opacity 0.8s ease"
            in
            div [ style "height" "100vh", style "background-color" "#a8c8e0" ]
                [ p
                    [ style "position" "fixed"
                    , style "top" counterTop
                    , style "left" "50%"
                    , style "transform" counterTransform
                    , style "font-size" counterFontSize
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    , style "text-align" "center"
                    , style "white-space" "nowrap"
                    , style "opacity" counterOpacity
                    , style "transition" "top 0.6s ease, font-size 0.6s ease, opacity 0.8s ease, transform 0.6s ease"
                    , style "z-index" "10"
                    ]
                    [ text counterText ]
                , p
                    [ style "position" "fixed"
                    , style "top" "50%"
                    , style "left" "50%"
                    , style "transform" "translate(-50%, -50%)"
                    , style "font-size" "28px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "text-align" "center"
                    , style "max-width" "600px"
                    , style "line-height" "1.5"
                    , style "opacity" text1Opacity
                    , style "transition" "opacity 0.8s ease"
                    ]
                    [ text "You pressed the space bar because you saw a green flash." ]
                , p
                    [ style "position" "fixed"
                    , style "top" "50%"
                    , style "left" "50%"
                    , style "transform" "translate(-50%, -50%)"
                    , style "font-size" "28px"
                    , style "color" "#2c4a5a"
                    , style "margin" "0"
                    , style "text-align" "center"
                    , style "max-width" "600px"
                    , style "line-height" "1.5"
                    , style "opacity" text2Opacity
                    , style "transition" text2Transition
                    ]
                    [ text "But there was no ding..." ]
                ]

        WinScreen ->
            screen
                [ p
                    [ style "font-size" "48px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    ]
                    [ text "Text \"creeper... awwww man\" to Max to claim your reward!" ]
                ]

        TimedOutScreen ->
            screen
                [ p
                    [ style "font-size" "42px"
                    , style "color" "#c0392b"
                    , style "text-align" "center"
                    , style "margin" "0"
                    , style "font-weight" "bold"
                    ]
                    [ text "You ran out of time." ]
                ]

        CheckingAnswerScreen _ ->
            screen
                [ p
                    [ style "font-size" "32px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Checking..." ]
                ]

        ConfirmingAnswerScreen _ ->
            screen
                [ p
                    [ style "font-size" "32px"
                    , style "color" "#2c4a5a"
                    , style "text-align" "center"
                    , style "margin" "0"
                    ]
                    [ text "Checking..." ]
                ]


spaceBarDecoder : Decoder Msg
spaceBarDecoder =
    Decode.field "key" Decode.string
        |> Decode.andThen
            (\key ->
                if key == " " then
                    Decode.succeed SpaceBarPressed

                else
                    Decode.fail "not space"
            )


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        keyboardSub =
            case model.screen of
                IQTestActiveScreen _ ->
                    Browser.Events.onKeyDown spaceBarDecoder

                _ ->
                    Sub.none

    in
    Sub.batch
        [ wsClientReady WsClientReady
        , receiveFromWs WsDataReceived
        , wsClientFailed WsDisconnected
        , Time.every 1000 (\_ -> WsSyncTick)
        , keyboardSub
        , Browser.Events.onAnimationFrame (\posix -> Tick (toFloat (Time.posixToMillis posix)))
        , receiveDomProperty DomPropertyReceived
        , domPropertyError DomPropertyError
        ]

-- TODO extract logic from TrackEnded and WsPong messages
main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
