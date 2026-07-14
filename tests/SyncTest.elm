module SyncTest exposing (..)

import Expect
import Game.IQTest exposing (FakeFlashPhase(..), IQSkipPhase(..))
import Json.Decode as Decode
import Json.Encode as Encode
import Sync
    exposing
        ( ServerEnvelope(..)
        , clientStateEnvelope
        , decodeFakeFlashPhase
        , decodeIQSkipPhase
        , decodeMsg
        , decodeModel
        , decodeScreen
        , decodeServerEnvelope
        , encodeFakeFlashPhase
        , encodeIQSkipPhase
        , encodeModel
        , encodeMsg
        , encodeScreen
        , iqCaughtEnvelope
        , iqFailedEnvelope
        , iqOfferDeclinedEnvelope
        , iqReadyForDingEnvelope
        , iqResumeEnvelope
        , iqStartCountdownEnvelope
        , quizAdvancedEnvelope
        , quizAnswerSubmittedEnvelope
        , stateRequestEnvelope
        )
import Test exposing (Test, describe, test)
import Types exposing (Model, Msg(..), Screen(..))


roundTripScreen : Screen -> Screen
roundTripScreen scr =
    encodeScreen scr
        |> Decode.decodeValue decodeScreen
        |> Result.withDefault WsErrorScreen


