module MainTest exposing (..)

import Expect
import Game.IQTest exposing (FakeFlashPhase(..), IQSkipAnimState, IQSkipPhase(..), IQTestState, iqLoudDelay, iqQuestionCount)
import Json.Encode as Encode
import Main exposing (decodeReadDirResult, decodeReadFileResult, everySecond, init, needsFakeFlashKick, pauseMusic, resumeCmd, resumePlaySongTarget, sendWs, subscriptions, tickFromPosix, update)
import Sync
import Test exposing (Test, describe, test)
import Time
import Types exposing (Model, Msg(..), Screen(..))


stateUpdateEnvelope : String -> String
stateUpdateEnvelope innerJson =
    Encode.encode 0
        (Encode.object
            [ ( "payload", Encode.string "stateUpdate" )
            , ( "stateUpdate", Encode.object [ ( "json", Encode.string innerJson ) ] )
            ]
        )


validModelJson : String
validModelJson =
    """{"tag":"BlankScreen","idx":0}"""


decisionEnvelope : Bool -> Int -> String
decisionEnvelope granted totalDings =
    Encode.encode 0
        (Encode.object
            [ ( "payload", Encode.string "iqOfferDecision" )
            , ( "iqOfferDecision", Encode.object [ ( "granted", Encode.bool granted ), ( "totalDings", Encode.int totalDings ) ] )
            ]
        )


baseModel : Model
baseModel =
    { screen = BlankScreen 0
    , now = 1000
    , pending = []
    , dingKey = 0
    , wsClientId = Just "old-ws-id"
    , timerEndsAt = 0
    , myUuid = Just "uuid1"
    , wsUrl = "wss://example.test"
    , questions = [ "song0.mp3", "video1.mp4" ]
    , awaitingAnswerResult = False
    , songTimerElapsed = False
    , songEndAcked = False
    }


iqActiveState : IQTestState
iqActiveState =
    { questionIdx = 0
    , dingCount = 0
    , totalDings = iqQuestionCount
    , isFlashing = False
    , dingActive = False
    , fakeFlashActive = False
    , fakeIsTrap = False
    , loudPlaying = False
    }


pendingReconnectFireAt : Model -> Maybe Float
pendingReconnectFireAt model =
    model.pending
        |> List.filter (\e -> e.msg == WsReconnect)
        |> List.map .fireAt
        |> List.head


pendingStartLoudMusicFireAt : Model -> Maybe Float
pendingStartLoudMusicFireAt model =
    model.pending
        |> List.filter (\e -> e.msg == StartLoudMusic)
        |> List.map .fireAt
        |> List.head


suite : Test
suite =
    describe "WsDisconnected reconnect throttling (issue #51)"
        [ test "disconnecting from an active screen throttles the reconnect via scheduleReconnect" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = BlankScreen 0 }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal WsConnectingScreen
                    , \m -> m.wsClientId |> Expect.equal Nothing
                    , \m -> pendingReconnectFireAt m |> Expect.equal (Just (baseModel.now + 3000))
                    ]
                    result
        , test "disconnecting from WsErrorScreen also throttles the reconnect, instead of retrying immediately" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = WsErrorScreen }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal WsConnectingScreen
                    , \m -> m.wsClientId |> Expect.equal Nothing
                    , \m -> pendingReconnectFireAt m |> Expect.equal (Just (baseModel.now + 3000))
                    ]
                    result
        , test "disconnecting while already on WsConnectingScreen dedupes to a single pending reconnect" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = WsConnectingScreen }
                in
                result.pending
                    |> List.filter (\e -> e.msg == WsReconnect)
                    |> List.length
                    |> Expect.equal 1
        ]


tickSuite : Test
tickSuite =
    describe "Tick"
        [ test "fires a due pending event and drops it from pending" <|
            \_ ->
                let
                    model =
                        { baseModel
                            | screen = BlankScreen 0
                            , songEndAcked = True
                            , pending = [ { fireAt = 900, msg = ShowQuestion 0 } ]
                        }

                    ( result, _ ) =
                        update (Tick 1000) model
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (QuestionScreen 0 "")
                    , \m -> m.pending |> Expect.equal []
                    ]
                    result
        ]


beginPressedSuite : Test
beginPressedSuite =
    describe "BeginPressed"
        [ test "starting on an audio slide unwraps BeginScreen; autoplay handles the song, no PlaySong needed" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed { baseModel | screen = BeginScreen (BlankScreen 0) }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 0)
                    , \m -> m.pending |> Expect.equal []
                    ]
                    result
        , test "starting on a video slide schedules its PlaySong kick" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed { baseModel | screen = BeginScreen (BlankScreen 1) }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 1)
                    , \m -> m.pending |> List.map .msg |> Expect.equal [ PlaySong 1 ]
                    ]
                    result
        , test "resuming a mid-game screen just unwraps BeginScreen -- the inner screen is already whatever the server derived" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed
                            { baseModel | screen = BeginScreen (IQTestScreen { questionIdx = 1, totalDings = iqQuestionCount, pendingSkipOffer = Nothing }) }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 1, totalDings = iqQuestionCount, pendingSkipOffer = Nothing })
        , test "clears any stray leftover local scheduling defensively" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed
                            { baseModel
                                | screen = BeginScreen (BlankScreen 0)
                                , pending = [ { fireAt = 999, msg = DingFlashEnd } ]
                            }
                in
                result.pending |> Expect.equal []
        , test "pressing Begin while not on BeginScreen is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)

        -- Regression coverage: a saved QuestionScreen resumes directly onto the
        -- answer input (no BlankScreen, no song replay, no fresh TrackEnded), so
        -- without this the server's quizSongEnded confirmation for this idx --
        -- cleared on every connect -- would never be re-established, and the
        -- player could never submit an answer again. See resumeCmd.
        , test "resuming onto a QuestionScreen re-reports quizSongEnded so the answer gate stays satisfied" <|
            \_ ->
                let
                    input =
                        { baseModel | screen = BeginScreen (QuestionScreen 1 "half-typed") }

                    ( result, cmd ) =
                        update BeginPressed input
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (QuestionScreen 1 "half-typed")
                    , \_ -> cmd |> Expect.equal (Cmd.batch [ pauseMusic "jeopardy-audio", sendWs input (Sync.quizSongEndedEnvelope 1) ])
                    ]
                    result
        ]


resumeCmdSuite : Test
resumeCmdSuite =
    describe "resumeCmd"
        [ test "a saved QuestionScreen re-reports quizSongEnded for its idx" <|
            \_ ->
                resumeCmd baseModel (QuestionScreen 3 "")
                    |> Expect.equal (sendWs baseModel (Sync.quizSongEndedEnvelope 3))
        , test "a saved BlankScreen sends nothing (the song replays and re-triggers TrackEnded)" <|
            \_ ->
                resumeCmd baseModel (BlankScreen 0) |> Expect.equal Cmd.none
        ]


