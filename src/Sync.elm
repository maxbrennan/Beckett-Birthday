module Sync exposing (..)

import Game.IQTest exposing (..)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Types exposing (..)


-- ── Server Envelope ───────────────────────────────────────────────────────────


type ServerEnvelope
    = ServerStateUpdate String
    | ServerAck
    | ServerWinText String
    | ServerAuth
    | ServerRejected String
    | ServerIqCountdownTick Int
    | ServerIqCountdownComplete Int
    | ServerIqDing { fake : Bool, trap : Bool, dingCount : Int, totalDings : Int }
    | ServerIqStartLoud
    | ServerIqTestComplete
    | ServerQuizAnswerResult { idx : Int, correct : Bool, revealAnswer : String }
    | ServerQuizSongEndedAck Int
    | ServerIqOfferDecision { granted : Bool, totalDings : Int }
    | ServerTimerSync Float
    | ServerTimedOut
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

                    "stateUpdateAck" ->
                        Decode.succeed ServerAck

                    "winText" ->
                        Decode.at [ "winText", "text" ] Decode.string
                            |> Decode.map ServerWinText

                    "authChallenge" ->
                        Decode.succeed ServerAuth

                    "authResult" ->
                        Decode.succeed ServerAuth

                    "stateRequestRejected" ->
                        Decode.at [ "stateRequestRejected", "reason" ] Decode.string
                            |> Decode.map ServerRejected

                    "iqCountdownTick" ->
                        Decode.at [ "iqCountdownTick", "remaining" ] Decode.int
                            |> Decode.map ServerIqCountdownTick

                    "iqCountdownComplete" ->
                        -- protobufjs omits default (0) scalar fields, so dingCount may be
                        -- absent on a fresh test; treat a missing count as 0.
                        Decode.oneOf [ Decode.at [ "iqCountdownComplete", "dingCount" ] Decode.int, Decode.succeed 0 ]
                            |> Decode.map ServerIqCountdownComplete

                    "iqDing" ->
                        Decode.map4
                            (\f t dc td -> ServerIqDing { fake = f, trap = t, dingCount = dc, totalDings = td })
                            (Decode.at [ "iqDing", "fake" ] Decode.bool)
                            -- protobufjs omits default (false) scalar fields, so trap/fake
                            -- may be absent; treat a missing flag as false.
                            (Decode.oneOf [ Decode.at [ "iqDing", "trap" ] Decode.bool, Decode.succeed False ])
                            (Decode.oneOf [ Decode.at [ "iqDing", "dingCount" ] Decode.int, Decode.succeed 0 ])
                            (Decode.oneOf [ Decode.at [ "iqDing", "totalDings" ] Decode.int, Decode.succeed 0 ])

                    "iqStartLoud" ->
                        Decode.succeed ServerIqStartLoud

                    "iqTestComplete" ->
                        Decode.succeed ServerIqTestComplete

                    "quizAnswerResult" ->
                        Decode.map3
                            (\idx correct revealAnswer -> ServerQuizAnswerResult { idx = idx, correct = correct, revealAnswer = revealAnswer })
                            (Decode.at [ "quizAnswerResult", "idx" ] Decode.int)
                            -- protobufjs omits default (false) scalar fields, so
                            -- correct may be absent; treat a missing flag as false.
                            (Decode.oneOf [ Decode.at [ "quizAnswerResult", "correct" ] Decode.bool, Decode.succeed False ])
                            (Decode.oneOf [ Decode.at [ "quizAnswerResult", "revealAnswer" ] Decode.string, Decode.succeed "" ])

                    "quizSongEndedAck" ->
                        Decode.at [ "quizSongEndedAck", "idx" ] Decode.int
                            |> Decode.map ServerQuizSongEndedAck

                    "iqOfferDecision" ->
                        Decode.map2
                            (\granted totalDings -> ServerIqOfferDecision { granted = granted, totalDings = totalDings })
                            -- protobufjs omits default (false) scalar fields, so granted
                            -- may be absent; treat a missing flag as false (denied).
                            (Decode.oneOf [ Decode.at [ "iqOfferDecision", "granted" ] Decode.bool, Decode.succeed False ])
                            (Decode.oneOf [ Decode.at [ "iqOfferDecision", "totalDings" ] Decode.int, Decode.succeed 0 ])

                    "timerSync" ->
                        -- protobufjs omits a scalar field left at its zero value, but
                        -- timerEndsAt is always a large epoch-ms deadline in practice.
                        Decode.oneOf
                            [ Decode.at [ "timerSync", "timerEndsAt" ] Decode.float
                            , Decode.succeed 0
                            ]
                            |> Decode.map ServerTimerSync

                    "timedOut" ->
                        Decode.succeed ServerTimedOut

                    _ ->
                        Decode.succeed ServerUnknown
            )