screenRoundTripTests : Test
screenRoundTripTests =
    describe "encodeScreen / decodeScreen round-trip"
        [ test "BlankScreen carries its index" <|
            \_ -> Expect.equal (BlankScreen 3) (roundTripScreen (BlankScreen 3))
        , test "VideoScreen carries index and filename" <|
            \_ -> Expect.equal (VideoScreen 2 "video.mp4") (roundTripScreen (VideoScreen 2 "video.mp4"))
        , test "QuestionScreen carries index and answer text" <|
            \_ -> Expect.equal (QuestionScreen 1 "answer") (roundTripScreen (QuestionScreen 1 "answer"))
        , test "TimedOutScreen" <|
            \_ -> Expect.equal TimedOutScreen (roundTripScreen TimedOutScreen)
        , test "CheckingAnswerScreen nests the next screen" <|
            \_ -> Expect.equal (CheckingAnswerScreen (QuestionScreen 4 "x")) (roundTripScreen (CheckingAnswerScreen (QuestionScreen 4 "x")))
        , test "WinScreen round-trips its text (safe: only ever derived once server-verified)" <|
            \_ -> Expect.equal (WinScreen "hello reward") (roundTripScreen (WinScreen "hello reward"))
        , test "WinScreen decodes a hand-edited textless payload as empty text rather than failing the whole decode" <|
            \_ ->
                Expect.equal
                    (Ok (WinScreen ""))
                    (Decode.decodeValue decodeScreen (Encode.object [ ( "tag", Encode.string "WinScreen" ) ]))
        , test "WsConnectingScreen" <|
            \_ -> Expect.equal WsConnectingScreen (roundTripScreen WsConnectingScreen)
        , test "WsErrorScreen" <|
            \_ -> Expect.equal WsErrorScreen (roundTripScreen WsErrorScreen)
        , test "WsLoadingScreen" <|
            \_ -> Expect.equal WsLoadingScreen (roundTripScreen WsLoadingScreen)
        , test "WrongAnswerScreen carries its index but deliberately drops the reveal text on encode (never persisted)" <|
            \_ -> Expect.equal (WrongAnswerScreen 5 "") (roundTripScreen (WrongAnswerScreen 5 "top secret answer"))
        , test "IQTestScreen carries its state" <|
            \_ ->
                Expect.equal
                    (IQTestScreen { questionIdx = 1, totalDings = 100, pendingSkipOffer = Nothing })
                    (roundTripScreen (IQTestScreen { questionIdx = 1, totalDings = 100, pendingSkipOffer = Nothing }))
        , test "IQTestScreen carries a pending skip offer too" <|
            \_ ->
                Expect.equal
                    (IQTestScreen { questionIdx = 1, totalDings = 100, pendingSkipOffer = Just 200 })
                    (roundTripScreen (IQTestScreen { questionIdx = 1, totalDings = 100, pendingSkipOffer = Just 200 }))
        , test "IQTestScreen's pendingSkipOffer defaults to Nothing for an older persisted row missing the field" <|
            \_ ->
                let
                    oldShapeJson =
                        Encode.object
                            [ ( "tag", Encode.string "IQTestScreen" )
                            , ( "state"
                              , Encode.object
                                    [ ( "questionIdx", Encode.int 1 )
                                    , ( "totalDings", Encode.int 100 )
                                    ]
                              )
                            ]
                in
                Decode.decodeValue decodeScreen oldShapeJson
                    |> Expect.equal (Ok (IQTestScreen { questionIdx = 1, totalDings = 100, pendingSkipOffer = Nothing }))
        , test "IQTestCountdownScreen carries its state" <|
            \_ ->
                Expect.equal
                    (IQTestCountdownScreen { questionIdx = 1, totalDings = 100, countdown = 3 })
                    (roundTripScreen (IQTestCountdownScreen { questionIdx = 1, totalDings = 100, countdown = 3 }))
        , test "IQTestActiveScreen carries its state" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, dingCount = 2, totalDings = 100, isFlashing = True, dingActive = False, fakeFlashActive = True, fakeIsTrap = False, loudPlaying = True }
                in
                Expect.equal (IQTestActiveScreen state) (roundTripScreen (IQTestActiveScreen state))
        , test "FakeFlashCaughtScreen carries its state" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, originalTotal = 100, displayNumerator = 3, displayDenominator = 100, phase = FfText1Hold, skipOffer = Nothing }
                in
                Expect.equal (FakeFlashCaughtScreen state) (roundTripScreen (FakeFlashCaughtScreen state))
        , test "FakeFlashCaughtScreen carries a granted skipOffer too" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, originalTotal = 100, displayNumerator = 3, displayDenominator = 100, phase = FfText1Hold, skipOffer = Just 200 }
                in
                Expect.equal (FakeFlashCaughtScreen state) (roundTripScreen (FakeFlashCaughtScreen state))
        , test "FakeFlashCaughtScreen's skipOffer defaults to Nothing for an older persisted row missing the field" <|
            \_ ->
                let
                    oldShapeJson =
                        Encode.object
                            [ ( "tag", Encode.string "FakeFlashCaughtScreen" )
                            , ( "state"
                              , Encode.object
                                    [ ( "questionIdx", Encode.int 1 )
                                    , ( "originalTotal", Encode.int 100 )
                                    , ( "displayNumerator", Encode.int 3 )
                                    , ( "displayDenominator", Encode.int 100 )
                                    , ( "phase", Encode.string "FfText1Hold" )
                                    ]
                              )
                            ]
                in
                Decode.decodeValue decodeScreen oldShapeJson
                    |> Expect.equal
                        (Ok
                            (FakeFlashCaughtScreen
                                { questionIdx = 1, originalTotal = 100, displayNumerator = 3, displayDenominator = 100, phase = FfText1Hold, skipOffer = Nothing }
                            )
                        )
        , test "IQTestSkipOfferScreen carries its state" <|
            \_ ->
                Expect.equal
                    (IQTestSkipOfferScreen { questionIdx = 2, totalDings = 100, pendingSkipOffer = Nothing })
                    (roundTripScreen (IQTestSkipOfferScreen { questionIdx = 2, totalDings = 100, pendingSkipOffer = Nothing }))
        , test "IQTestSkipAnimScreen carries its state" <|
            \_ ->
                let
                    state =
                        { questionIdx = 2, displayCount = 42, total = 100, phase = SkipTick }
                in
                Expect.equal (IQTestSkipAnimScreen state) (roundTripScreen (IQTestSkipAnimScreen state))
        , test "ConfirmingAnswerScreen nests the next screen" <|
            \_ -> Expect.equal (ConfirmingAnswerScreen (BlankScreen 4)) (roundTripScreen (ConfirmingAnswerScreen (BlankScreen 4)))
        , test "BeginScreen nests the next screen" <|
            \_ -> Expect.equal (BeginScreen (BlankScreen 2)) (roundTripScreen (BeginScreen (BlankScreen 2)))
        , test "an unrecognized tag fails to decode" <|
            \_ ->
                Decode.decodeString decodeScreen """{"tag":"NotAScreen"}"""
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]


