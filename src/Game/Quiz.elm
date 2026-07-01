module Game.Quiz exposing (..)

import Char
import Json.Decode as Decode


-- ── Music Quiz Questions ──────────────────────────────────────────────────────
--
-- Each entry: song file in assets/ and the list of accepted answer strings.
-- Answers are compared case-insensitively after normalization (see `normalize`).
--
-- The question list itself lives in `quiz-questions.json` (repo root) so it can
-- be edited per-version without touching Elm source. It is loaded at startup via
-- the `readFile` port and decoded with `decodeQuestions` below.


type alias Question =
    { song : String
    , answers : List String
    }


questionDecoder : Decode.Decoder Question
questionDecoder =
    Decode.map2 Question
        (Decode.field "song" Decode.string)
        (Decode.field "answers" (Decode.list Decode.string))


decodeQuestions : String -> List Question
decodeQuestions raw =
    Decode.decodeString (Decode.list questionDecoder) raw
        |> Result.withDefault []


-- ── Helpers ───────────────────────────────────────────────────────────────────


getQuestion : List Question -> Int -> Maybe Question
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
