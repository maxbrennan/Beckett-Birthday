module QuizTest exposing (..)

import Expect
import Game.Quiz exposing (Question, capitalize, decodeQuestions, getQuestion, isVideo, normalize)
import Test exposing (Test, describe, test)


normalizeTests : Test
normalizeTests =
    describe "normalize"
        [ test "lowercases and collapses whitespace" <|
            \_ -> Expect.equal "here comes the sun" (normalize "Here   Comes The Sun")
        , test "replaces hyphens with spaces" <|
            \_ -> Expect.equal "rock n roll" (normalize "Rock-n-Roll")
        , test "strips punctuation but keeps alphanumerics" <|
            \_ -> Expect.equal "dont stop believin" (normalize "Don't Stop, Believin'!")
        , test "collapses repeated internal whitespace left after filtering" <|
            \_ -> Expect.equal "abc 123" (normalize "  abc!!! 123  ")
        ]


capitalizeTests : Test
capitalizeTests =
    describe "capitalize"
        [ test "uppercases the first character" <|
            \_ -> Expect.equal "Hello" (capitalize "hello")
        , test "leaves the rest of the string unchanged" <|
            \_ -> Expect.equal "HELLo" (capitalize "hELLo")
        , test "empty string stays empty" <|
            \_ -> Expect.equal "" (capitalize "")
        ]


isVideoTests : Test
isVideoTests =
    describe "isVideo"
        [ test "true for .mp4 files" <|
            \_ -> Expect.equal True (isVideo "song.mp4")
        , test "false for audio files" <|
            \_ -> Expect.equal False (isVideo "song.mp3")
        , test "false for a filename with no extension" <|
            \_ -> Expect.equal False (isVideo "song")
        ]


getQuestionTests : Test
getQuestionTests =
    let
        questions =
            [ Question "a.mp3" [ "a" ], Question "b.mp3" [ "b" ], Question "c.mp3" [ "c" ] ]
    in
    describe "getQuestion"
        [ test "returns the question at the given index" <|
            \_ -> Expect.equal (Just (Question "b.mp3" [ "b" ])) (getQuestion questions 1)
        , test "returns Nothing when the index is out of range" <|
            \_ -> Expect.equal Nothing (getQuestion questions 10)
        , test "returns Nothing for an empty list" <|
            \_ -> Expect.equal Nothing (getQuestion [] 0)
        ]


decodeQuestionsTests : Test
decodeQuestionsTests =
    describe "decodeQuestions"
        [ test "decodes a well-formed JSON array of questions" <|
            \_ ->
                Expect.equal
                    [ Question "one.mp3" [ "One", "Uno" ], Question "two.mp3" [ "Two" ] ]
                    (decodeQuestions """[{"song":"one.mp3","answers":["One","Uno"]},{"song":"two.mp3","answers":["Two"]}]""")
        , test "returns an empty list for malformed JSON" <|
            \_ -> Expect.equal [] (decodeQuestions "not json")
        , test "returns an empty list for valid JSON that doesn't match the shape" <|
            \_ -> Expect.equal [] (decodeQuestions """[{"wrong": "shape"}]""")
        ]