fakeFlashPhaseRoundTripTests : Test
fakeFlashPhaseRoundTripTests =
    let
        roundTrip phase =
            encodeFakeFlashPhase phase
                |> Decode.decodeValue decodeFakeFlashPhase
    in
    describe "encodeFakeFlashPhase / decodeFakeFlashPhase round-trip"
        [ test "round-trips every phase" <|
            \_ ->
                [ FfDelay, FfText1In, FfText1Hold, FfText1Out, FfText2In, FfText2Hold, FfText2Out, FfCounterIn, FfTickNumerator, FfTickDelay, FfTickDenominator, FfCounterOut ]
                    |> List.map roundTrip
                    |> Expect.equal
                        (List.map Ok [ FfDelay, FfText1In, FfText1Hold, FfText1Out, FfText2In, FfText2Hold, FfText2Out, FfCounterIn, FfTickNumerator, FfTickDelay, FfTickDenominator, FfCounterOut ])
        , test "rejects an unknown phase string" <|
            \_ ->
                Decode.decodeValue decodeFakeFlashPhase (Encode.string "NotAPhase")
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]


iqSkipPhaseRoundTripTests : Test
iqSkipPhaseRoundTripTests =
    let
        roundTrip phase =
            encodeIQSkipPhase phase
                |> Decode.decodeValue decodeIQSkipPhase
    in
    describe "encodeIQSkipPhase / decodeIQSkipPhase round-trip"
        [ test "round-trips every phase" <|
            \_ ->
                [ SkipCounterIn, SkipTick, SkipCounterOut ]
                    |> List.map roundTrip
                    |> Expect.equal (List.map Ok [ SkipCounterIn, SkipTick, SkipCounterOut ])
        , test "rejects an unknown phase string" <|
            \_ ->
                Decode.decodeValue decodeIQSkipPhase (Encode.string "NotAPhase")
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]


msgRoundTripTests : Test
msgRoundTripTests =
    let
        roundTrip msg =
            encodeMsg msg
                |> Decode.decodeValue decodeMsg
    in
    describe "encodeMsg / decodeMsg round-trip"
        [ test "round-trips every explicitly-encoded Msg variant" <|
            \_ ->
                let
                    msgs =
                        [ Tick 100
                        , PlaySong 2
                        , ShowQuestion 2
                        , TrackEnded "song.mp3"
                        , DingFlashEnd
                        , DingWindowExpired
                        , FakeFlashWindowExpired
                        , FakeFlashCounterTick
                        , FakeFlashNextPhase
                        , StartLoudMusic
                        , WsReconnect
                        ]
                in
                List.map roundTrip msgs |> Expect.equal (List.map Ok msgs)
        , test "a Msg with no dedicated encoding falls back to NoOp" <|
            \_ -> roundTrip AnswerSubmitted |> Expect.equal (Ok NoOp)
        , test "decodeMsg maps an unrecognized tag to NoOp" <|
            \_ -> Decode.decodeString decodeMsg """{"tag":"SomethingUnknown"}""" |> Expect.equal (Ok NoOp)
        ]


iqEnvelopeBuilderTests : Test
iqEnvelopeBuilderTests =
    describe "IQ-test client->server envelope builders"
        [ test "iqStartCountdownEnvelope" <|
            \_ -> Encode.encode 0 iqStartCountdownEnvelope |> Expect.equal """{"payload":"iqStartCountdown","iqStartCountdown":{}}"""
        , test "iqReadyForDingEnvelope" <|
            \_ -> Encode.encode 0 iqReadyForDingEnvelope |> Expect.equal """{"payload":"iqReadyForDing","iqReadyForDing":{}}"""
        , test "iqCaughtEnvelope" <|
            \_ -> Encode.encode 0 iqCaughtEnvelope |> Expect.equal """{"payload":"iqCaught","iqCaught":{}}"""
        , test "iqResumeEnvelope" <|
            \_ -> Encode.encode 0 iqResumeEnvelope |> Expect.equal """{"payload":"iqResume","iqResume":{}}"""
        , test "iqFailedEnvelope" <|
            \_ -> Encode.encode 0 iqFailedEnvelope |> Expect.equal """{"payload":"iqFailed","iqFailed":{}}"""
        , test "iqOfferDeclinedEnvelope" <|
            \_ -> Encode.encode 0 iqOfferDeclinedEnvelope |> Expect.equal """{"payload":"iqOfferDeclined","iqOfferDeclined":{}}"""
        ]