playSongSuite : Test
playSongSuite =
    describe "PlaySong"
        [ test "switches to a video screen for a video question" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (PlaySong 1) { baseModel | screen = BlankScreen 1 }
                in
                result.screen |> Expect.equal (VideoScreen 1 "video1.mp4")
        , test "leaves a non-video question's screen untouched" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (PlaySong 0) { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "ignores a stale PlaySong for a different index" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (PlaySong 1) { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


trackEndedSuite : Test
trackEndedSuite =
    describe "TrackEnded"
        [ test "matching the current blank screen's song schedules ShowQuestion, resets the rendezvous flags, and reports to the server" <|
            \_ ->
                let
                    ( result, cmd ) =
                        update (TrackEnded "song0.mp3")
                            { baseModel | screen = BlankScreen 0, songTimerElapsed = True, songEndAcked = True }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 0)
                    , \m -> m.pending |> List.map .msg |> Expect.equal [ ShowQuestion 0 ]
                    , \m -> m.songTimerElapsed |> Expect.equal False
                    , \m -> m.songEndAcked |> Expect.equal False
                    , \_ -> cmd |> Expect.equal (sendWs baseModel (Sync.quizSongEndedEnvelope 0))
                    ]
                    result
        , test "a video's own track ending advances to its blank screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "video1.mp4") { baseModel | screen = VideoScreen 1 "video1.mp4" }
                in
                result.screen |> Expect.equal (BlankScreen 1)
        , test "the jeopardy theme ending on the begin screen is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "jeopardy-theme.mp3") { baseModel | screen = BeginScreen (BlankScreen 0) }
                in
                result.screen |> Expect.equal (BeginScreen (BlankScreen 0))
        , test "the jeopardy theme ending elsewhere is also a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "jeopardy-theme.mp3") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


answerSubmittedSuite : Test
answerSubmittedSuite =
    describe "AnswerSubmitted"
        [ test "sends the answer to the server and marks the request as awaiting a result" <|
            \_ ->
                let
                    ( result, _ ) =
                        update AnswerSubmitted { baseModel | screen = QuestionScreen 0 "Alpha" }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (QuestionScreen 0 "Alpha")
                    , \m -> m.awaitingAnswerResult |> Expect.equal True
                    ]
                    result
        , test "a duplicate submit while already awaiting a result is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update AnswerSubmitted { baseModel | screen = QuestionScreen 0 "Alpha", awaitingAnswerResult = True }
                in
                result |> Expect.equal { baseModel | screen = QuestionScreen 0 "Alpha", awaitingAnswerResult = True }
        ]


serverQuizAnswerResultSuite : Test
serverQuizAnswerResultSuite =
    let
        resultEnvelope : { idx : Int, correct : Bool, revealAnswer : String } -> String
        resultEnvelope { idx, correct, revealAnswer } =
            Encode.encode 0
                (Encode.object
                    [ ( "payload", Encode.string "quizAnswerResult" )
                    , ( "quizAnswerResult"
                      , Encode.object
                            [ ( "idx", Encode.int idx )
                            , ( "correct", Encode.bool correct )
                            , ( "revealAnswer", Encode.string revealAnswer )
                            ]
                      )
                    ]
                )
    in
    describe "ServerQuizAnswerResult (via WsDataReceived)"
        [ test "a correct answer with a following question moves on" <|
            \_ ->
                let
                    ( result, _ ) =
                        update
                            (WsDataReceived (resultEnvelope { idx = 0, correct = True, revealAnswer = "" }))
                            { baseModel | screen = QuestionScreen 0 "Alpha", awaitingAnswerResult = True }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (CheckingAnswerScreen (BlankScreen 1))
                    , \m -> m.pending |> List.map .msg |> Expect.equal [ PlaySong 1 ]
                    , \m -> m.awaitingAnswerResult |> Expect.equal False
                    ]
                    result
        , test "a correct answer on the last question wins" <|
            \_ ->
                let
                    ( result, _ ) =
                        update
                            (WsDataReceived (resultEnvelope { idx = 1, correct = True, revealAnswer = "" }))
                            { baseModel | screen = QuestionScreen 1 "Beta", awaitingAnswerResult = True }
                in
                result.screen |> Expect.equal (CheckingAnswerScreen (WinScreen ""))
        , test "an incorrect answer shows the wrong-answer screen with the server's reveal text" <|
            \_ ->
                let
                    ( result, _ ) =
                        update
                            (WsDataReceived (resultEnvelope { idx = 0, correct = False, revealAnswer = "Alpha" }))
                            { baseModel | screen = QuestionScreen 0 "nope", awaitingAnswerResult = True }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (WrongAnswerScreen 0 "Alpha")
                    , \m -> m.awaitingAnswerResult |> Expect.equal False
                    ]
                    result
        , test "a result for a stale idx (already moved on) is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update
                            (WsDataReceived (resultEnvelope { idx = 0, correct = True, revealAnswer = "" }))
                            { baseModel | screen = QuestionScreen 1 "Beta", awaitingAnswerResult = True }
                in
                result.screen |> Expect.equal (QuestionScreen 1 "Beta")
        , test "ignored off a question screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (resultEnvelope { idx = 0, correct = True, revealAnswer = "" })) { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


spaceBarPressedSuite : Test
spaceBarPressedSuite =
    describe "SpaceBarPressed"
        [ test "catching the trap starts the fake-flash cutscene" <|
            \_ ->
                let
                    state =
                        { iqActiveState | fakeFlashActive = True, fakeIsTrap = True, dingCount = 3, totalDings = 50 }

                    ( result, _ ) =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen state }
                in
                result.screen
                    |> Expect.equal
                        (FakeFlashCaughtScreen
                            { questionIdx = 0, originalTotal = 50, displayNumerator = 3, displayDenominator = 50, phase = FfDelay, skipOffer = Nothing }
                        )
        , test "pressing a 50%-phase fake freezes on the active screen (flags cleared) and reports the fail" <|
            \_ ->
                let
                    state =
                        { iqActiveState | fakeFlashActive = True, fakeIsTrap = False, totalDings = 42 }

                    ( result, cmd ) =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen state }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (IQTestActiveScreen { state | isFlashing = False, dingActive = False, fakeFlashActive = False })
                    , \_ -> cmd |> Expect.equal (sendWs baseModel Sync.iqFailedEnvelope)
                    ]
                    ()
        , test "clearing a real ding updates the optimistic count" <|
            \_ ->
                let
                    state =
                        { iqActiveState | dingActive = True, dingCount = 2, totalDings = iqQuestionCount }

                    ( result, _ ) =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen state }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { state | dingActive = False, dingCount = 3 })
        , test "pressing with nothing active freezes on the active screen (flags cleared) and reports the fail" <|
            \_ ->
                let
                    state =
                        { iqActiveState | totalDings = 7 }

                    ( result, cmd ) =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen state }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (IQTestActiveScreen { state | isFlashing = False, dingActive = False, fakeFlashActive = False })
                    , \_ -> cmd |> Expect.equal (sendWs baseModel Sync.iqFailedEnvelope)
                    ]
                    ()
        ]