stateRequestEnvelope : String -> Encode.Value
stateRequestEnvelope uuid =
    Encode.object
        [ ( "payload", Encode.string "stateRequest" )
        , ( "stateRequest", Encode.object [ ( "uuid", Encode.string uuid ) ] )
        ]


-- ── IQ-test client→server envelopes (all payload-less) ──────────────────────────
-- The client never sends a count; the server owns it.


iqStartCountdownEnvelope : Encode.Value
iqStartCountdownEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqStartCountdown" )
        , ( "iqStartCountdown", Encode.object [] )
        ]


iqReadyForDingEnvelope : Encode.Value
iqReadyForDingEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqReadyForDing" )
        , ( "iqReadyForDing", Encode.object [] )
        ]


iqCaughtEnvelope : Encode.Value
iqCaughtEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqCaught" )
        , ( "iqCaught", Encode.object [] )
        ]


-- Sent right after restoring a saved IQ screen from a reconnect, so the server
-- re-arms whatever it paused on disconnect (see Server.elm's resumeIqTimer).
iqResumeEnvelope : Encode.Value
iqResumeEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqResume" )
        , ( "iqResume", Encode.object [] )
        ]


-- "A qualifying fail just happened" -- see Server.elm's decideIqOffer /
-- ClientIqFailed. The server replies with iqOfferDecision (ServerIqOfferDecision).
iqFailedEnvelope : Encode.Value
iqFailedEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqFailed" )
        , ( "iqFailed", Encode.object [] )
        ]


-- "The player declined an outstanding skip offer." Releases the server-held grant
-- (Server.elm's Model.iqOfferGrants) so a subsequent iqStartCountdown is no longer
-- blocked.
iqOfferDeclinedEnvelope : Encode.Value
iqOfferDeclinedEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqOfferDeclined" )
        , ( "iqOfferDeclined", Encode.object [] )
        ]


-- Tells the server "I just passed question idx" (correct answer, or an IQ-test
-- penalty clearing after a wrong one). The server, not this message, decides
-- whether this means the game is won -- see Server.elm's acceptQuizAdvance/
-- quizJustCompleted.
quizAdvancedEnvelope : Int -> Encode.Value
quizAdvancedEnvelope idx =
    Encode.object
        [ ( "payload", Encode.string "quizAdvanced" )
        , ( "quizAdvanced", Encode.object [ ( "idx", Encode.int idx ) ] )
        ]


-- "I typed this answer for question idx" -- the server validates it against
-- config/app-config.json's quizQuestions field (never sent to the client) and
-- replies with a quizAnswerResult message (see ServerQuizAnswerResult above).
quizAnswerSubmittedEnvelope : { idx : Int, answer : String } -> Encode.Value
quizAnswerSubmittedEnvelope { idx, answer } =
    Encode.object
        [ ( "payload", Encode.string "quizAnswerSubmitted" )
        , ( "quizAnswerSubmitted", Encode.object [ ( "idx", Encode.int idx ), ( "answer", Encode.string answer ) ] )
        ]


-- "The song/video for question idx just finished playing." The server tracks
-- this and requires it before accepting a submitted answer for the same idx --
-- see ServerQuizSongEndedAck above / Server.elm's ClientQuizSongEnded.
quizSongEndedEnvelope : Int -> Encode.Value
quizSongEndedEnvelope idx =
    Encode.object
        [ ( "payload", Encode.string "quizSongEnded" )
        , ( "quizSongEnded", Encode.object [ ( "idx", Encode.int idx ) ] )
        ]


-- ── JSON Encoders ─────────────────────────────────────────────────────────────


encodeMaybeString : Maybe String -> Encode.Value
encodeMaybeString =
    Maybe.map Encode.string >> Maybe.withDefault Encode.null


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


