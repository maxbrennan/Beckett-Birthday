port module Main exposing (main)

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
import Random
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
      }
    , Cmd.batch
        [ readFile "app-uuid.json"
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
                        if not state.fakeFlashUsed then
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
                            ( clearPending { model | screen = BlankScreen nextIdx }
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
                        ConfirmingAnswerScreen nextScreen ->
                            ( { model | screen = nextScreen }, Cmd.none )

                        _ ->
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
                    , initWebSocketClient model.wsUrl
                    )

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
                    if debug then
                        ( { model | myUuid = Just "dev-mode" }, initWebSocketClient model.wsUrl )

                    else
                        ( { model | screen = WsErrorScreen }, Cmd.none )

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
            (\{ contents } ->
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