fakeFlashNextPhaseSuite : Test
fakeFlashNextPhaseSuite =
    describe "FakeFlashNextPhase"
        [ test "advances through the linear phase table" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfDelay, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | phase = FfText1In })
        , test "FfCounterIn starts the ticking counter" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfCounterIn, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | phase = FfTickNumerator })
        , test "FfCounterOut exits back to the IQ begin screen with the doubled count, when no skip offer was granted" <|
            \_ ->
                let
                    state =
                        { questionIdx = 3, originalTotal = 10, displayNumerator = 0, displayDenominator = 20, phase = FfCounterOut, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 3, totalDings = 20, pendingSkipOffer = Nothing })
        , test "FfCounterOut lands on the skip-offer screen instead, when the server already granted it" <|
            \_ ->
                let
                    state =
                        { questionIdx = 3, originalTotal = 10, displayNumerator = 0, displayDenominator = 20, phase = FfCounterOut, skipOffer = Just 20 }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (IQTestSkipOfferScreen { questionIdx = 3, totalDings = 20, pendingSkipOffer = Nothing })
        ]


wsSyncTickSuite : Test
wsSyncTickSuite =
    describe "WsSyncTick"
        [ test "with a live connection, promotes a CheckingAnswerScreen to ConfirmingAnswerScreen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsSyncTick { baseModel | wsClientId = Just "ws1", screen = CheckingAnswerScreen (BlankScreen 0) }
                in
                result.screen |> Expect.equal (ConfirmingAnswerScreen (BlankScreen 0))
        , test "with no connection, resolves a CheckingAnswerScreen straight through" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsSyncTick { baseModel | wsClientId = Nothing, screen = CheckingAnswerScreen (BlankScreen 0) }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "with a live connection on WsLoadingScreen, does nothing" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsSyncTick { baseModel | wsClientId = Just "ws1", screen = WsLoadingScreen }
                in
                result.screen |> Expect.equal WsLoadingScreen
        , test "with a live connection on WsConnectingScreen, does nothing" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsSyncTick { baseModel | wsClientId = Just "ws1", screen = WsConnectingScreen }
                in
                result.screen |> Expect.equal WsConnectingScreen
        , test "with a live connection on WsErrorScreen, does nothing" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsSyncTick { baseModel | wsClientId = Just "ws1", screen = WsErrorScreen }
                in
                result.screen |> Expect.equal WsErrorScreen
        ]


initSuite : Test
initSuite =
    describe "init"
        [ test "starts on WsConnectingScreen with a fresh model" <|
            \_ ->
                let
                    ( model, _ ) =
                        init "wss://example.test"
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal WsConnectingScreen
                    , \m -> m.wsUrl |> Expect.equal "wss://example.test"
                    , \m -> m.now |> Expect.equal 0
                    , \m -> m.myUuid |> Expect.equal Nothing
                    ]
                    model
        ]


tickFromPosixSuite : Test
tickFromPosixSuite =
    describe "tickFromPosix"
        [ test "converts a Posix into a Tick with millisecond precision" <|
            \_ -> tickFromPosix (Time.millisToPosix 12345) |> Expect.equal (Tick 12345)
        ]


everySecondSuite : Test
everySecondSuite =
    describe "everySecond"
        [ test "always produces WsSyncTick" <|
            \_ -> everySecond (Time.millisToPosix 0) |> Expect.equal WsSyncTick
        ]


decodeReadFileResultSuite : Test
decodeReadFileResultSuite =
    -- app-uuid.json is the only file left on this port -- the quiz no longer reads
    -- any config/ JSON client-side at all (see #54/#70's review); song discovery
    -- moved to decodeReadDirResult below.
    describe "decodeReadFileResult"
        [ test "a valid uuid field yields UuidLoaded (Just uuid)" <|
            \_ ->
                decodeReadFileResult { path = "app-uuid.json", contents = Just """{"uuid":"abc-123"}""", error = Nothing }
                    |> Expect.equal (UuidLoaded (Just "abc-123"))
        , test "malformed contents yields UuidLoaded Nothing" <|
            \_ ->
                decodeReadFileResult { path = "app-uuid.json", contents = Just "not json", error = Nothing }
                    |> Expect.equal (UuidLoaded Nothing)
        , test "no contents yields UuidLoaded Nothing" <|
            \_ ->
                decodeReadFileResult { path = "app-uuid.json", contents = Nothing, error = Just "not found" }
                    |> Expect.equal (UuidLoaded Nothing)
        ]


decodeReadDirResultSuite : Test
decodeReadDirResultSuite =
    describe "decodeReadDirResult"
        [ test "orders assets/songs/ files numerically into QuestionsLoaded" <|
            \_ ->
                decodeReadDirResult { path = "assets/songs", files = [ "1.mp3", "0.mp3" ], error = Nothing }
                    |> Expect.equal (QuestionsLoaded [ "0.mp3", "1.mp3" ])
        , test "drops non-numeric entries (e.g. .DS_Store)" <|
            \_ ->
                decodeReadDirResult { path = "assets/songs", files = [ "0.mp3", ".DS_Store" ], error = Nothing }
                    |> Expect.equal (QuestionsLoaded [ "0.mp3" ])
        , test "an unreadable directory yields no questions" <|
            \_ ->
                decodeReadDirResult { path = "assets/songs", files = [], error = Just "boom" }
                    |> Expect.equal (QuestionsLoaded [])
        ]


subscriptionsSuite : Test
subscriptionsSuite =
    describe "subscriptions"
        [ test "builds a subscription set on an active IQ test screen" <|
            \_ ->
                let
                    _ =
                        subscriptions { baseModel | screen = IQTestActiveScreen iqActiveState }
                in
                Expect.pass
        , test "builds a subscription set off the IQ test screen" <|
            \_ ->
                let
                    _ =
                        subscriptions { baseModel | screen = BlankScreen 0 }
                in
                Expect.pass
        ]


playSongMoreSuite : Test
playSongMoreSuite =
    describe "PlaySong (remaining branches)"
        [ test "no question at this index leaves the screen untouched" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (PlaySong 5) { baseModel | screen = BlankScreen 5 }
                in
                result.screen |> Expect.equal (BlankScreen 5)
        , test "a screen that isn't blank-wrapped is untouched" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (PlaySong 0) { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


trackEndedMoreSuite : Test
trackEndedMoreSuite =
    describe "TrackEnded (remaining branches)"
        [ test "a non-matching screen/song is untouched" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "song0.mp3") { baseModel | screen = QuestionScreen 0 "x" }
                in
                result.screen |> Expect.equal (QuestionScreen 0 "x")
        ]


showQuestionSuite : Test
showQuestionSuite =
    describe "ShowQuestion"
        [ test "matching BlankScreen with the ack already in reveals the question immediately" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (ShowQuestion 0) { baseModel | screen = BlankScreen 0, songEndAcked = True }
                in
                result.screen |> Expect.equal (QuestionScreen 0 "")
        , test "matching BlankScreen without the ack yet only records that the timer elapsed" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (ShowQuestion 0) { baseModel | screen = BlankScreen 0, songEndAcked = False }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 0)
                    , \m -> m.songTimerElapsed |> Expect.equal True
                    ]
                    result
        , test "a stale ShowQuestion for a different index is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (ShowQuestion 1) { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "ignored off a blank screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (ShowQuestion 0) { baseModel | screen = WsErrorScreen }
                in
                result.screen |> Expect.equal WsErrorScreen
        ]


