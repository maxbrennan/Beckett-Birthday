module MainTest exposing (..)

import Expect
import Game.IQTest exposing (FakeFlashPhase(..), IQTestState, iqQuestionCount)
import Game.Quiz exposing (Question)
import Main exposing (update)
import Test exposing (Test, describe, test)
import Types exposing (Model, Msg(..), PausedState, Screen(..))


baseModel : Model
baseModel =
    { screen = BeginScreen
    , jeopardyPlaying = False
    , now = 1000
    , pending = []
    , savedState = Nothing
    , dingKey = 0
    , pendingStartTime = Nothing
    , wsClientId = Just "old-ws-id"
    , timerEndsAt = 0
    , myUuid = Just "uuid1"
    , wsUrl = "wss://example.test"
    , questions = [ Question "song0.mp3" [ "alpha" ], Question "video1.mp4" [ "beta" ] ]
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


suite : Test
suite =
    describe "WsDisconnected reconnect throttling (issue #51)"
        [ test "disconnecting from an active screen throttles the reconnect via scheduleReconnect" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = BeginScreen }
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
        [ test "times a screen out once past timerEndsAt" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (Tick 5000) { baseModel | screen = BeginScreen, timerEndsAt = 4000 }
                in
                result.screen |> Expect.equal TimedOutScreen
        , test "does not time out a connection-status screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (Tick 5000) { baseModel | screen = WsConnectingScreen, timerEndsAt = 4000 }
                in
                result.screen |> Expect.equal WsConnectingScreen
        , test "fires a due pending event and drops it from pending" <|
            \_ ->
                let
                    model =
                        { baseModel
                            | screen = BlankScreen 0
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
        [ test "with no saved state, starts the first question after a delay" <|
            \_ ->
                let
                    ( result, _ ) =
                        update BeginPressed { baseModel | screen = BeginScreen, jeopardyPlaying = True }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 0)
                    , \m -> m.jeopardyPlaying |> Expect.equal False
                    , \m -> m.pending |> List.map .msg |> Expect.equal [ PlaySong 0 ]
                    ]
                    result
        , test "with saved state, resumes the saved screen and rebases pending events" <|
            \_ ->
                let
                    saved : PausedState
                    saved =
                        { screen = BlankScreen 2
                        , pending = [ { fireAt = 5500, msg = ShowQuestion 2 } ]
                        , savedAt = 5000
                        , songResumeTime = Just 3.5
                        , videoResumeTime = Nothing
                        }

                    ( result, _ ) =
                        update BeginPressed { baseModel | now = 6000, savedState = Just saved }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 2)
                    , \m -> m.savedState |> Expect.equal Nothing
                    , \m -> m.pendingStartTime |> Expect.equal (Just 3.5)
                    , \m -> m.pending |> List.map .fireAt |> Expect.equal [ 6500 ]
                    ]
                    result
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
        [ test "matching the current blank screen's song schedules ShowQuestion" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "song0.mp3") { baseModel | screen = BlankScreen 0 }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (BlankScreen 0)
                    , \m -> m.pending |> List.map .msg |> Expect.equal [ ShowQuestion 0 ]
                    ]
                    result
        , test "a video's own track ending advances to its blank screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "video1.mp4") { baseModel | screen = VideoScreen 1 "video1.mp4" }
                in
                result.screen |> Expect.equal (BlankScreen 1)
        , test "the jeopardy theme ending on BeginScreen is a no-op" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "jeopardy-theme.mp3") { baseModel | screen = BeginScreen, jeopardyPlaying = True }
                in
                result.jeopardyPlaying |> Expect.equal True
        , test "the jeopardy theme ending elsewhere clears jeopardyPlaying" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (TrackEnded "jeopardy-theme.mp3") { baseModel | screen = BlankScreen 0, jeopardyPlaying = True }
                in
                result.jeopardyPlaying |> Expect.equal False
        ]


answerSubmittedSuite : Test
answerSubmittedSuite =
    describe "AnswerSubmitted"
        [ test "a correct answer with a following question moves on" <|
            \_ ->
                let
                    ( result, _ ) =
                        update AnswerSubmitted { baseModel | screen = QuestionScreen 0 "Alpha" }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal (CheckingAnswerScreen (BlankScreen 1))
                    , \m -> m.pending |> List.map .msg |> Expect.equal [ PlaySong 1 ]
                    ]
                    result
        , test "a correct answer on the last question wins" <|
            \_ ->
                let
                    ( result, _ ) =
                        update AnswerSubmitted { baseModel | screen = QuestionScreen 1 "Beta" }
                in
                result.screen |> Expect.equal (CheckingAnswerScreen (WinScreen ""))
        , test "an incorrect answer shows the wrong-answer screen" <|
            \_ ->
                let
                    ( result, _ ) =
                        update AnswerSubmitted { baseModel | screen = QuestionScreen 0 "nope" }
                in
                result.screen |> Expect.equal (CheckingAnswerScreen (WrongAnswerScreen 0))
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
                            { questionIdx = 0, originalTotal = 50, displayNumerator = 3, displayDenominator = 50, phase = FfDelay }
                        )
        , test "pressing a 50%-phase fake fails back to the IQ begin screen" <|
            \_ ->
                let
                    state =
                        { iqActiveState | fakeFlashActive = True, fakeIsTrap = False, totalDings = 42 }

                    ( result, _ ) =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen state }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 0, totalDings = 42 })
        , test "clearing a real ding updates the optimistic count" <|
            \_ ->
                let
                    state =
                        { iqActiveState | dingActive = True, dingCount = 2, totalDings = iqQuestionCount }

                    ( result, _ ) =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen state }
                in
                result.screen |> Expect.equal (IQTestActiveScreen { state | dingActive = False, dingCount = 3 })
        , test "pressing with nothing active fails" <|
            \_ ->
                let
                    ( result, _ ) =
                        update SpaceBarPressed { baseModel | screen = IQTestActiveScreen { iqActiveState | totalDings = 7 } }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 0, totalDings = 7 })
        ]


fakeFlashNextPhaseSuite : Test
fakeFlashNextPhaseSuite =
    describe "FakeFlashNextPhase"
        [ test "advances through the linear phase table" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfDelay }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | phase = FfText1In })
        , test "FfCounterIn starts the ticking counter" <|
            \_ ->
                let
                    state =
                        { questionIdx = 0, originalTotal = 10, displayNumerator = 0, displayDenominator = 10, phase = FfCounterIn }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (FakeFlashCaughtScreen { state | phase = FfTickNumerator })
        , test "FfCounterOut exits back to the IQ begin screen with the doubled count" <|
            \_ ->
                let
                    state =
                        { questionIdx = 3, originalTotal = 10, displayNumerator = 0, displayDenominator = 20, phase = FfCounterOut }

                    ( result, _ ) =
                        update FakeFlashNextPhase { baseModel | screen = FakeFlashCaughtScreen state }
                in
                result.screen |> Expect.equal (IQTestScreen { questionIdx = 3, totalDings = 20 })
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
        ]