encodeIQSkipPhase : IQSkipPhase -> Encode.Value
encodeIQSkipPhase phase =
    Encode.string
        (case phase of
            SkipCounterIn -> "SkipCounterIn"
            SkipTick -> "SkipTick"
            SkipCounterOut -> "SkipCounterOut"
        )


encodeIQSkipAnimState : IQSkipAnimState -> Encode.Value
encodeIQSkipAnimState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "displayCount", Encode.int s.displayCount )
        , ( "total", Encode.int s.total )
        , ( "phase", encodeIQSkipPhase s.phase )
        ]


encodeIQTestScreenState : IQTestScreenState -> Encode.Value
encodeIQTestScreenState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "totalDings", Encode.int s.totalDings )
        , ( "pendingSkipOffer", s.pendingSkipOffer |> Maybe.map Encode.int |> Maybe.withDefault Encode.null )
        ]


encodeIQTestCountdownState : IQTestCountdownState -> Encode.Value
encodeIQTestCountdownState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "totalDings", Encode.int s.totalDings )
        , ( "countdown", Encode.int s.countdown )
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
        , ( "fakeIsTrap", Encode.bool s.fakeIsTrap )
        , ( "loudPlaying", Encode.bool s.loudPlaying )
        ]


encodeFakeFlashCaughtState : FakeFlashCaughtState -> Encode.Value
encodeFakeFlashCaughtState s =
    Encode.object
        [ ( "questionIdx", Encode.int s.questionIdx )
        , ( "originalTotal", Encode.int s.originalTotal )
        , ( "displayNumerator", Encode.int s.displayNumerator )
        , ( "displayDenominator", Encode.int s.displayDenominator )
        , ( "phase", encodeFakeFlashPhase s.phase )
        , ( "skipOffer", s.skipOffer |> Maybe.map Encode.int |> Maybe.withDefault Encode.null )
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

        BlankScreen idx ->
            Encode.object [ ( "tag", Encode.string "BlankScreen" ), ( "idx", Encode.int idx ) ]

        VideoScreen idx s ->
            Encode.object [ ( "tag", Encode.string "VideoScreen" ), ( "idx", Encode.int idx ), ( "s", Encode.string s ) ]

        QuestionScreen idx s ->
            Encode.object [ ( "tag", Encode.string "QuestionScreen" ), ( "idx", Encode.int idx ), ( "s", Encode.string s ) ]

        WrongAnswerScreen idx _ ->
            -- Deliberately drop the reveal text: it must never be written into
            -- persisted state (builds.json), same as WinScreen's text. The
            -- server derives this whole screen family down to BlankScreen
            -- progress anyway (see Server.elm's deriveQuizScreen), so the text
            -- was never going to survive a resume.
            Encode.object [ ( "tag", Encode.string "WrongAnswerScreen" ), ( "idx", Encode.int idx ) ]

        IQTestScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestScreen" ), ( "state", encodeIQTestScreenState state ) ]

        IQTestCountdownScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestCountdownScreen" ), ( "state", encodeIQTestCountdownState state ) ]

        IQTestActiveScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestActiveScreen" ), ( "state", encodeIQTestState state ) ]

        FakeFlashCaughtScreen state ->
            Encode.object [ ( "tag", Encode.string "FakeFlashCaughtScreen" ), ( "state", encodeFakeFlashCaughtState state ) ]

        IQTestSkipOfferScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestSkipOfferScreen" ), ( "state", encodeIQTestScreenState state ) ]

        IQTestSkipAnimScreen state ->
            Encode.object [ ( "tag", Encode.string "IQTestSkipAnimScreen" ), ( "state", encodeIQSkipAnimState state ) ]

        WinScreen text ->
            -- Round-trips normally now: the server only ever derives/persists this
            -- with the real, already-verified win text embedded (see Server.elm's
            -- deriveWinScreen), so there's nothing unsafe about it surviving a resume.
            Encode.object [ ( "tag", Encode.string "WinScreen" ), ( "text", Encode.string text ) ]

        TimedOutScreen ->
            Encode.object [ ( "tag", Encode.string "TimedOutScreen" ) ]

        CheckingAnswerScreen nextScreen ->
            Encode.object [ ( "tag", Encode.string "CheckingAnswerScreen" ), ( "nextScreen", encodeScreen nextScreen ) ]

        ConfirmingAnswerScreen nextScreen ->
            Encode.object [ ( "tag", Encode.string "ConfirmingAnswerScreen" ), ( "nextScreen", encodeScreen nextScreen ) ]

        BeginScreen nextScreen ->
            Encode.object [ ( "tag", Encode.string "BeginScreen" ), ( "nextScreen", encodeScreen nextScreen ) ]


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

        StartLoudMusic ->
            Encode.object [ ( "tag", Encode.string "StartLoudMusic" ) ]

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


clientStateEnvelope : Model -> Encode.Value
clientStateEnvelope model =
    Encode.object
        [ ( "payload", Encode.string "stateUpdate" )
        , ( "stateUpdate", Encode.object [ ( "json", Encode.string (Encode.encode 0 (encodeModel model)) ) ] )
        ]


{-| The only thing that ever round-trips through the server's persisted state
(`builds.json`) is the screen itself (now always reconstructable from the
server's own authoritative state -- see Server.elm's deriveIqScreen/
deriveQuizScreen/deriveTimedOutScreen -- and, while the player hasn't pressed
Begin yet, wrapped in `BeginScreen`). There's no separate wrapper object: the
persisted/wire value *is* `encodeScreen model.screen` directly. Every other
Model field is either session-local (`wsClientId`, `myUuid`, `wsUrl`,
`questions`, `timerEndsAt`, `awaitingAnswerResult`) or purely local
live/animation state (`now`, `pending`, `dingKey`) that's never read by the
server and always resets fresh on connect -- see decodeModel.
-}
encodeModel : Model -> Encode.Value
encodeModel model =
    encodeScreen model.screen


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


decodeIQSkipPhase : Decoder IQSkipPhase
decodeIQSkipPhase =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "SkipCounterIn" -> Decode.succeed SkipCounterIn
                    "SkipTick" -> Decode.succeed SkipTick
                    "SkipCounterOut" -> Decode.succeed SkipCounterOut
                    _ -> Decode.fail ("Unknown IQSkipPhase: " ++ s)
            )


decodeIQSkipAnimState : Decoder IQSkipAnimState
decodeIQSkipAnimState =
    Decode.map4
        (\qi dc t ph -> { questionIdx = qi, displayCount = dc, total = t, phase = ph })
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "displayCount" Decode.int)
        (Decode.field "total" Decode.int)
        (Decode.field "phase" decodeIQSkipPhase)


