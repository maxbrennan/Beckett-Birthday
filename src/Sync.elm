module Sync exposing (..)

import Game.IQTest exposing (..)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Types exposing (..)


-- ── Server Envelope ───────────────────────────────────────────────────────────


type ServerEnvelope
    = ServerStateUpdate String
    | ServerAck
    | ServerAuth
    | ServerRejected String
    | ServerUnknown


decodeServerEnvelope : Decode.Decoder ServerEnvelope
decodeServerEnvelope =
    Decode.field "payload" Decode.string
        |> Decode.andThen
            (\variant ->
                case variant of
                    "stateUpdate" ->
                        Decode.at [ "stateUpdate", "json" ] Decode.string
                            |> Decode.map ServerStateUpdate

                    "ack" ->
                        Decode.succeed ServerAck

                    "authChallenge" ->
                        Decode.succeed ServerAuth

                    "authResult" ->
                        Decode.succeed ServerAuth

                    "stateRequestRejected" ->
                        Decode.at [ "stateRequestRejected", "reason" ] Decode.string
                            |> Decode.map ServerRejected

                    _ ->
                        Decode.succeed ServerUnknown
            )


stateRequestEnvelope : String -> Encode.Value
stateRequestEnvelope uuid =
    Encode.object
        [ ( "payload", Encode.string "stateRequest" )
        , ( "stateRequest", Encode.object [ ( "uuid", Encode.string uuid ) ] )
        ]


-- ── JSON Encoders ─────────────────────────────────────────────────────────────


encodeMaybeString : Maybe String -> Encode.Value
encodeMaybeString =
    Maybe.map Encode.string >> Maybe.withDefault Encode.null


encodeMaybeFloat : Maybe Float -> Encode.Value
encodeMaybeFloat =
    Maybe.map Encode.float >> Maybe.withDefault Encode.null


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


clientStateEnvelope : Model -> Encode.Value
clientStateEnvelope model =
    Encode.object
        [ ( "payload", Encode.string "stateUpdate" )
        , ( "stateUpdate", Encode.object [ ( "json", Encode.string (Encode.encode 0 (encodeModel model)) ) ] )
        ]


encodeModel : Model -> Encode.Value
encodeModel model =
    Encode.object
        [ ( "screen", encodeScreen model.screen )
        , ( "jeopardyPlaying", Encode.bool model.jeopardyPlaying )
        , ( "now", Encode.float model.now )
        , ( "pending", Encode.list encodePendingEvent model.pending )
        , ( "savedState", model.savedState |> Maybe.map encodePausedState |> Maybe.withDefault Encode.null )
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
    Decode.map7
        (\scr jp n pend ss dk pst ->
            \wci tea ->
                { screen = scr
                , jeopardyPlaying = jp
                , now = n
                , pending = pend
                , savedState = ss
                , dingKey = dk
                , pendingStartTime = pst
                , wsClientId = wci
                , timerEndsAt = tea
                , myUuid = Nothing
                , wsUrl = ""
                }
        )
        (Decode.field "screen" decodeScreen)
        (Decode.field "jeopardyPlaying" Decode.bool)
        (Decode.field "now" Decode.float)
        (Decode.field "pending" (Decode.list decodePendingEvent))
        (Decode.field "savedState" (Decode.nullable decodePausedState))
        (Decode.field "dingKey" Decode.int)
        (Decode.field "pendingStartTime" (Decode.nullable Decode.float))
        |> Decode.andThen
            (\partial ->
                Decode.map2 partial
                    (Decode.field "wsClientId" (Decode.nullable Decode.string))
                    (Decode.field "timerEndsAt" Decode.float)
            )