serverQuizSongEndedAckSuite : Test
serverQuizSongEndedAckSuite =
    let
        ackEnvelope : Int -> String
        ackEnvelope idx =
            Encode.encode 0
                (Encode.object
                    [ ( "payload", Encode.string "quizSongEndedAck" )
                    , ( "quizSongEndedAck", Encode.object [ ( "idx", Encode.int idx ) ] )
                    ]
                )
    in
    describe "ServerQuizSongEndedAck (via WsDataReceived)"
        [ test "arriving after the local timer already elapsed reveals the question immediately" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (ackEnvelope 0))
                            { baseModel | screen = BlankScreen 0, songTimerElapsed = True }
                in
                result.screen |> Expect.equal (QuestionScreen 0 "")
        , test "arriving before the local timer elapses just records the ack" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (ackEnvelope 0))
                            { baseModel | screen = BlankScreen 0, songTimerElapsed = False }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 0)
                    , \m -> m.songEndAcked |> Expect.equal True
                    ]
                    result
        , test "a stale ack for a different index is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (ackEnvelope 1))
                            { baseModel | screen = BlankScreen 0, songTimerElapsed = True }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 0)
                    , \m -> m.songEndAcked |> Expect.equal False
                    ]
                    result
        , test "ignored off a blank screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (ackEnvelope 0)) { baseModel | screen = WsErrorScreen }
                in
                result.screen |> Expect.equal WsErrorScreen
        ]


serverIqOfferDecisionSuite : Test
serverIqOfferDecisionSuite =
    describe "ServerIqOfferDecision (via WsDataReceived)"
        [ test "granted, on the active IQ screen, transitions to the instructions screen with the offer stashed as pending (issue #93)" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (decisionEnvelope True 42))
                            { baseModel | screen = IQTestActiveScreen { iqActiveState | questionIdx = 2 } }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 2, totalDings = 42, pendingSkipOffer = Just 42 })
        , test "not granted, on the active IQ screen, transitions to the plain begin screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (decisionEnvelope False 42))
                            { baseModel | screen = IQTestActiveScreen { iqActiveState | questionIdx = 2 } }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 2, totalDings = 42, pendingSkipOffer = Nothing })
        , test "granted, on the fake-flash-caught screen, stashes the decision without transitioning yet" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 20, phase = FfDelay, skipOffer = Nothing }

                    ( result, _ ) =
                        update (WsDataReceived (decisionEnvelope True 20)) { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | skipOffer = Just 20 })
        , test "not granted, on the fake-flash-caught screen, stashes Nothing" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 20, phase = FfDelay, skipOffer = Just 999 }

                    ( result, _ ) =
                        update (WsDataReceived (decisionEnvelope False 20)) { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | skipOffer = Nothing })
        , test "ignored off both screens" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (decisionEnvelope True 42)) { baseModel | screen = WsErrorScreen }
                in
                result.screen |> Expect.equal WsErrorScreen
        ]


iqSkipOfferAcceptedSuite : Test
iqSkipOfferAcceptedSuite =
    describe "IQSkipOfferAccepted"
        [ test "starts the count-up animation at SkipCounterIn" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipOfferAccepted
                            { baseModel | screen = IQTestSkipOfferScreen { questionIdx = 2, totalDings = 100, pendingSkipOffer = Nothing } }
                in
                result.screen
                    |> Expect.equal
                        (IQTestSkipAnimScreen { questionIdx = 2, displayCount = 0, total = 100, phase = SkipCounterIn })
        , test "ignored off the skip-offer screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipOfferAccepted { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


iqSkipOfferDeclinedSuite : Test
iqSkipOfferDeclinedSuite =
    describe "IQSkipOfferDeclined"
        [ test "returns to the IQ begin screen and reports the decline" <|
            \_ ->
                let
                    ( result, cmd ) =
                        update IQSkipOfferDeclined
                            { baseModel | screen = IQTestSkipOfferScreen { questionIdx = 2, totalDings = 100, pendingSkipOffer = Nothing } }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (IQTestScreen { questionIdx = 2, totalDings = 100, pendingSkipOffer = Nothing })
                    , \_ -> cmd |> Expect.equal (sendWs baseModel Sync.iqOfferDeclinedEnvelope)
                    ]
                    ()
        , test "ignored off the skip-offer screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipOfferDeclined { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


iqSkipAnimNextPhaseSuite : Test
iqSkipAnimNextPhaseSuite =
    describe "IQSkipAnimNextPhase"
        [ test "SkipCounterIn advances to SkipTick" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipAnimNextPhase
                            { baseModel | screen = IQTestSkipAnimScreen { questionIdx = 2, displayCount = 0, total = 100, phase = SkipCounterIn } }
                in
                result.screen |> Expect.equal (IQTestSkipAnimScreen { questionIdx = 2, displayCount = 0, total = 100, phase = SkipTick })
        , test "SkipTick advances to SkipCounterOut" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipAnimNextPhase
                            { baseModel | screen = IQTestSkipAnimScreen { questionIdx = 2, displayCount = 100, total = 100, phase = SkipTick } }
                in
                result.screen |> Expect.equal (IQTestSkipAnimScreen { questionIdx = 2, displayCount = 100, total = 100, phase = SkipCounterOut })
        , test "SkipCounterOut advances to the next song's BlankScreen and reports the pass, exactly like a genuine pass" <|
            \_ ->
                let
                    ( result, cmd ) =
                        update IQSkipAnimNextPhase
                            { baseModel | screen = IQTestSkipAnimScreen { questionIdx = 2, displayCount = 100, total = 100, phase = SkipCounterOut } }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (BlankScreen 3)
                    , \_ -> cmd |> Expect.equal (sendWs baseModel (Sync.quizAdvancedEnvelope 2))
                    ]
                    ()
        , test "ignored off the skip-anim screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipAnimNextPhase { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


iqSkipCounterTickSuite : Test
iqSkipCounterTickSuite =
    describe "IQSkipCounterTick"
        [ test "ticks displayCount up by one while it's below total, and bumps dingKey" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipCounterTick
                            { baseModel
                                | screen = IQTestSkipAnimScreen { questionIdx = 2, displayCount = 0, total = 100, phase = SkipTick }
                                , dingKey = 7
                            }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (IQTestSkipAnimScreen { questionIdx = 2, displayCount = 1, total = 100, phase = SkipTick })
                    , \m -> m.dingKey |> Expect.equal 8
                    ]
                    result
        , test "displayCount reaching total stops ticking (schedules the next phase instead)" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipCounterTick
                            { baseModel
                                | screen = IQTestSkipAnimScreen { questionIdx = 2, displayCount = 100, total = 100, phase = SkipTick }
                                , dingKey = 7
                            }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (IQTestSkipAnimScreen { questionIdx = 2, displayCount = 100, total = 100, phase = SkipTick })
                    , \m -> m.dingKey |> Expect.equal 7
                    ]
                    result
        , test "outside SkipTick (e.g. SkipCounterOut) is a no-op here" <|
            \_ ->
                let
                    state =
                        { questionIdx = 2, displayCount = 100, total = 100, phase = SkipCounterOut }

                    ( result, _ ) =
                        update IQSkipCounterTick { baseModel | screen = IQTestSkipAnimScreen state }
                in
                result.screen |> Expect.equal (IQTestSkipAnimScreen state)
        , test "ignored off the skip-anim screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQSkipCounterTick { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