decodeIQTestScreenState : Decoder IQTestScreenState
decodeIQTestScreenState =
    Decode.map2
        (\qi td ->
            \pendingSkipOffer -> { questionIdx = qi, totalDings = td, pendingSkipOffer = pendingSkipOffer }
        )
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "totalDings" Decode.int)
        |> Decode.andThen
            (\partial ->
                -- older persisted rows predate this field; treat missing as Nothing.
                Decode.map partial
                    (Decode.oneOf [ Decode.field "pendingSkipOffer" (Decode.nullable Decode.int), Decode.succeed Nothing ])
            )


decodeIQTestCountdownState : Decoder IQTestCountdownState
decodeIQTestCountdownState =
    Decode.map3
        (\qi td cd -> { questionIdx = qi, totalDings = td, countdown = cd })
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "totalDings" Decode.int)
        (Decode.field "countdown" Decode.int)


decodeIQTestState : Decoder IQTestState
decodeIQTestState =
    Decode.map8
        (\qi dc td isF dA ffA fit lP ->
            { questionIdx = qi, dingCount = dc, totalDings = td, isFlashing = isF
            , dingActive = dA, fakeFlashActive = ffA, fakeIsTrap = fit, loudPlaying = lP
            }
        )
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "dingCount" Decode.int)
        (Decode.field "totalDings" Decode.int)
        (Decode.field "isFlashing" Decode.bool)
        (Decode.field "dingActive" Decode.bool)
        (Decode.field "fakeFlashActive" Decode.bool)
        (Decode.field "fakeIsTrap" Decode.bool)
        (Decode.field "loudPlaying" Decode.bool)