quizEnvelopeBuilderTests : Test
quizEnvelopeBuilderTests =
    describe "quiz client->server envelope builders"
        [ test "quizAdvancedEnvelope carries the idx" <|
            \_ -> Encode.encode 0 (quizAdvancedEnvelope 3) |> Expect.equal """{"payload":"quizAdvanced","quizAdvanced":{"idx":3}}"""
        , test "quizAnswerSubmittedEnvelope carries the idx and answer" <|
            \_ ->
                Encode.encode 0 (quizAnswerSubmittedEnvelope { idx = 2, answer = "Alpha" })
                    |> Expect.equal """{"payload":"quizAnswerSubmitted","quizAnswerSubmitted":{"idx":2,"answer":"Alpha"}}"""
        ]


modelRoundTripTests : Test
modelRoundTripTests =
    let
        model : Model
        model =
            { screen = BlankScreen 2
            , now = 12345
            , pending = [ { fireAt = 1500, msg = ShowQuestion 1 } ]
            , dingKey = 7
            , wsClientId = Just "client-1"
            , timerEndsAt = 54321
            , myUuid = Just "should-not-round-trip"
            , wsUrl = "wss://example.com"
            , questions = []
            , awaitingAnswerResult = True
            , songTimerElapsed = False
            , songEndAcked = False
            }

        decoded =
            encodeModel model
                |> Decode.decodeValue decodeModel
    in
    describe "encodeModel / decodeModel round-trip"
        [ test "round-trips the one persisted field (screen), with no wrapping object" <|
            \_ ->
                case decoded of
                    Ok m ->
                        Expect.equal model.screen m.screen

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "encodeModel is exactly encodeScreen, no extra key" <|
            \_ -> Encode.encode 0 (encodeModel model) |> Expect.equal (Encode.encode 0 (encodeScreen model.screen))
        , test "everything else is session/live-local -- decodeModel always resets it to a fresh-connection default" <|
            \_ ->
                -- wsClientId/myUuid/wsUrl/questions/awaitingAnswerResult/timerEndsAt are
                -- session-local facts decodeModel can't know (Main.elm's ServerStateUpdate
                -- handler preserves the live model's copies instead -- see its own comment).
                -- pending/dingKey/now are purely local live/animation state that never
                -- needs to survive a disconnect with any precision (0/[] is exactly
                -- correct for a freshly (re)connected session).
                case decoded of
                    Ok m ->
                        Expect.equal
                            { myUuid = Nothing, wsUrl = "", questions = [], awaitingAnswerResult = False, timerEndsAt = 0, pending = [], dingKey = 0, now = 0 }
                            { myUuid = m.myUuid, wsUrl = m.wsUrl, questions = m.questions, awaitingAnswerResult = m.awaitingAnswerResult, timerEndsAt = m.timerEndsAt, pending = m.pending, dingKey = m.dingKey, now = m.now }

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        ]


decodeModelDefaultsTests : Test
decodeModelDefaultsTests =
    describe "decodeModel tolerates the brand-new-player/older-row shape"
        [ test "a genuinely brand-new player's \"{}\" decodes to BeginScreen (BlankScreen 0)" <|
            \_ ->
                Decode.decodeString decodeModel "{}"
                    |> Result.map .screen
                    |> Expect.equal (Ok (BeginScreen (BlankScreen 0)))
        , test "a real screen decodes as itself (no wrapping needed)" <|
            \_ ->
                Decode.decodeString decodeModel """{"tag":"BlankScreen","idx":0}"""
                    |> Result.map .screen
                    |> Expect.equal (Ok (BlankScreen 0))
        ]


