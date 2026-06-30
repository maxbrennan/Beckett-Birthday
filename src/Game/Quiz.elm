module Game.Quiz exposing (..)

import Char


-- ── Music Quiz Questions ──────────────────────────────────────────────────────
--
-- Each entry: song file in assets/ and the list of accepted answer strings.
-- Answers are compared case-insensitively after normalization (see `normalize`).


type alias Question =
    { song : String
    , answers : List String
    }


questions : List Question
questions =
    [ { song = "baby-shark.mp3", answers = [ "Baby Shark (Hip Hip Version)", "Baby Shark Hip Hop", "Baby Shark Hip Hop Edition" ] }
    , { song = "manchild.mp3", answers = [ "Manchild" ] }
    , { song = "house-tour.mp3", answers = [ "House Tour" ] }
    , { song = "revenge.mp4", answers = [ "Revenge", "Revenge Parody", "Revenge a Minecraft Parody" ] }
    , { song = "style.mp3", answers = [ "Style" ] }
    , { song = "ready-for-it.mp3", answers = [ "...Ready For It?" ] }
    , { song = "tit-for-tat.mp3", answers = [ "TIT FOR TAT" ] }
    , { song = "sports-car.mp3", answers = [ "Sports car" ] }
    , { song = "revolving-door.mp3", answers = [ "Revolving door" ] }
    , { song = "korean.mp3", answers = [ "핑크판타지" ] }
    ]


-- ── Helpers ───────────────────────────────────────────────────────────────────


getQuestion : Int -> Maybe Question
getQuestion idx =
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