answerChangedSuite : Test
answerChangedSuite =
    describe "AnswerChanged"
        [ test "updates the typed answer on a question screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (AnswerChanged "hi") { baseModel | screen = QuestionScreen 0 "" }
                in
                result.screen |> Expect.equal (QuestionScreen 0 "hi")
        , test "ignored off a question screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (AnswerChanged "hi") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


answerSubmittedMoreSuite : Test
answerSubmittedMoreSuite =
    describe "AnswerSubmitted (remaining branches)"
        [ test "ignored off a question screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update AnswerSubmitted { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


continuePressedSuite : Test
continuePressedSuite =
    describe "ContinuePressed"
        [ test "moves from the wrong-answer screen back to the IQ begin screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update ContinuePressed { baseModel | screen = WrongAnswerScreen 2 "Alpha" }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 2, totalDings = iqQuestionCount, pendingSkipOffer = Nothing })
        , test "ignored off the wrong-answer screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update ContinuePressed { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


iqTestBeginPressedSuite : Test
iqTestBeginPressedSuite =
    describe "IQTestBeginPressed"
        [ test "starts the countdown from the IQ begin screen, when there's no pending skip offer" <|
            \_ ->
                let
                    ( result, cmd ) =
                        update IQTestBeginPressed { baseModel | screen = IQTestScreen { questionIdx = 0, totalDings = iqQuestionCount, pendingSkipOffer = Nothing } }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (IQTestCountdownScreen { questionIdx = 0, totalDings = iqQuestionCount, countdown = iqQuestionCount })
                    , \_ -> cmd |> Expect.equal (sendWs baseModel Sync.iqStartCountdownEnvelope)
                    ]
                    ()
        , test "goes straight to the skip-offer screen instead, when a grant is pending (issue #93)" <|
            \_ ->
                let
                    ( result, cmd ) =
                        update IQTestBeginPressed { baseModel | screen = IQTestScreen { questionIdx = 2, totalDings = 100, pendingSkipOffer = Just 100 } }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (IQTestSkipOfferScreen { questionIdx = 2, totalDings = 100, pendingSkipOffer = Nothing })
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        , test "ignored off the IQ begin screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update IQTestBeginPressed { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


dingFlashEndSuite : Test
dingFlashEndSuite =
    describe "DingFlashEnd"
        [ test "clears isFlashing on the active IQ screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update DingFlashEnd { baseModel | screen = IQTestActiveScreen { iqActiveState | isFlashing = True } }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | isFlashing = False })
        , test "ignored off the active IQ screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update DingFlashEnd { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


dingWindowExpiredSuite : Test
dingWindowExpiredSuite =
    describe "DingWindowExpired"
        [ test "a still-active ding times out to a fail: freezes on the active screen (flags cleared) and reports it" <|
            \_ ->
                let
                    state =
                        { iqActiveState | dingActive = True, totalDings = 9 }

                    ( result, cmd ) =
                        update DingWindowExpired { baseModel | screen = IQTestActiveScreen state }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (IQTestActiveScreen { state | isFlashing = False, dingActive = False, fakeFlashActive = False })
                    , \_ -> cmd |> Expect.equal (sendWs baseModel Sync.iqFailedEnvelope)
                    ]
                    ()
        , test "an already-cleared ding is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update DingWindowExpired { baseModel | screen = IQTestActiveScreen { iqActiveState | dingActive = False } }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | dingActive = False })
        , test "ignored off the active IQ screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update DingWindowExpired { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


fakeFlashWindowExpiredSuite : Test
fakeFlashWindowExpiredSuite =
    describe "FakeFlashWindowExpired"
        [ test "correctly-ignored fake clears fakeFlashActive" <|
            \_ ->
                let
                    ( result, _ ) =
                        update FakeFlashWindowExpired { baseModel | screen = IQTestActiveScreen { iqActiveState | fakeFlashActive = True } }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | fakeFlashActive = False })
        , test "a no-longer-active fake is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update FakeFlashWindowExpired { baseModel | screen = IQTestActiveScreen { iqActiveState | fakeFlashActive = False } }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | fakeFlashActive = False })
        , test "ignored off the active IQ screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update FakeFlashWindowExpired { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


startLoudMusicSuite : Test
startLoudMusicSuite =
    describe "StartLoudMusic"
        [ test "sets loudPlaying on the active IQ screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update StartLoudMusic { baseModel | screen = IQTestActiveScreen iqActiveState }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | loudPlaying = True })
        , test "ignored off the active IQ screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update StartLoudMusic { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


fakeFlashNextPhaseMoreSuite : Test
fakeFlashNextPhaseMoreSuite =
    describe "FakeFlashNextPhase (remaining branches)"
        [ test "FfTickDelay starts the denominator tick" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfTickDelay, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | phase = FfTickDenominator })
        , test "a mid-tick phase is a no-op (advanced by FakeFlashCounterTick instead)" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 5, displayDenominator = 10, phase = FfTickNumerator, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen state)
        , test "ignored off the fake-flash-caught screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


wsClientReadySuite : Test
wsClientReadySuite =
    describe "WsClientReady"
        [ test "with a known uuid, requests state and loads" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsClientReady "ws1") { baseModel | myUuid = Just "uuid1" }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal WsLoadingScreen
                    , \m -> m.wsClientId |> Expect.equal (Just "ws1")
                    ]
                    result
        , test "with no uuid yet, falls back to the error screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsClientReady "ws1") { baseModel | myUuid = Nothing }
                in
                result.screen |> Expect.equal WsErrorScreen
        ]


wsDisconnectedMoreSuite : Test
wsDisconnectedMoreSuite =
    describe "WsDisconnected (remaining branches)"
        [ test "from any other screen, drops the ws id and reconnects" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = BlankScreen 0, wsClientId = Just "ws1" }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal WsConnectingScreen
                    , \m -> m.wsClientId |> Expect.equal Nothing
                    ]
                    result
        ]


