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


init : String -> ( Model, Cmd Msg )
init wsUrl =
    ( { screen = WsConnectingScreen
      , jeopardyPlaying = False
      , now = 0
      , pending = []
      , savedState = Nothing
      , dingKey = 0
      , pendingStartTime = Nothing
      , wsClientId = Nothing
      , timerEndsAt = 0
      , myUuid = Nothing
      , wsUrl = wsUrl
      , questions = []
      }
    , Cmd.batch
        [ readFile "app-uuid.json"
        , readFile "config/quiz-questions.json"
        , Task.perform (\posix -> Tick (toFloat (Time.posixToMillis posix))) Time.now
        ]
    )


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
                    , Cmd.batch [ pauseMusic "jeopardy-audio", videoCmd, resumeCmd model saved.screen ]
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
                        case getQuestion model.questions idx of
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
                        case getQuestion model.questions idx of
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
                    case getQuestion model.questions idx of
                        Just q ->
                            if List.any (\a -> normalize answer == normalize a) q.answers then
                                let
                                    nextIdx =
                                        idx + 1
                                in
                                case getQuestion model.questions nextIdx of
                                    Just _ ->
                                        ( { model | screen = CheckingAnswerScreen (BlankScreen nextIdx) }
                                            |> clearPending
                                            |> schedule 1000 (PlaySong nextIdx)
                                        , sendWs model (quizAdvancedEnvelope idx)
                                        )

                                    Nothing ->
                                        -- Empty text for now; the server fills it in at win
                                        -- time via the winText message (see ServerWinText),
                                        -- once it independently confirms quizAdvancedEnvelope
                                        -- reached the real last question (see Server.elm's
                                        -- acceptQuizAdvance/quizJustCompleted).
                                        ( clearPending { model | screen = CheckingAnswerScreen (WinScreen "") }
                                        , sendWs model (quizAdvancedEnvelope idx)
                                        )

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
                    if state.fakeFlashActive then
                        if state.fakeIsTrap then
                            -- Caught by the one-time trap: play the penalty cutscene
                            -- locally and report the catch; the server doubles its count.
                            ( clearPending
                                { model
                                    | screen =
                                        FakeFlashCaughtScreen
                                            { questionIdx = state.questionIdx
                                            , originalTotal = state.totalDings
                                            , displayNumerator = state.dingCount
                                            , displayDenominator = state.totalDings
                                            , phase = FfDelay
                                            }
                                }
                                |> schedule 1000 FakeFlashNextPhase
                            , sendWs model iqCaughtEnvelope
                            )

                        else
                            -- Pressed a 50%-phase fake: that's a miss.
                            iqFail model state

                    else if state.dingActive then
                        -- Cleared a real ding: update the displayed counter right away
                        -- for responsive rendering, then report it -- the server is
                        -- still authoritative and its next ServerIqDing/
                        -- ServerIqTestComplete overwrites whatever we guess here.
                        -- Mirror the server's own advanceOnClear rule so the guess is
                        -- actually right, not just eventually corrected: while still
                        -- in the doubled-punishment range (totalDings > iqQuestionCount),
                        -- a clear grinds the denominator down; only once it's back to
                        -- iqQuestionCount does the numerator start counting up.
                        let
                            optimisticState =
                                if state.totalDings > iqQuestionCount then
                                    { state | dingActive = False, totalDings = state.totalDings - 1 }

                                else
                                    { state | dingActive = False, dingCount = state.dingCount + 1 }
                        in
                        ( { model | screen = IQTestActiveScreen optimisticState }
                        , sendWs model iqReadyForDingEnvelope
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
                            -- Back to the IQ Begin screen with the doubled display
                            -- count (capped to agree with the server's own doubling).
                            ( clearPending
                                { model
                                    | screen =
                                        IQTestScreen
                                            { questionIdx = state.questionIdx
                                            , totalDings = Basics.min (state.originalTotal * 2) maxTotalDings
                                            }
                                }
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
                            if String.trim inner == "{}" then
                                ( { model | screen = BeginScreen, jeopardyPlaying = True }, Cmd.none )

                            else
                                case Decode.decodeString decodeModel inner of
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
                                            , myUuid = model.myUuid
                                            , wsUrl = model.wsUrl
                                            , questions = model.questions
                                            , timerEndsAt = model.timerEndsAt
                                          }
                                        , videoCmd
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
                            case model.screen of
                                CheckingAnswerScreen nextScreen ->
                                    { model | screen = ConfirmingAnswerScreen nextScreen }

                                _ ->
                                    model
                    in
                    ( newModel, sendToWs { wsId = wsId, data = Encode.encode 0 (clientStateEnvelope newModel) } )

                ( Nothing, _ ) ->
                    let
                        newModel =
                            case model.screen of
                                CheckingAnswerScreen nextScreen ->
                                    { model | screen = nextScreen }

                                _ ->
                                    model
                    in
                    ( newModel, Cmd.none )

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
        , readFileResult
            (\{ path, contents } ->
                case path of
                    "config/quiz-questions.json" ->
                        QuestionsLoaded (Maybe.map decodeQuestions contents |> Maybe.withDefault [])

                    _ ->
                        case contents of
                            Just raw ->
                                case Decode.decodeString (Decode.field "uuid" Decode.string) raw of
                                    Ok uuid ->
                                        UuidLoaded (Just uuid)

                                    Err _ ->
                                        UuidLoaded Nothing

                            Nothing ->
                                UuidLoaded Nothing
            )
        ]

-- TODO extract logic from TrackEnded and WsPong messages
main : Program String Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
