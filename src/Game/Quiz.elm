module Game.Quiz exposing (..)

import Char
import Json.Decode as Decode


-- ── Music Quiz Questions ──────────────────────────────────────────────────────
--
-- Each entry: song file in assets/songs/ and the list of accepted answer strings.
-- Answers are compared case-insensitively after normalization (see `normalize`).
--
-- The question list itself lives in `config/quiz-questions.json` so it can be
-- edited per-version without touching Elm source. Only Server.elm reads it (via
-- the `readFile` port and `decodeQuestions`) -- it is never bundled into the
-- client. The client instead loads `config/quiz-manifest.json` (song filenames
-- only, decoded with `decodeSongManifest` into `SongEntry`s), so answers never
-- leave the server (see #54).


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


-- The client-safe counterpart to Question: just the filename, no answers (see
-- #54). Loaded from config/quiz-manifest.json -- the only quiz config the
-- client ever reads. config/quiz-questions.json (song + answers) is read only
-- by the server.
type alias SongEntry =
    { song : String }


songEntryDecoder : Decode.Decoder SongEntry
songEntryDecoder =
    Decode.map SongEntry (Decode.field "song" Decode.string)


decodeSongManifest : String -> List SongEntry
decodeSongManifest raw =
    Decode.decodeString (Decode.list songEntryDecoder) raw
        |> Result.withDefault []


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
