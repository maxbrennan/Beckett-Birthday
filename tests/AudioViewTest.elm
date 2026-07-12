module AudioViewTest exposing (..)

import Audio exposing (currentQuizSong, hasPendingPlaySong)
import Expect
import Test exposing (Test, describe, test)
import Types exposing (Model, Msg(..), PendingEvent, Screen(..))
import View exposing (formatTimer)


baseModel : Model
baseModel =
    { screen = WsConnectingScreen
    , now = 0
    , pending = []
    , dingKey = 0
    , wsClientId = Nothing
    , timerEndsAt = 0
    , myUuid = Nothing
    , wsUrl = ""
    , questions = [ "song0.mp3", "video1.mp4", "song2.mp3" ]
    , awaitingAnswerResult = False
    }


hasPendingPlaySongTests : Test
hasPendingPlaySongTests =
    describe "hasPendingPlaySong"
        [ test "True when a PlaySong event for that index is pending" <|
            \_ -> Expect.equal True (hasPendingPlaySong 2 [ PendingEvent 1000 (PlaySong 2) ])
        , test "False when the pending PlaySong is for a different index" <|
            \_ -> Expect.equal False (hasPendingPlaySong 2 [ PendingEvent 1000 (PlaySong 3) ])
        , test "False when there are no pending events" <|
            \_ -> Expect.equal False (hasPendingPlaySong 2 [])
        , test "False when pending events exist but none are PlaySong" <|
            \_ -> Expect.equal False (hasPendingPlaySong 0 [ PendingEvent 1000 DingFlashEnd ])
        ]


currentQuizSongTests : Test
currentQuizSongTests =
    describe "currentQuizSong"
        [ test "returns the song for a BlankScreen whose question is audio" <|
            \_ -> Expect.equal (Just "song0.mp3") (currentQuizSong { baseModel | screen = BlankScreen 0 })
        , test "returns Nothing for a video question (played differently)" <|
            \_ -> Expect.equal Nothing (currentQuizSong { baseModel | screen = BlankScreen 1 })
        , test "returns Nothing when a PlaySong for this index is already pending (avoid double-trigger)" <|
            \_ ->
                Expect.equal Nothing
                    (currentQuizSong { baseModel | screen = BlankScreen 0, pending = [ PendingEvent 1000 (PlaySong 0) ] })
        , test "returns Nothing on non-BlankScreen screens" <|
            \_ -> Expect.equal Nothing (currentQuizSong { baseModel | screen = WsConnectingScreen })
        , test "returns Nothing when the index is out of range" <|
            \_ -> Expect.equal Nothing (currentQuizSong { baseModel | screen = BlankScreen 99 })
        , test "returns Nothing while parked on the begin screen, even for an audio slide (the double-audio bug fix)" <|
            \_ -> Expect.equal Nothing (currentQuizSong { baseModel | screen = BeginScreen (BlankScreen 0) })
        ]


formatTimerTests : Test
formatTimerTests =
    describe "formatTimer"
        [ test "formats zero as 0d 0h 0m 0s" <|
            \_ -> Expect.equal "0d 0h 0m 0s" (formatTimer 0)
        , test "formats seconds only" <|
            \_ -> Expect.equal "0d 0h 0m 45s" (formatTimer 45000)
        , test "formats minutes and seconds" <|
            \_ -> Expect.equal "0d 0h 2m 5s" (formatTimer (125 * 1000))
        , test "formats hours, minutes, and seconds" <|
            \_ -> Expect.equal "0d 1h 1m 1s" (formatTimer ((3600 + 60 + 1) * 1000))
        , test "formats days" <|
            \_ -> Expect.equal "2d 0h 0m 0s" (formatTimer (2 * 86400 * 1000))
        ]
