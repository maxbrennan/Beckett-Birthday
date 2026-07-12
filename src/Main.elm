port module Main exposing (..)

import Audio exposing (..)
import Browser
import Browser.Dom
import Browser.Events
import Game.IQTest exposing (..)
import Game.Quiz exposing (..)
import Html exposing (Html, audio, button, div, img, input, p, text, video)
import Html.Attributes exposing (autoplay, id, loop, placeholder, property, src, style, type_, value)
import Html.Events exposing (on, onClick, onInput)
import Html.Keyed
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Sync exposing (..)
import Task
import Time
import Types exposing (..)
import View exposing (..)


port pauseMusic : String -> Cmd msg

port setDomProperty : { elementId : String, property : String, value : Encode.Value } -> Cmd msg

port domPropertyError : (String -> msg) -> Sub msg

port getDomProperty : { elementId : String, property : String } -> Cmd msg

port receiveDomProperty : ({ elementId : String, property : String, value : Decode.Value } -> msg) -> Sub msg

port logToFile : String -> Cmd msg

port initWebSocketClient : String -> Cmd msg

port wsClientReady : (String -> msg) -> Sub msg

port sendToWs : { wsId : String, data : String } -> Cmd msg

port receiveFromWs : (String -> msg) -> Sub msg

port wsClientFailed : (String -> msg) -> Sub msg

port readFile : String -> Cmd msg

port readFileResult : ({ path : String, contents : Maybe String, error : Maybe String } -> msg) -> Sub msg