decodeFakeFlashCaughtState : Decoder FakeFlashCaughtState
decodeFakeFlashCaughtState =
    Decode.map5
        (\qi ot dn dd ph ->
            \skipOffer ->
                { questionIdx = qi, originalTotal = ot, displayNumerator = dn, displayDenominator = dd, phase = ph, skipOffer = skipOffer }
        )
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "originalTotal" Decode.int)
        (Decode.field "displayNumerator" Decode.int)
        (Decode.field "displayDenominator" Decode.int)
        (Decode.field "phase" decodeFakeFlashPhase)
        |> Decode.andThen
            (\partial ->
                -- older persisted rows predate this field; treat missing as Nothing (no
                -- decision yet/denied).
                Decode.map partial
                    (Decode.oneOf [ Decode.field "skipOffer" (Decode.nullable Decode.int), Decode.succeed Nothing ])
            )


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
                        -- Text is not persisted (see encodeScreen); a disconnect
                        -- here resets to BeginScreen before it could ever matter.
                        Decode.map (\idx -> WrongAnswerScreen idx "") (Decode.field "idx" Decode.int)

                    "IQTestScreen" ->
                        Decode.map IQTestScreen (Decode.field "state" decodeIQTestScreenState)

                    "IQTestCountdownScreen" ->
                        Decode.map IQTestCountdownScreen (Decode.field "state" decodeIQTestCountdownState)

                    "IQTestActiveScreen" ->
                        Decode.map IQTestActiveScreen (Decode.field "state" decodeIQTestState)

                    "FakeFlashCaughtScreen" ->
                        Decode.map FakeFlashCaughtScreen (Decode.field "state" decodeFakeFlashCaughtState)

                    "IQTestSkipOfferScreen" ->
                        Decode.map IQTestSkipOfferScreen (Decode.field "state" decodeIQTestScreenState)

                    "IQTestSkipAnimScreen" ->
                        Decode.map IQTestSkipAnimScreen (Decode.field "state" decodeIQSkipAnimState)

                    "WinScreen" ->
                        Decode.map WinScreen
                            (Decode.oneOf [ Decode.field "text" Decode.string, Decode.succeed "" ])

                    "TimedOutScreen" ->
                        Decode.succeed TimedOutScreen

                    "CheckingAnswerScreen" ->
                        Decode.map CheckingAnswerScreen (Decode.field "nextScreen" decodeScreen)

                    "ConfirmingAnswerScreen" ->
                        Decode.map ConfirmingAnswerScreen (Decode.field "nextScreen" decodeScreen)

                    "BeginScreen" ->
                        Decode.map BeginScreen (Decode.field "nextScreen" decodeScreen)

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

                    "StartLoudMusic" ->
                        Decode.succeed StartLoudMusic

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


{-| Tolerant of both a genuinely brand-new player's `entry.state == Nothing`
(the server sends `{}` -- see Server.elm's ClientStateRequest) and any
older-shape row that predates this field: `screen` defaults to
`BeginScreen (BlankScreen 0)` when the value can't be decoded as a `Screen` at
all, rather than requiring the server to synthesize a full default state for
the empty case. This single default is what makes the fresh-player double-audio
bug structurally impossible -- there's no separate `isBeginScreen` flag that
could independently disagree with `screen`.

`now`/`pending`/`dingKey` reset to their fresh-connection defaults here rather
than round-tripping: they're purely local live/animation state, same as
`myUuid`/`wsUrl`/`questions`/`awaitingAnswerResult`/`timerEndsAt` below.
`timerEndsAt` is deliberately not decoded here: the session deadline is
server-owned (see RegistryEntry.timerEndsAt / timerSyncEnvelope) and delivered
only via the dedicated ServerTimerSync message. The caller preserves the
model's live `wsClientId`/`myUuid`/`wsUrl`/`questions`/`timerEndsAt` across this
decode (see Main.elm's ServerStateUpdate handler).
-}
decodeModel : Decoder Model
decodeModel =
    Decode.map
        (\scr ->
            { screen = scr
            , now = 0
            , pending = []
            , dingKey = 0
            , wsClientId = Nothing
            , timerEndsAt = 0
            , myUuid = Nothing
            , wsUrl = ""
            , questions = []
            , awaitingAnswerResult = False
            , songTimerElapsed = False
            , songEndAcked = False
            }
        )
        (Decode.oneOf [ decodeScreen, Decode.succeed (BeginScreen (BlankScreen 0)) ])
