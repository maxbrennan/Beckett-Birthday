module Game.Quiz exposing (..)

import Char
import Json.Decode as Decode


-- ── Music Quiz Questions ──────────────────────────────────────────────────────
--
-- Each entry: the list of accepted answer strings for one quiz slide. There's no
-- `song` field -- assets/songs/ files are named numerically (0.mp3, 1.mp3, ...,
-- see songOrder below), and a question's position in this array *is* its song's
-- index, so the array order is the single source of truth for both sides.
--
-- The question list itself lives in the `quizQuestions` field of
-- `config/app-config.json` so it can be edited per-version without touching Elm
-- source. Only Server.elm reads it (via the `readFile` port and
-- `decodeQuestions`) -- nothing under config/ is bundled into the client at all
-- (see #35, #54, #70's review). The client instead lists assets/songs/ directly
-- (via the readDir port) and orders the results with songOrder, so it never
-- sees an answer.


type alias Question =
    { answers : List String }


questionDecoder : Decode.Decoder Question
questionDecoder =
    Decode.map Question (Decode.field "answers" (Decode.list Decode.string))


decodeQuestions : String -> List Question
decodeQuestions raw =
    Decode.decodeString (Decode.field "quizQuestions" (Decode.list questionDecoder)) raw
        |> Result.withDefault []


-- ── Client-side song ordering ────────────────────────────────────────────────
-- The client never sees quiz-questions.json. It lists assets/songs/ (readDir)
-- and derives play order purely from each filename's leading number -- "0.mp3"
-- is slide 0, "3.mp4" is slide 3, etc. Anything that doesn't start with a
-- number (stray files like .DS_Store) is dropped rather than guessed at.


songNumericPrefix : String -> Maybe Int
songNumericPrefix filename =
    filename
        |> String.split "."
        |> List.head
        |> Maybe.andThen String.toInt


songOrder : List String -> List String
songOrder filenames =
    filenames
        |> List.filterMap (\f -> songNumericPrefix f |> Maybe.map (\n -> ( n, f )))
        |> List.sortBy Tuple.first
        |> List.map Tuple.second


-- ── Helpers ───────────────────────────────────────────────────────────────────


getQuestion : List a -> Int -> Maybe a
getQuestion questions idx =
    List.head (List.drop idx questions)


normalize : String -> String
normalize s =
    s
        |> String.toLower
        |> String.replace "-" " "
        |> String.filter (\c -> Char.isAlphaNum c || c == ' ')
        |> String.words
        |> String.join " "


capitalize : String -> String
capitalize s =
    case String.uncons s of
        Just ( first, rest ) ->
            String.fromChar (Char.toUpper first) ++ rest

        Nothing ->
            s


isVideo : String -> Bool
isVideo filename =
    String.endsWith ".mp4" filename


-- Scoring decision for a submitted answer: is it right, and if so is there
-- another question after it or was this the last one.
type AnswerOutcome
    = NoQuestion
    | IncorrectAnswer
    | CorrectContinue Int
    | CorrectWin


decideAnswer : List Question -> Int -> String -> AnswerOutcome
decideAnswer questions idx answer =
    case getQuestion questions idx of
        Nothing ->
            NoQuestion

        Just q ->
            if List.any (\a -> normalize answer == normalize a) q.answers then
                let
                    nextIdx =
                        idx + 1
                in
                case getQuestion questions nextIdx of
                    Just _ ->
                        CorrectContinue nextIdx

                    Nothing ->
                        CorrectWin

            else
                IncorrectAnswer