wsReconnectSuite : Test
wsReconnectSuite =
    describe "WsReconnect"
        [ test "from the error screen, reconnects" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsReconnect { baseModel | screen = WsErrorScreen }
                in
                result.screen |> Expect.equal WsConnectingScreen
        , test "from the connecting screen, retries" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsReconnect { baseModel | screen = WsConnectingScreen }
                in
                result.screen |> Expect.equal WsConnectingScreen
        , test "ignored elsewhere" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsReconnect { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


uuidLoadedSuite : Test
uuidLoadedSuite =
    describe "UuidLoaded"
        [ test "a loaded uuid connects the websocket" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (UuidLoaded (Just "uuid9")) baseModel
                in
                result.myUuid |> Expect.equal (Just "uuid9")
        , test "no uuid falls back to the error screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (UuidLoaded Nothing) baseModel
                in
                result.screen |> Expect.equal WsErrorScreen
        ]


miscTrivialSuite : Test
miscTrivialSuite =
    describe "trivial Msg branches"
        [ test "QuestionsLoaded replaces the question list" <|
            \_ ->
                let
                    qs =
                        [ "x.mp3" ]

                    ( result, _ ) =
                        update (QuestionsLoaded qs) baseModel
                in
                result.questions |> Expect.equal qs
        , test "NoOp is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update NoOp baseModel
                in
                result |> Expect.equal baseModel
        , test "DomPropertyReceived is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (DomPropertyReceived { elementId = "x", property = "y", value = Encode.null }) baseModel
                in
                result |> Expect.equal baseModel
        , test "DomPropertyError is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (DomPropertyError "boom") baseModel
                in
                result |> Expect.equal baseModel
        ]


fakeFlashCounterTickSuite : Test
fakeFlashCounterTickSuite =
    describe "FakeFlashCounterTick"
        [ test "ticks the numerator down while it's above zero" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 3, displayDenominator = 10, phase = FfTickNumerator, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashCounterTick { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | displayNumerator = 2 })
        , test "numerator reaching zero moves to the tick-delay phase" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfTickNumerator, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashCounterTick { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | phase = FfTickDelay })
        , test "ticks the denominator up while under target" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 15, phase = FfTickDenominator, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashCounterTick { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | displayDenominator = 16 })
        , test "denominator reaching target moves to the counter-out phase" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 20, phase = FfTickDenominator, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashCounterTick { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | phase = FfCounterOut })
        , test "a non-tick phase is a no-op" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfDelay, skipOffer = Nothing }

                    ( result, _ ) =
                        update FakeFlashCounterTick { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen state)
        , test "ignored off the fake-flash-caught screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update FakeFlashCounterTick { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