-- Lists assets/songs/ directly -- the client no longer reads any config/ JSON for
-- the quiz (see #54, #70's review); song order comes from the numeric filename
-- convention alone (see Game.Quiz.songOrder).
port readDir : String -> Cmd msg

port readDirResult : ({ path : String, files : List String, error : Maybe String } -> msg) -> Sub msg


init : String -> ( Model, Cmd Msg )
init wsUrl =
    ( { screen = WsConnectingScreen
      , now = 0
      , pending = []
      , dingKey = 0
      , wsClientId = Nothing
      , timerEndsAt = 0
      , myUuid = Nothing
      , wsUrl = wsUrl
      , questions = []
      , awaitingAnswerResult = False
      }
    , Cmd.batch
        [ readFile "app-uuid.json"
        , readDir "assets/songs"
        , Task.perform tickFromPosix Time.now
        ]
    )


-- Converts an animation-frame/Time.now Posix into the Tick Msg it drives.
tickFromPosix : Time.Posix -> Msg
tickFromPosix posix =
    Tick (toFloat (Time.posixToMillis posix))


-- Queue a message to fire `delay` ms from now.
schedule : Float -> Msg -> Model -> Model
schedule delay msg model =
    { model | pending = { fireAt = model.now + delay, msg = msg } :: model.pending }


-- Same as `schedule 3000 WsReconnect`, but first drops any WsReconnect already queued.
-- Without this, a burst of disconnects while the server is unreachable (a real client
-- can see several in quick succession, e.g. from both the socket's error and close
-- events firing for the same failure) queues one WsReconnect per disconnect, all with
-- nearly the same fireAt — when the server comes back, every one of them fires in the
-- same Tick and each independently reopens a socket, flooding the server with duplicate
-- connections for the same uuid (all but one correctly rejected, but the client can
-- spend a long time cycling through the pile-up before it settles).
scheduleReconnect : Model -> Model
scheduleReconnect model =
    { model | pending = { fireAt = model.now + 3000, msg = WsReconnect } :: List.filter (\e -> e.msg /= WsReconnect) model.pending }


-- Drop all pending events (use on major screen transitions to avoid stale firings).
clearPending : Model -> Model
clearPending model =
    { model | pending = [] }


-- Send a payload to the server over the WebSocket, if connected.
sendWs : Model -> Encode.Value -> Cmd Msg
sendWs model payload =
    case model.wsClientId of
        Just wsId ->
            sendToWs { wsId = wsId, data = Encode.encode 0 payload }

        Nothing ->
            Cmd.none


-- After restoring a saved screen on reconnect, tell the server we're back so it
-- can re-arm whatever IQ timer it paused on disconnect (see Server.elm's
-- resumeIqTimer). Harmless to send for FakeFlashCaughtScreen too -- the server
-- has nothing scheduled for that phase, so it's just a no-op there.
resumeCmd : Model -> Screen -> Cmd Msg
resumeCmd model screen =
    case screen of
        IQTestCountdownScreen _ ->
            sendWs model iqResumeEnvelope

        IQTestActiveScreen _ ->
            sendWs model iqResumeEnvelope

        FakeFlashCaughtScreen _ ->
            sendWs model iqResumeEnvelope

        _ ->
            Cmd.none



iqFail : Model -> IQTestState -> ( Model, Cmd Msg )
iqFail model state =
    -- Back to the IQ Begin screen. No server message: the server preserves its
    -- own count/phase across a fail, and the next iqStartCountdown resets only the
    -- run. totalDings here is the display copy the server last sent.
    ( clearPending
        { model
            | screen =
                IQTestScreen
                    { questionIdx = state.questionIdx
                    , totalDings = state.totalDings
                    }
        }
    , Cmd.none
    )


-- Unwraps a BlankScreen index through the CheckingAnswerScreen/ConfirmingAnswerScreen
-- wrappers a screen may be paused/synced under.
innerBlankIdx : Screen -> Maybe Int
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


-- Which BlankScreen index (if any) a TrackEnded event should advance to.
-- VideoScreen always advances (its own end already gates on the right video);
-- BlankScreen only advances if the reported track matches the song scheduled
-- for that question, rejecting a stale TrackEnded left over from a transition.
trackEndedTarget : List String -> Screen -> String -> Maybe Int
trackEndedTarget questions screen name =
    case screen of
        BlankScreen idx ->
            case getQuestion questions idx of
                Just song ->
                    if song == name then
                        Just idx

                    else
                        Nothing

                Nothing ->
                    Nothing

        VideoScreen idx _ ->
            Just idx

        _ ->
            Nothing


-- Which PlaySong (if any) pressing Begin must schedule to actually start the
-- screen we're parked on. Only a bare BlankScreen on a *video* slide with no
-- PlaySong already pending needs the kick: the server-derived resume screen
-- (see Server.elm's deriveQuizScreen) is a BlankScreen, and while an audio
-- slide self-starts from there (the audio element renders and plays -- see
-- Audio.currentQuizSong), a video slide only ever starts via PlaySong's
-- transition into VideoScreen, so without this it would sit on the blank
-- screen forever.
resumePlaySongTarget : List String -> List PendingEvent -> Screen -> Maybe Int
resumePlaySongTarget questions pending screen =
    case screen of
        BlankScreen idx ->
            case getQuestion questions idx of
                Just song ->
                    if isVideo song && not (hasPendingPlaySong idx pending) then
                        Just idx

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


-- Promotes a CheckingAnswerScreen to ConfirmingAnswerScreen once the client
-- actually has a connection to send that state over.
promoteChecking : Screen -> Screen
promoteChecking screen =
    case screen of
        CheckingAnswerScreen nextScreen ->
            ConfirmingAnswerScreen nextScreen

        _ ->
            screen


-- Falls a CheckingAnswerScreen straight through to its wrapped screen when
-- there's no connection to confirm it over.
resolveChecking : Screen -> Screen
resolveChecking screen =
    case screen of
        CheckingAnswerScreen nextScreen ->
            nextScreen

        _ ->
            screen


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        -- Advance the clock. Fire any events whose fireAt has passed.
        -- The first Tick (model.now == 0) just initialises the clock without firing.
        Tick t ->
            if model.now == 0 then
                ( { model | now = t }, Cmd.none )

            else
                let
                    ( due, stillPending ) =
                        List.partition (\e -> e.fireAt <= t) model.pending

                    baseModel =
                        { model | now = t, pending = stillPending }
                in
                -- Whether the session has timed out is a server decision (see
                -- Server.elm's ClientStateUpdate handling / the ServerTimedOut case
                -- below), not something the client computes from its own clock.
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

        
        BeginPressed ->
            case model.screen of
                BeginScreen inner ->
                    -- inner is already whatever the server derived (or, for the
                    -- families that stay self-reported, the client's own last
                    -- report) -- unwrapping it is the whole resume, no separate
                    -- round-trip needed. Clear any stray leftover local
                    -- scheduling defensively (there shouldn't be any live while
                    -- parked on the begin screen), then kick off whatever this
                    -- screen needs to actually start running.
                    let
                        cleared =
                            { model | screen = inner } |> clearPending

                        kicked =
                            case resumePlaySongTarget cleared.questions cleared.pending cleared.screen of
                                Just idx ->
                                    schedule 1000 (PlaySong idx) cleared

                                Nothing ->
                                    cleared
                    in
                    ( kicked
                    , Cmd.batch [ pauseMusic "jeopardy-audio", resumeCmd model inner ]
                    )

                _ ->
                    ( model, Cmd.none )

        PlaySong idx ->
            case innerBlankIdx model.screen of
                Just blankIdx ->
                    if blankIdx == idx then
                        case getQuestion model.questions idx of
                            Just song ->
                                if isVideo song then
                                    ( { model | screen = VideoScreen idx song }, Cmd.none )

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
                ( model, Cmd.none )

            else
                case trackEndedTarget model.questions model.screen name of
                    Just idx ->
                        ( { model | screen = BlankScreen idx }
                            |> schedule 1000 (ShowQuestion idx)
                        , Cmd.none
                        )

                    Nothing ->
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
                    -- The server, not this client, holds the answers (see #54)
                    -- and decides correctness -- the result arrives as
                    -- ServerQuizAnswerResult in WsDataReceived below, which is
                    -- what actually transitions the screen. awaitingAnswerResult
                    -- both disables the submit UI (see View.elm) and guards
                    -- against a duplicate submit while the round trip is in flight.
                    if model.awaitingAnswerResult then
                        ( model, Cmd.none )

                    else
                        ( { model | awaitingAnswerResult = True }
                        , sendWs model (quizAnswerSubmittedEnvelope { idx = idx, answer = answer })
                        )

                _ ->
                    ( model, Cmd.none )

        ContinuePressed ->
            case model.screen of
                WrongAnswerScreen idx _ ->
                    ( clearPending
                        { model
                            | screen =
                                IQTestScreen
                                    { questionIdx = idx
                                    , totalDings = iqQuestionCount
                                    }
                        }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        IQTestBeginPressed ->
            case model.screen of
                IQTestScreen iqScreen ->
                    -- Enter the countdown screen and ask the server to run it. The
                    -- server owns the count and all timing; the client just renders.
                    ( { model
                        | screen =
                            IQTestCountdownScreen
                                { questionIdx = iqScreen.questionIdx
                                , totalDings = iqScreen.totalDings
                                , countdown = iqScreen.totalDings
                                }
                      }
                    , sendWs model iqStartCountdownEnvelope
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
                        -- Correctly ignored the fake: clear it and ask the server
                        -- for the next ding. The server advances its own progression.
                        ( { model | screen = IQTestActiveScreen { state | fakeFlashActive = False } }
                        , sendWs model iqReadyForDingEnvelope
                        )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SpaceBarPressed ->
            case model.screen of
                IQTestActiveScreen state ->
                    -- The server is authoritative and its next ServerIqDing/
                    -- ServerIqTestComplete overwrites whatever decideSpaceBar
                    -- guesses here; this just makes the UI responsive.
                    case decideSpaceBar state of
                        CaughtTrap caughtState ->
                            ( clearPending { model | screen = FakeFlashCaughtScreen caughtState }
                                |> schedule 1000 FakeFlashNextPhase
                            , sendWs model iqCaughtEnvelope
                            )

                        SpaceBarFailed ->
                            iqFail model state

                        OptimisticClear newState ->
                            ( { model | screen = IQTestActiveScreen newState }
                            , sendWs model iqReadyForDingEnvelope
                            )

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
                    case nextFfPhase state.phase of
                        Just ( newPhase, delay ) ->
                            ( { model | screen = FakeFlashCaughtScreen { state | phase = newPhase } }
                                |> schedule delay FakeFlashNextPhase
                            , Cmd.none
                            )

                        Nothing ->
                            case state.phase of
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
                                    ( clearPending { model | screen = IQTestScreen (exitFakeFlash state) }
                                    , Cmd.none
                                    )

                                _ ->
                                    ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        WsClientReady wsId ->
            let
                newModel =
                    { model | wsClientId = Just wsId, screen = WsLoadingScreen }
            in
            case model.myUuid of
                Just uuid ->
                    ( newModel
                    , sendToWs { wsId = wsId, data = Encode.encode 0 (stateRequestEnvelope uuid) }
                    )

                Nothing ->
                    ( { newModel | screen = WsErrorScreen }, Cmd.none )

        WsDataReceived envelopeJson ->
            case Decode.decodeString decodeServerEnvelope envelopeJson of
                Ok (ServerStateUpdate inner) ->
                    case model.screen of
                        WsLoadingScreen ->
                            -- decodeModel is tolerant of the brand-new-player "{}" shape
                            -- (screen defaults to BeginScreen (BlankScreen 0)), so every
                            -- case -- fresh player or resume -- goes through the same
                            -- decode; there's no separate empty-object sentinel branch.
                            case Decode.decodeString decodeModel inner of
                                Ok newModel ->
                                    -- Session/connection-local facts decodeModel can't know
                                    -- (it always fills them with fresh-connection defaults)
                                    -- carry forward from the live model instead. dingKey isn't
                                    -- included: 0 is exactly correct for a freshly (re)connected
                                    -- session, nothing ding-related survives a disconnect.
                                    ( { newModel
                                        | wsClientId = model.wsClientId
                                        , myUuid = model.myUuid
                                        , wsUrl = model.wsUrl
                                        , questions = model.questions
                                        , timerEndsAt = model.timerEndsAt
                                      }
                                    , Cmd.none
                                    )

                                Err _ ->
                                    ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerRejected _) ->
                    ( { model | screen = WsErrorScreen, wsClientId = Nothing }, Cmd.none )

                Ok ServerAck ->
                    case model.screen of
                        ConfirmingAnswerScreen (WinScreen _) ->
                            -- The win screen is revealed by the separate winText message,
                            -- not this ack, so the client waits here until it arrives.
                            ( model, Cmd.none )

                        ConfirmingAnswerScreen nextScreen ->
                            ( { model | screen = nextScreen }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerWinText winText) ->
                    case model.screen of
                        CheckingAnswerScreen (WinScreen _) ->
                            ( { model | screen = WinScreen winText }, Cmd.none )

                        ConfirmingAnswerScreen (WinScreen _) ->
                            ( { model | screen = WinScreen winText }, Cmd.none )

                        WinScreen _ ->
                            ( { model | screen = WinScreen winText }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerIqCountdownTick remaining) ->
                    -- Display-only: the server is authoritative on the countdown.
                    case model.screen of
                        IQTestCountdownScreen state ->
                            ( { model | screen = IQTestCountdownScreen { state | countdown = remaining } }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok ServerIqCountdownComplete ->
                    -- Countdown done: enter the active test and request the first ding.
                    case model.screen of
                        IQTestCountdownScreen state ->
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
                                            , fakeIsTrap = False
                                            , loudPlaying = False
                                            }
                                }
                            , sendWs model iqReadyForDingEnvelope
                            )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerIqDing d) ->
                    -- The server decided real vs fake (and, for fakes, trap vs
                    -- 50%-phase). The client just renders the flash and arms the
                    -- local response window.
                    case model.screen of
                        IQTestActiveScreen state ->
                            let
                                base =
                                    { state | dingCount = d.dingCount, totalDings = d.totalDings, isFlashing = True }
                            in
                            if d.fake then
                                ( { model | screen = IQTestActiveScreen { base | dingActive = False, fakeFlashActive = True, fakeIsTrap = d.trap } }
                                    |> schedule iqFlashDuration DingFlashEnd
                                    |> schedule iqWindowDuration FakeFlashWindowExpired
                                , Cmd.none
                                )

                            else
                                ( { model
                                    | screen = IQTestActiveScreen { base | dingActive = True, fakeFlashActive = False }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule iqFlashDuration DingFlashEnd
                                    |> schedule iqWindowDuration DingWindowExpired
                                , Cmd.none
                                )

                        _ ->
                            ( model, Cmd.none )

                Ok ServerIqStartLoud ->
                    -- The 4th real ding was cleared: arm the loud gag after 3 s
                    -- (kept client-side to match the original timing).
                    case model.screen of
                        IQTestActiveScreen _ ->
                            ( model |> schedule 3000 StartLoudMusic, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok ServerIqTestComplete ->
                    -- The server's count reached the target: release to the next song.
                    case model.screen of
                        IQTestActiveScreen state ->
                            let
                                nextIdx =
                                    state.questionIdx + 1
                            in
                            ( clearPending { model | screen = BlankScreen nextIdx }
                                |> schedule 1000 (PlaySong nextIdx)
                            -- The wrong-answer -> IQ-test-penalty path doesn't replay the
                            -- question -- it advances past it just like a correct answer
                            -- would, so this counts as passing state.questionIdx too (see
                            -- Server.elm's acceptQuizAdvance/quizJustCompleted).
                            , sendWs model (quizAdvancedEnvelope state.questionIdx)
                            )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerQuizAnswerResult r) ->
                    -- The server independently validated the answer (see #54);
                    -- this is what actually transitions off QuestionScreen. The
                    -- idx check guards against a stale result arriving after the
                    -- screen has already moved on (e.g. a race with a reconnect).
                    case model.screen of
                        QuestionScreen idx _ ->
                            if idx /= r.idx then
                                ( model, Cmd.none )

                            else
                                let
                                    cleared =
                                        { model | awaitingAnswerResult = False }
                                in
                                if r.correct then
                                    let
                                        nextIdx =
                                            idx + 1
                                    in
                                    case getQuestion model.questions nextIdx of
                                        Just _ ->
                                            ( { cleared | screen = CheckingAnswerScreen (BlankScreen nextIdx) }
                                                |> clearPending
                                                |> schedule 1000 (PlaySong nextIdx)
                                            , Cmd.none
                                            )

                                        Nothing ->
                                            -- Empty text for now; the server fills it in at win
                                            -- time via the winText message (see ServerWinText),
                                            -- once it independently confirms the server's own
                                            -- quizProgress tally reached totalQuestions (see
                                            -- Server.elm's acceptQuizAdvance/quizJustCompleted).
                                            ( clearPending { cleared | screen = CheckingAnswerScreen (WinScreen "") }
                                            , Cmd.none
                                            )

                                else
                                    ( { cleared | screen = WrongAnswerScreen idx r.revealAnswer }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ServerTimerSync deadline) ->
                    -- Delivered once per stateRequest (see Server.elm's
                    -- ClientStateRequest handling): the server-established 7-day
                    -- deadline, for display only -- the client never computes it.
                    ( { model | timerEndsAt = deadline }, Cmd.none )

                Ok ServerTimedOut ->
                    -- The server's own clock decided the session is over.
                    ( { model | screen = TimedOutScreen }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        WsDisconnected _ ->
            let
                _ = Debug.log "WebSocket disconnected"
            in
            case model.screen of
                WsConnectingScreen ->
                    ( model |> scheduleReconnect, Cmd.none )

                _ ->
                    ( { model | wsClientId = Nothing, screen = WsConnectingScreen } |> scheduleReconnect, Cmd.none )

        WsReconnect ->
            case model.screen of
                WsErrorScreen ->
                    ( { model | screen = WsConnectingScreen }, initWebSocketClient model.wsUrl )

                WsConnectingScreen ->
                    ( model, initWebSocketClient model.wsUrl )

                _ ->
                    ( model, Cmd.none )

        WsSyncTick ->
            case ( model.wsClientId, model.screen ) of
                ( Just _, WsLoadingScreen ) ->
                    ( model, Cmd.none )

                ( Just _, WsConnectingScreen ) ->
                    ( model, Cmd.none )

                ( Just _, WsErrorScreen ) ->
                    ( model, Cmd.none )

                ( Just wsId, _ ) ->
                    let
                        newModel =
                            { model | screen = promoteChecking model.screen }
                    in
                    ( newModel, sendToWs { wsId = wsId, data = Encode.encode 0 (clientStateEnvelope newModel) } )

                ( Nothing, _ ) ->
                    ( { model | screen = resolveChecking model.screen }, Cmd.none )

        UuidLoaded maybeUuid ->
            case maybeUuid of
                Just uuid ->
                    ( { model | myUuid = Just uuid }, initWebSocketClient model.wsUrl )

                Nothing ->
                    ( { model | screen = WsErrorScreen }, Cmd.none )

        QuestionsLoaded loadedQuestions ->
            ( { model | questions = loadedQuestions }, Cmd.none )

        NoOp ->
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
                                let
                                    targetId =
                                        "ding-audio-" ++ String.fromInt (modBy dingSlotCount model.dingKey)
                                in
                                ( { model
                                    | screen = FakeFlashCaughtScreen { state | displayNumerator = state.displayNumerator - 1 }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , setDomProperty { elementId = targetId, property = "volume", value = Encode.float 0.15 }
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
                                let
                                    targetId =
                                        "ding-audio-" ++ String.fromInt (modBy dingSlotCount model.dingKey)
                                in
                                ( { model
                                    | screen = FakeFlashCaughtScreen { state | displayDenominator = state.displayDenominator + 1 }
                                    , dingKey = model.dingKey + 1
                                  }
                                    |> schedule counterTickMs FakeFlashCounterTick
                                , setDomProperty { elementId = targetId, property = "volume", value = Encode.float 0.3 }
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








-- Decides what Msg a readFile port response becomes: app-uuid.json is read for
-- its "uuid" field (it's the only file this port is still used for -- the quiz
-- no longer reads any config/ JSON client-side, see #54/#70's review).
decodeReadFileResult : { path : String, contents : Maybe String, error : Maybe String } -> Msg
decodeReadFileResult { contents } =
    case contents of
        Just raw ->
            case Decode.decodeString (Decode.field "uuid" Decode.string) raw of
                Ok uuid ->
                    UuidLoaded (Just uuid)

                Err _ ->
                    UuidLoaded Nothing

        Nothing ->
            UuidLoaded Nothing


-- Decides what Msg a readDir port response becomes: assets/songs/'s listing,
-- ordered by each filename's leading number (see Game.Quiz.songOrder) -- an
-- unreadable directory naturally yields no questions, the same fail-safe
-- default as a malformed quiz-manifest.json used to.
decodeReadDirResult : { path : String, files : List String, error : Maybe String } -> Msg
decodeReadDirResult { files } =
    QuestionsLoaded (songOrder files)


everySecond : Time.Posix -> Msg
everySecond _ =
    WsSyncTick


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
        , Time.every 1000 everySecond
        , keyboardSub
        , Browser.Events.onAnimationFrame tickFromPosix
        , receiveDomProperty DomPropertyReceived
        , domPropertyError DomPropertyError
        , readFileResult decodeReadFileResult
        , readDirResult decodeReadDirResult
        ]

main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
