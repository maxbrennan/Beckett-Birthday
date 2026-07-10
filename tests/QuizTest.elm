module QuizTest exposing (..)

import Expect
import Game.Quiz exposing (AnswerOutcome(..), Question, capitalize, decideAnswer, decodeQuestions, getQuestion, isVideo, normalize, songNumericPrefix, songOrder)
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
            [ Question [ "a" ], Question [ "b" ], Question [ "c" ] ]
    in
    describe "getQuestion"
        [ test "returns the question at the given index" <|
            \_ -> Expect.equal (Just (Question [ "b" ])) (getQuestion questions 1)
        , test "returns Nothing when the index is out of range" <|
            \_ -> Expect.equal Nothing (getQuestion questions 10)
        , test "returns Nothing for an empty list" <|
            \_ -> Expect.equal Nothing (getQuestion [] 0)
        ]


decideAnswerTests : Test
decideAnswerTests =
    let
        questions =
            [ Question [ "Alpha" ], Question [ "Beta" ] ]
    in
    describe "decideAnswer"
        [ test "correct answer with a following question continues to it" <|
            \_ -> decideAnswer questions 0 "alpha" |> Expect.equal (CorrectContinue 1)
        , test "correct answer on the last question wins" <|
            \_ -> decideAnswer questions 1 "beta" |> Expect.equal CorrectWin
        , test "wrong answer" <|
            \_ -> decideAnswer questions 0 "gamma" |> Expect.equal IncorrectAnswer
        , test "no question at this index" <|
            \_ -> decideAnswer questions 5 "alpha" |> Expect.equal NoQuestion
        ]


decodeQuestionsTests : Test
decodeQuestionsTests =
    describe "decodeQuestions"
        [ test "decodes a well-formed JSON array of questions" <|
            \_ ->
                Expect.equal
                    [ Question [ "One", "Uno" ], Question [ "Two" ] ]
                    (decodeQuestions """[{"answers":["One","Uno"]},{"answers":["Two"]}]""")
        , test "returns an empty list for malformed JSON" <|
            \_ -> Expect.equal [] (decodeQuestions "not json")
        , test "returns an empty list for valid JSON that doesn't match the shape" <|
            \_ -> Expect.equal [] (decodeQuestions """[{"wrong": "shape"}]""")
        ]


-- The client never sees quiz-questions.json at all (see #54/#70's review) -- it
-- lists assets/songs/ directly and orders the results with songOrder, purely
-- from each filename's leading number.
songOrderTests : Test
songOrderTests =
    describe "songOrder"
        [ test "sorts numerically, not lexicographically" <|
            \_ ->
                Expect.equal
                    [ "0.mp3", "1.mp3", "2.mp3", "10.mp3" ]
                    (songOrder [ "10.mp3", "2.mp3", "0.mp3", "1.mp3" ])
        , test "keeps each filename's extension (video vs audio) intact" <|
            \_ -> Expect.equal [ "0.mp3", "1.mp4" ] (songOrder [ "1.mp4", "0.mp3" ])
        , test "drops entries with no leading number (e.g. stray .DS_Store files)" <|
            \_ -> Expect.equal [ "0.mp3", "1.mp3" ] (songOrder [ "0.mp3", ".DS_Store", "1.mp3" ])
        , test "empty listing yields no questions" <|
            \_ -> Expect.equal [] (songOrder [])
        ]


songNumericPrefixTests : Test
songNumericPrefixTests =
    describe "songNumericPrefix"
        [ test "extracts the leading integer before the extension" <|
            \_ -> Expect.equal (Just 3) (songNumericPrefix "3.mp4")
        , test "Nothing for a filename with no leading number" <|
            \_ -> Expect.equal Nothing (songNumericPrefix ".DS_Store")
        , test "Nothing for a filename with no extension separator at all" <|
            \_ -> Expect.equal Nothing (songNumericPrefix "song")
        ]


-- getQuestion is fully generic (List a -> Int -> Maybe a) -- confirms it still
-- works positionally over the client's raw filename strings, same as it does
-- over the server's List Question.
getQuestionOnFilenamesTests : Test
getQuestionOnFilenamesTests =
    let
        songs =
            [ "a.mp3", "b.mp3" ]
    in
    describe "getQuestion on filenames"
        [ test "returns the entry at the given index" <|
            \_ -> Expect.equal (Just "b.mp3") (getQuestion songs 1)
        , test "returns Nothing when the index is out of range" <|
            \_ -> Expect.equal Nothing (getQuestion songs 10)
        ]