wsDataReceivedSuite : Test
wsDataReceivedSuite =
    describe "WsDataReceived"
        [ test "stateUpdate of an empty object (brand-new player) on WsLoadingScreen enters the begin screen at BlankScreen 0" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (stateUpdateEnvelope "{}")) { baseModel | screen = WsLoadingScreen }
                in
                result.screen |> Expect.equal (BeginScreen (BlankScreen 0))
        , test "stateUpdate of a real model on WsLoadingScreen restores it" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (stateUpdateEnvelope validModelJson)) { baseModel | screen = WsLoadingScreen }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "stateUpdate with an undecodable model is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (stateUpdateEnvelope "not json")) { baseModel | screen = WsLoadingScreen }
                in
                result.screen |> Expect.equal WsLoadingScreen
        , test "stateUpdate off WsLoadingScreen is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (stateUpdateEnvelope "{}")) { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "stateRequestRejected falls back to the error screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"stateRequestRejected","stateRequestRejected":{"reason":"locked"}}""") baseModel
                in
                result.screen |> Expect.equal WsErrorScreen
        , test "stateUpdateAck on ConfirmingAnswerScreen(WinScreen) waits for winText" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"stateUpdateAck"}""") { baseModel | screen = ConfirmingAnswerScreen (WinScreen "") }
                in
                result.screen |> Expect.equal (ConfirmingAnswerScreen (WinScreen ""))
        , test "stateUpdateAck on ConfirmingAnswerScreen resolves to the next screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"stateUpdateAck"}""") { baseModel | screen = ConfirmingAnswerScreen (BlankScreen 1) }
                in
                result.screen |> Expect.equal (BlankScreen 1)
        , test "stateUpdateAck elsewhere is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"stateUpdateAck"}""") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "winText on CheckingAnswerScreen(WinScreen) reveals the win screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"winText","winText":{"text":"yay"}}""") { baseModel | screen = CheckingAnswerScreen (WinScreen "") }
                in
                result.screen |> Expect.equal (WinScreen "yay")
        , test "winText on ConfirmingAnswerScreen(WinScreen) reveals the win screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"winText","winText":{"text":"yay"}}""") { baseModel | screen = ConfirmingAnswerScreen (WinScreen "") }
                in
                result.screen |> Expect.equal (WinScreen "yay")
        , test "winText on WinScreen updates the text" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"winText","winText":{"text":"yay"}}""") { baseModel | screen = WinScreen "" }
                in
                result.screen |> Expect.equal (WinScreen "yay")
        , test "winText on BlankScreen reveals the win screen (stuck after IQ-test penalty on the last question)" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"winText","winText":{"text":"yay"}}""") { baseModel | screen = BlankScreen 3 }
                in
                result.screen |> Expect.equal (WinScreen "yay")
        , test "winText elsewhere is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"winText","winText":{"text":"yay"}}""") { baseModel | screen = QuestionScreen 0 "" }
                in
                result.screen |> Expect.equal (QuestionScreen 0 "")
        , test "iqCountdownTick updates the displayed countdown" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, totalDings = iqQuestionCount, countdown = 5 }

                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqCountdownTick","iqCountdownTick":{"remaining":3}}""") { baseModel | screen = IQTestCountdownScreen state }
                in
                result.screen |> Expect.equal (IQTestCountdownScreen { state | countdown = 3 })
        , test "iqCountdownTick elsewhere is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqCountdownTick","iqCountdownTick":{"remaining":3}}""") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "iqCountdownComplete enters the active test, preserving a nonzero dingCount" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, totalDings = iqQuestionCount, countdown = 0 }

                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqCountdownComplete","iqCountdownComplete":{"dingCount":5}}""") { baseModel | screen = IQTestCountdownScreen state }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | questionIdx = 1, dingCount = 5 })
        , test "iqCountdownComplete below the loud threshold does not schedule the loud video" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, totalDings = iqQuestionCount, countdown = 0 }

                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqCountdownComplete","iqCountdownComplete":{"dingCount":3}}""") { baseModel | screen = IQTestCountdownScreen state }
                in
                pendingStartLoudMusicFireAt result |> Expect.equal Nothing
        , test "iqCountdownComplete at/above the loud threshold schedules (but doesn't yet start) the loud video" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, totalDings = iqQuestionCount, countdown = 0 }

                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqCountdownComplete","iqCountdownComplete":{"dingCount":5}}""")
                            { baseModel | screen = IQTestCountdownScreen state }
                in
                Expect.all
                    [ \_ -> result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | questionIdx = 1, dingCount = 5 })
                    , \_ -> pendingStartLoudMusicFireAt result |> Expect.equal (Just (result.now + iqLoudDelay))
                    ]
                    ()
        , test "iqCountdownComplete's scheduled loud video actually starts once fired" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, totalDings = iqQuestionCount, countdown = 0 }

                    ( afterCountdown, _ ) =
                        update (WsDataReceived """{"payload":"iqCountdownComplete","iqCountdownComplete":{"dingCount":5}}""")
                            { baseModel | screen = IQTestCountdownScreen state }

                    ( result, _ ) =
                        update StartLoudMusic afterCountdown
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | questionIdx = 1, dingCount = 5, loudPlaying = True })
        , test "iqCountdownComplete elsewhere is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqCountdownComplete"}""") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "iqDing (fake) arms the fake-flash window" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqDing","iqDing":{"fake":true,"trap":true,"dingCount":5,"totalDings":100}}""")
                            { baseModel | screen = IQTestActiveScreen iqActiveState }
                in
                result.screen
                    |> Expect.equal (IQTestActiveScreen { iqActiveState | dingCount = 5, totalDings = 100, isFlashing = True, dingActive = False, fakeFlashActive = True, fakeIsTrap = True })
        , test "iqDing (real) arms the ding window" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqDing","iqDing":{"fake":false,"trap":false,"dingCount":2,"totalDings":100}}""")
                            { baseModel | screen = IQTestActiveScreen iqActiveState }
                in
                result.screen
                    |> Expect.equal (IQTestActiveScreen { iqActiveState | dingCount = 2, totalDings = 100, isFlashing = True, dingActive = True, fakeFlashActive = False })
        , test "iqDing elsewhere is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqDing","iqDing":{"fake":false,"trap":false,"dingCount":2,"totalDings":100}}""") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "iqStartLoud arms the loud loop on the active screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqStartLoud"}""") { baseModel | screen = IQTestActiveScreen iqActiveState }
                in
                result.screen |> Expect.equal (IQTestActiveScreen iqActiveState)
        , test "iqStartLoud elsewhere is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqStartLoud"}""") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "iqTestComplete releases to the next song" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqTestComplete"}""") { baseModel | screen = IQTestActiveScreen iqActiveState }
                in
                result.screen |> Expect.equal (BlankScreen 1)
        , test "iqTestComplete elsewhere is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"iqTestComplete"}""") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "an unrecognized payload is ignored" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"authChallenge"}""") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "stateUpdate restore preserves the live timerEndsAt rather than the decoded placeholder" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived (stateUpdateEnvelope validModelJson)) { baseModel | screen = WsLoadingScreen, timerEndsAt = 99999 }
                in
                result.timerEndsAt |> Expect.equal 99999
        , test "timerSync sets the server-delivered deadline for display" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"timerSync","timerSync":{"timerEndsAt":123456}}""") baseModel
                in
                result.timerEndsAt |> Expect.equal 123456
        , test "timedOut forces the timed-out screen regardless of the current screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDataReceived """{"payload":"timedOut","timedOut":{}}""") { baseModel | screen = BlankScreen 2 }
                in
                result.screen |> Expect.equal TimedOutScreen
        ]


remainingEdgeCasesSuite : Test
remainingEdgeCasesSuite =
    describe "remaining edge cases for full branch coverage"
        [ test "Tick's very first tick (now == 0) just initializes the clock" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (Tick 5000) { baseModel | now = 0, screen = BlankScreen 0 }
                in
                Expect.all
                    [ \m -> m.now |> Expect.equal 5000
                    , \m -> m.screen |> Expect.equal (BlankScreen 0)
                    ]
                    result
        , test "a WsDisconnected burst dedupes an already-queued reconnect" <|
            \_ ->
                let
                    model =
                        { baseModel
                            | screen = BlankScreen 0
                            , wsClientId = Just "ws1"
                            , pending = [ { fireAt = 1200, msg = WsReconnect }, { fireAt = 1300, msg = ShowQuestion 0 } ]
                        }

                    ( result, _ ) =
                        update (WsDisconnected "closed") model
                in
                Expect.all
                    [ \m -> m.pending |> List.filter (\e -> e.msg == WsReconnect) |> List.length |> Expect.equal 1
                    , \m -> m.pending |> List.any (\e -> e.msg == ShowQuestion 0) |> Expect.equal True
                    ]
                    result
        , test "SpaceBarPressed with no connection still updates optimistically without a Cmd effect" <|
            \_ ->
                let
                    ( result, _ ) =
                        update SpaceBarPressed { baseModel | wsClientId = Nothing, screen = IQTestActiveScreen { iqActiveState | dingActive = True } }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { iqActiveState | dingActive = False, dingCount = 1 })
        , test "SpaceBarPressed ignored off the active IQ screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update SpaceBarPressed { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "resuming into a derived IQTestCountdownScreen re-arms the server timer" <|
            \_ ->
                let
                    savedScreen =
                        IQTestCountdownScreen { questionIdx = 0, totalDings = iqQuestionCount, countdown = 3 }

                    ( result, _ ) =
                        update BeginPressed { baseModel | screen = BeginScreen savedScreen }
                in
                result.screen |> Expect.equal savedScreen
        , test "resuming into a derived IQTestActiveScreen re-arms the server timer" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed { baseModel | screen = BeginScreen (IQTestActiveScreen iqActiveState) }
                in
                result.screen |> Expect.equal (IQTestActiveScreen iqActiveState)
        , test "resuming into a derived FakeFlashCaughtScreen re-arms the local cutscene animation" <|
            \_ ->
                let
                    savedScreen =
                        FakeFlashCaughtScreen { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfDelay, skipOffer = Nothing }

                    ( result, _ ) =
                        update BeginPressed { baseModel | now = 6000, screen = BeginScreen savedScreen }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal savedScreen
                    , \m ->
                        m.pending
                            |> List.filter (\e -> e.msg == FakeFlashNextPhase)
                            |> List.map .fireAt
                            |> Expect.equal [ 7000 ]
                    ]
                    result
        , test "PlaySong unwraps a CheckingAnswerScreen-wrapped blank screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (PlaySong 1) { baseModel | screen = CheckingAnswerScreen (BlankScreen 1) }
                in
                result.screen |> Expect.equal (VideoScreen 1 "video1.mp4")
        , test "PlaySong unwraps a ConfirmingAnswerScreen-wrapped blank screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (PlaySong 1) { baseModel | screen = ConfirmingAnswerScreen (BlankScreen 1) }
                in
                result.screen |> Expect.equal (VideoScreen 1 "video1.mp4")
        , test "TrackEnded ignores a track that doesn't match the scheduled song" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "someone-elses-song.mp3") { baseModel | screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "TrackEnded ignores an out-of-range blank screen index" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "song0.mp3") { baseModel | screen = BlankScreen 99 }
                in
                result.screen |> Expect.equal (BlankScreen 99)
        , test "AnswerSubmitted with no question at this index is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update AnswerSubmitted { baseModel | screen = QuestionScreen 99 "x" }
                in
                result.screen |> Expect.equal (QuestionScreen 99 "x")
        , test "WsSyncTick with a connection but an unrelated screen leaves it untouched" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsSyncTick { baseModel | wsClientId = Just "ws1", screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        , test "WsSyncTick with no connection and an unrelated screen leaves it untouched" <|
            \_ ->
                let
                    ( result, _ ) =
                        update WsSyncTick { baseModel | wsClientId = Nothing, screen = BlankScreen 0 }
                in
                result.screen |> Expect.equal (BlankScreen 0)
        ]


-- ── Resuming onto a server-derived BlankScreen ────────────────────────────────
-- The server-derived resume screen (Server.elm's deriveQuizScreen) is a bare
-- BlankScreen with no pending PlaySong; a video slide needs the kick or it
-- would never leave the blank screen. baseModel.questions: slide 0 is audio,
-- slide 1 is video.


resumePlaySongTargetSuite : Test
resumePlaySongTargetSuite =
    describe "resumePlaySongTarget"
        [ test "a bare BlankScreen on a video slide needs the PlaySong kick" <|
            \_ ->
                resumePlaySongTarget baseModel.questions [] (BlankScreen 1)
                    |> Expect.equal (Just 1)
        , test "an audio slide self-starts (the rendered audio element plays), no kick" <|
            \_ ->
                resumePlaySongTarget baseModel.questions [] (BlankScreen 0)
                    |> Expect.equal Nothing
        , test "a video slide with its PlaySong already pending is left to that schedule" <|
            \_ ->
                resumePlaySongTarget baseModel.questions [ { fireAt = 0, msg = PlaySong 1 } ] (BlankScreen 1)
                    |> Expect.equal Nothing
        , test "an out-of-range slide has nothing to play" <|
            \_ ->
                resumePlaySongTarget baseModel.questions [] (BlankScreen 99)
                    |> Expect.equal Nothing
        , test "screens other than a bare BlankScreen never need the kick" <|
            \_ ->
                resumePlaySongTarget baseModel.questions [] (VideoScreen 1 "video1.mp4")
                    |> Expect.equal Nothing
        ]


needsFakeFlashKickSuite : Test
needsFakeFlashKickSuite =
    describe "needsFakeFlashKick"
        [ test "a FakeFlashCaughtScreen needs the cutscene kick" <|
            \_ ->
                needsFakeFlashKick
                    (FakeFlashCaughtScreen { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfDelay, skipOffer = Nothing })
                    |> Expect.equal True
        , test "a bare BlankScreen doesn't need it" <|
            \_ ->
                needsFakeFlashKick (BlankScreen 0) |> Expect.equal False
        , test "an IQTestActiveScreen doesn't need it" <|
            \_ ->
                needsFakeFlashKick (IQTestActiveScreen iqActiveState) |> Expect.equal False
        ]


resumeVideoKickRoutingSuite : Test
resumeVideoKickRoutingSuite =
    describe "BeginPressed resume schedules PlaySong for a bare video-slide BlankScreen"
        [ test "resuming onto a video-slide BlankScreen with empty pending schedules the PlaySong" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed { baseModel | now = 6000, screen = BeginScreen (BlankScreen 1) }
                in
                result.pending
                    |> List.filter (\e -> e.msg == PlaySong 1)
                    |> List.map .fireAt
                    |> Expect.equal [ 7000 ]
        , test "resuming onto an audio-slide BlankScreen schedules nothing extra" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed { baseModel | now = 6000, screen = BeginScreen (BlankScreen 0) }
                in
                result.pending |> Expect.equal []
        ]


{-| Issue #93: a granted IQ-offer used to jump straight from the fail/catch to
the offer screen, skipping the instructions screen. These reproduce the
issue's own two test cases end to end, chaining `update` calls the same way a
real play session would fire the underlying Msgs.
-}
issue93Suite : Test
issue93Suite =
    describe "Issue #93: IQ offer appears after instructions, not immediately"
        [ test "IQ offer appears after instructions" <|
            \_ ->
                let
                    afterFail =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen { iqActiveState | dingCount = 5, totalDings = 100 } }
                            |> Tuple.first

                    afterDecision =
                        update (WsDataReceived (decisionEnvelope True 100)) afterFail
                            |> Tuple.first

                    afterBegin =
                        update IQTestBeginPressed afterDecision
                            |> Tuple.first
                in
                Expect.all
                    [ \_ -> afterDecision.screen |> Expect.equal (IQTestScreen { questionIdx = 0, totalDings = 100, pendingSkipOffer = Just 100 })
                    , \_ -> afterBegin.screen |> Expect.equal (IQTestSkipOfferScreen { questionIdx = 0, totalDings = 100, pendingSkipOffer = Nothing })
                    ]
                    ()
        , test "IQ Test occurs after animation" <|
            \_ ->
                let
                    trapState =
                        { iqActiveState | fakeFlashActive = True, fakeIsTrap = True, dingCount = 3, totalDings = 50 }

                    afterCatch =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen trapState }
                            |> Tuple.first

                    afterDecision =
                        update (WsDataReceived (decisionEnvelope True 50)) afterCatch
                            |> Tuple.first

                    -- "Wait for the animation to finish": jump straight to the terminal
                    -- phase, mirroring fakeFlashNextPhaseSuite's existing style.
                    atCounterOut =
                        case afterDecision.screen of
                            FakeFlashCaughtScreen s ->
                                { afterDecision | screen = FakeFlashCaughtScreen { s | phase = FfCounterOut } }

                            _ ->
                                afterDecision

                    afterAnimation =
                        update FakeFlashNextPhase atCounterOut
                            |> Tuple.first

                    afterDecline =
                        update IQSkipOfferDeclined afterAnimation
                            |> Tuple.first
                in
                Expect.all
                    [ \_ ->
                        afterCatch.screen
                            |> Expect.equal
                                (FakeFlashCaughtScreen
                                    { questionIdx = 0, originalTotal = 50, displayNumerator = 3, displayDenominator = 50, phase = FfDelay, skipOffer = Nothing }
                                )
                    , \_ ->
                        -- Correct, unchanged behavior: the catch path lands directly on the
                        -- offer screen once the cutscene finishes -- a regression guard.
                        afterAnimation.screen |> Expect.equal (IQTestSkipOfferScreen { questionIdx = 0, totalDings = 50, pendingSkipOffer = Nothing })
                    , \_ -> afterDecline.screen |> Expect.equal (IQTestScreen { questionIdx = 0, totalDings = 50, pendingSkipOffer = Nothing })
                    ]
                    ()
        ]