serverEnvelopeTests : Test
serverEnvelopeTests =
    describe "decodeServerEnvelope"
        [ test "stateUpdate carries the nested json string" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"stateUpdate","stateUpdate":{"json":"{\\"a\\":1}"}}"""
                    |> Expect.equal (Ok (ServerStateUpdate "{\"a\":1}"))
        , test "stateUpdateAck" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"stateUpdateAck"}"""
                    |> Expect.equal (Ok ServerAck)
        , test "winText carries the text" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"winText","winText":{"text":"congrats"}}"""
                    |> Expect.equal (Ok (ServerWinText "congrats"))
        , test "stateRequestRejected carries the reason" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"stateRequestRejected","stateRequestRejected":{"reason":"locked"}}"""
                    |> Expect.equal (Ok (ServerRejected "locked"))
        , test "unknown payload maps to ServerUnknown" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"somethingElse"}"""
                    |> Expect.equal (Ok ServerUnknown)
        , test "authChallenge" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"authChallenge"}"""
                    |> Expect.equal (Ok ServerAuth)
        , test "authResult" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"authResult"}"""
                    |> Expect.equal (Ok ServerAuth)
        , test "iqCountdownTick carries the remaining count" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqCountdownTick","iqCountdownTick":{"remaining":3}}"""
                    |> Expect.equal (Ok (ServerIqCountdownTick 3))
        , test "iqCountdownComplete carries the ding count" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqCountdownComplete","iqCountdownComplete":{"dingCount":5}}"""
                    |> Expect.equal (Ok (ServerIqCountdownComplete 5))
        , test "iqCountdownComplete defaults dingCount to 0 when protobufjs omits it" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqCountdownComplete"}"""
                    |> Expect.equal (Ok (ServerIqCountdownComplete 0))
        , test "iqDing with all fields present" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqDing","iqDing":{"fake":true,"trap":true,"dingCount":5,"totalDings":100}}"""
                    |> Expect.equal (Ok (ServerIqDing { fake = True, trap = True, dingCount = 5, totalDings = 100 }))
        , test "iqDing defaults trap/dingCount/totalDings to false/0 when protobufjs omits them" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqDing","iqDing":{"fake":false}}"""
                    |> Expect.equal (Ok (ServerIqDing { fake = False, trap = False, dingCount = 0, totalDings = 0 }))
        , test "iqStartLoud" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqStartLoud"}"""
                    |> Expect.equal (Ok ServerIqStartLoud)
        , test "iqTestComplete" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqTestComplete"}"""
                    |> Expect.equal (Ok ServerIqTestComplete)
        , test "quizAnswerResult with all fields present" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"quizAnswerResult","quizAnswerResult":{"idx":2,"correct":false,"revealAnswer":"Alpha"}}"""
                    |> Expect.equal (Ok (ServerQuizAnswerResult { idx = 2, correct = False, revealAnswer = "Alpha" }))
        , test "quizAnswerResult defaults correct/revealAnswer to false/\"\" when protobufjs omits them" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"quizAnswerResult","quizAnswerResult":{"idx":0}}"""
                    |> Expect.equal (Ok (ServerQuizAnswerResult { idx = 0, correct = False, revealAnswer = "" }))
        , test "iqOfferDecision with all fields present" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqOfferDecision","iqOfferDecision":{"granted":true,"totalDings":150}}"""
                    |> Expect.equal (Ok (ServerIqOfferDecision { granted = True, totalDings = 150 }))
        , test "iqOfferDecision defaults granted/totalDings to false/0 when protobufjs omits them" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqOfferDecision","iqOfferDecision":{}}"""
                    |> Expect.equal (Ok (ServerIqOfferDecision { granted = False, totalDings = 0 }))
        ]


envelopeBuilderTests : Test
envelopeBuilderTests =
    describe "outgoing envelope builders"
        [ test "stateRequestEnvelope carries the uuid" <|
            \_ ->
                stateRequestEnvelope "abc-123"
                    |> Encode.encode 0
                    |> Expect.equal """{"payload":"stateRequest","stateRequest":{"uuid":"abc-123"}}"""
        , test "clientStateEnvelope wraps an encoded model as a stateUpdate JSON string" <|
            \_ ->
                let
                    model : Model
                    model =
                        { screen = BeginScreen (BlankScreen 0)
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
                in
                clientStateEnvelope model
                    |> Decode.decodeValue (Decode.field "payload" Decode.string)
                    |> Expect.equal (Ok "stateUpdate")
        ]
