port module Server exposing (..)

import Dict exposing (Dict)
import Game.IQTest as IQTest
import Game.Quiz exposing (AnswerOutcome(..), Question, capitalize, decideAnswer, getQuestion, questionDecoder)
import Json.Decode as Decode
import Json.Encode as Encode
import Platform
import Process
import Random
import Server.Distribution exposing (..)
import Server.Protocol exposing (..)
import Server.Registry exposing (..)
import Set exposing (Set)
import Task
import Time



type alias Model =
    { connectedPlayers : Dict String String
    , distClients : Dict String DistStage
    , registry : List RegistryEntry
    , pendingStateEdits : Set String
    , iqTimers : Dict String IqTimerState
    , seed : Random.Seed

    -- Server-owned quiz completion tracking (see acceptQuizAdvance/
    -- quizJustCompleted below): the furthest question index each uuid has been
    -- independently confirmed to have passed -- never from the client's own
    -- self-reported state. The true per-build question list/count lives on
    -- each uuid's own RegistryEntry.quizQuestions (see questionsForUuid), not
    -- here -- see #77.
    , quizProgress : Dict String Int

    -- Per-uuid confirmation that the song/video for this idx has actually
    -- finished playing (see ClientQuizSongEnded), required before
    -- ClientQuizAnswerSubmitted accepts an answer for the same idx -- a
    -- crafted client can no longer submit before any song plays. In memory
    -- only, deliberately never persisted to RegistryEntry/builds.json: a
    -- reconnect always re-derives BlankScreen and replays the song from
    -- scratch anyway (see ClientStateRequest clearing this on connect), so
    -- there is nothing worth surviving a restart for.
    , quizSongEnded : Dict String Int

    -- Per-uuid: a granted-but-not-yet-consumed IQ-test skip offer, mapping to the
    -- exact questionIdx it was granted for (see decideIqOffer / ClientIqFailed /
    -- ClientIqCaught). In memory only, deliberately never persisted: a reconnect
    -- always re-derives IQTestScreen/FakeFlashCaughtScreen fresh via deriveIqScreen,
    -- which can't reconstruct the transient offer/anim screens anyway, so there's
    -- nothing worth surviving a restart for -- same rationale as quizSongEnded above.
    -- Consumed by ClientQuizAdvanced when accepted (see the bypass there), or
    -- released by ClientIqOfferDeclined when declined.
    , iqOfferGrants : Dict String Int
    }


-- ── Session-timer server-side logic ──────────────────────────────────────────
-- The whole-game 7-day session deadline. The server is the sole owner of it (see
-- RegistryEntry.timerEndsAt): it establishes the value once, on a player's first
-- stateRequest, and independently decides expiry off its own clock (the `now`
-- carried on every MessageReceived -- see server/index.js's Date.now()) rather than
-- trusting the client's local clock at all.


-- Set to True to enable a short debug session length, matching the pattern in
-- Game.IQTest.debug.
debug : Bool
debug =
    False


timeLimitMs : Float
timeLimitMs =
    if debug then
        600000

    else
        7 * 24 * 60 * 60 * 1000


{-| Where a player is in the server-driven IQ test. The server owns all timing
and the whole ding/question count; the client only renders and reports raw input.
-}
type IqPhase
    = IqCounting -- pre-test countdown ticking down
    | IqAwaitingReady -- countdown done or a ding resolved; waiting for the client's iqReadyForDing
    | IqDingScheduled -- a random inter-ding delay is sleeping; ding not yet shown
    | IqDingShown -- a ding was emitted; waiting for the client to resolve it
    | IqIdleNotStarted -- never started this test yet, or an admin's edit:state edit reset it back to the begin screen
    | IqIdleCaught -- just caught the trap; waiting for the client to press Begin (iqStartCountdown) again after the fake-flash cutscene


{-| Per-player IQ-test state, keyed by **uuid** (the durable player identity, not
the ephemeral `clientId` a WebSocket connection gets) so it survives a
disconnect/reconnect. Persists across fail-restart, catch-restart, and a
disconnect within a session -- only test completion removes it. The client
never supplies the count -- the server initializes it to `iqQuestionCount` and
doubles it on a catch.

On disconnect the entry is *paused*, not dropped: `ClientDisconnected` bumps
`epoch` (invalidating any in-flight `Process.sleep`) and otherwise keeps every field,
*except* a disconnect while `phase == IqDingShown` is rewound to `IqDingScheduled`
(see `ClientDisconnected`) so a resume replays the ding rather than skipping past it.
`ClientIqResume` re-arms the appropriate schedule once the player is back and
has actually rendered the IQ screen again -- see `resumeIqTimer`.

**Persistence:** every live change to this state is
also mirrored into the player's `RegistryEntry.iqTimer` field in
`builds.json` (see `persistIqTimerInRegistry`/`setIqTimer`/`clearIqTimer`).
The player's screen is never cached alongside it -- it's synthesized fresh at
every connect, straight from this record, via `deriveIqScreen` (see
`ClientStateRequest`). This is what makes the client's IQ screen 100%
derivable from the server's own state instead of a second,
independently-drifting copy, and it's also what lets `init`/`FileRead`
rehydrate `iqTimers` after a full process restart (otherwise a restart would
silently reset a mid-punishment-phase player back to the baseline count). The
IQ test was the first game phase moved to this pattern; the quiz-slide phase
now follows it via `deriveQuizScreen`/`persistQuizScreenInRegistry`, driven by
the far smaller server-owned `Model.quizProgress` instead of a state record
like this one.
-}
type alias IqTimerState =
    { epoch : Int -- bumped on every start; stale Process.sleep fires are ignored
    , phase : IqPhase
    , questionIdx : Int -- which overall trivia slide this IQ test belongs to; not a cheat vector, purely for display continuity
    , countdownRemaining : Int
    , dingCount : Int -- real dings cleared so far
    , totalDings : Int -- target count; the punishment phase decrements this toward iqQuestionCount
    , fakeFlashPoint : Int -- server-chosen trap position
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    , lastDing : DingKind -- kind of the ding most recently emitted
    , dingDelay : Maybe Float -- the delay rolled for the ding currently in flight; Just while a wait is pending or its ding is shown (IqDingScheduled/IqDingShown), Nothing otherwise. Preserved across a disconnect so a resume replays the same wait instead of rolling a new one.
    }


{-| What the server most recently flashed. A `TrapFake` is the one-time
catchable trap (pressing it triggers the penalty); a `PhaseFake` is a 50%-phase
fake (pressing it fails). Both are "fakes" for progression purposes.
-}
type DingKind
    = RealDing
    | TrapFake
    | PhaseFake


type Msg
    = ClientConnected String
    | ClientDisconnected String
    | MessageReceived { clientId : String, payload : Encode.Value, now : Float }
    | FileRead String (Result String String)
    | AuthCompleted { clientId : String, success : Bool, level : Int, uuid : String }
    | WriteFileCompleted { path : String, ok : Bool, error : Maybe String }
    | GotTime Time.Posix
    | CountdownStep { uuid : String, epoch : Int }
    | DingReady { uuid : String, epoch : Int }





-- ── IQ-test server-side logic ────────────────────────────────────────────────
-- Pure ports of the old client scoring, kept separate so they can be unit-tested.


{-| Classify the next ding. Mirrors the old client `DingOccurred` rule: the
one-time trap fires at `fakeFlashPoint` (until used), and once used only the 50%
phase produces fakes (on a coin flip).
-}
classifyDing : Bool -> IqTimerState -> DingKind
classifyDing coin s =
    if not s.fakeFlashUsed && not s.in50PercentPhase && s.dingCount == s.fakeFlashPoint then
        TrapFake

    else if s.in50PercentPhase && coin then
        PhaseFake

    else
        RealDing


dingIsFake : DingKind -> Bool
dingIsFake kind =
    kind /= RealDing


type ClearOutcome
    = Completed
    | Advanced { startLoud : Bool, state : IqTimerState }


{-| Advance the progression when the client reports the outstanding ding was
resolved (a real ding cleared, or a fake correctly ignored). Mirrors the old
client `SpaceBarPressed` scoring: a cleared fake marks the trap used; a cleared
real ding either grinds down the punishment total, or counts up toward the target
(triggering the loud gag on the 4th and completing at the target).
-}
advanceOnClear : IqTimerState -> ClearOutcome
advanceOnClear s =
    if dingIsFake s.lastDing then
        Advanced { startLoud = False, state = { s | fakeFlashUsed = True } }

    else if s.totalDings > IQTest.iqQuestionCount then
        let
            newTotal =
                s.totalDings - 1
        in
        Advanced
            { startLoud = False
            , state =
                { s
                    | totalDings = newTotal
                    , in50PercentPhase = s.in50PercentPhase || (newTotal == IQTest.iqQuestionCount)
                }
            }

    else
        let
            newDingCount =
                s.dingCount + 1
        in
        if newDingCount >= s.totalDings then
            Completed

        else
            Advanced
                { startLoud = newDingCount == IQTest.iqLoudDingThreshold
                , state = { s | dingCount = newDingCount }
                }


{-| Apply the fake-flash penalty: double the count (capped), re-arm the punishment
phase, and reset progress. Mirrors the old client `FfCounterOut` restart.
-}
applyCatch : IqTimerState -> IqTimerState
applyCatch s =
    { s
        | totalDings = Basics.min (s.totalDings * 2) IQTest.maxTotalDings
        , fakeFlashUsed = True
        , in50PercentPhase = False
        , dingCount = 0
    }


{-| Decide whether a qualifying fail (ClientIqFailed) or trap catch (ClientIqCaught)
grants the one-time skip offer: the build must not have it config-disabled, this
player must not have already been granted it once before (ever, regardless of
accept/decline -- see RegistryEntry.iqOfferUsed), and the run must have cleared at
least iqOfferMinDings real dings. totalDings always echoes back the count at the
moment of the fail/catch (already-doubled for a catch, since the caller passes
`applyCatch`'s output) so the caller can render the right N either way.
-}
decideIqOffer : { dingCountAtFail : Int, totalDingsAtFail : Int, offerDisabled : Bool, offerUsed : Bool } -> { granted : Bool, totalDings : Int }
decideIqOffer { dingCountAtFail, totalDingsAtFail, offerDisabled, offerUsed } =
    { granted = not offerDisabled && not offerUsed && dingCountAtFail >= IQTest.iqOfferMinDings
    , totalDings = totalDingsAtFail
    }


-- ── Quiz-progress server-side logic ──────────────────────────────────────────
-- Server-authoritative gate for the win screen: the server only trusts an
-- explicit, monotonic sequence of quizAdvanced events -- never the freeform
-- client-reported `state.screen` -- to decide when a player has passed every
-- question. See RegistryEntry.quizProgress and Model.quizProgress.
-- The same confirmed progress also drives the persisted quiz-slide screen
-- (deriveQuizScreen/persistQuizScreenInRegistry below), mirroring the IQ
-- test's deriveIqScreen pattern, so a self-reported quiz slide can't drift
-- from what the player has actually earned.


{-| The connecting player's own build's quiz questions, resolved from their
RegistryEntry.quizQuestions blob (sent at deploy time -- see #77). Never a
global list: two different builds' answers can, and should, differ.
-}
questionsForUuid : String -> List RegistryEntry -> List Question
questionsForUuid uuid registry =
    registry
        |> List.filter (\e -> e.uuid == uuid)
        |> List.head
        |> Maybe.andThen .quizQuestions
        |> Maybe.andThen (Decode.decodeValue (Decode.list questionDecoder) >> Result.toMaybe)
        |> Maybe.withDefault []


{-| Accept an incoming quizAdvanced idx only if it's exactly the next one this
player is expected to report -- replays (idx < current) and skips
(idx > current) are rejected, so a crafted client can't jump straight to "done".
-}
acceptQuizAdvance : { current : Int, idx : Int } -> Maybe Int
acceptQuizAdvance { current, idx } =
    if idx == current then
        Just (current + 1)

    else
        Nothing


{-| True when the player has a live IQ-timer entry (including `IqIdleCaught`,
"waiting to restart") -- i.e., mid-penalty. Both quiz-progression entry
points (`ClientQuizAdvanced` and `ClientQuizAnswerSubmitted`) are unexpected
while this holds: the honest client's quiz screens never render during the
IQ test, so a live entry means a crafted client is trying to advance
concurrently with (or instead of) serving the penalty. `clearIqTimer` already
removes the entry before the legitimate `quizAdvanced`/`quizAnswerSubmitted`
sent right after a genuine test completion, so this never blocks the honest
flow (see #73/#75).
-}
quizBlockedByLiveIqTimer : String -> Model -> Bool
quizBlockedByLiveIqTimer uuid model =
    Dict.member uuid model.iqTimers


{-| True once the player's confirmed progress has reached the real question
count. `total <= 0` (config unread/unreadable) can never be "complete" -- a
fail-safe default, not a trivially satisfiable edge case.
-}
quizJustCompleted : { next : Int, total : Int } -> Bool
quizJustCompleted { next, total } =
    total > 0 && next == total


{-| Project a player's confirmed quiz progress onto the exact JSON shape
`Sync.elm`'s `encodeScreen` produces for `BlankScreen`, so the persisted
quiz-slide screen can be derived from server state instead of the client's own
report (the quiz analogue of `deriveIqScreen`). `BlankScreen progress` is the
start of the slide the player has earned but not yet passed -- the client
replays that slide's song/video from the top on resume, deliberately
collapsing finer-grained transient state (a typed-but-unsubmitted answer, a
mid-playback position, a wrong-answer reveal) that only ever existed
client-side. `Nothing` when progress is out of the playable range: at or past
`total` the quiz is complete and the client's own `WinScreen` report stays
authoritative (`BlankScreen total` names no question and would strand the
player on a slide with nothing to play), and `total <= 0` means the question
config was never read -- same fail-safe convention as `quizJustCompleted`.
-}
deriveQuizScreen : { progress : Int, total : Int } -> Maybe Encode.Value
deriveQuizScreen { progress, total } =
    if 0 <= progress && progress < total then
        Just <|
            Encode.object
                [ ( "tag", Encode.string "BlankScreen" )
                , ( "idx", Encode.int progress )
                ]

    else
        Nothing


{-| Project session expiry onto the exact JSON shape `Sync.elm`'s `encodeScreen`
produces for `TimedOutScreen`, so an expired session is derivable the same way
as the IQ/quiz families rather than waiting on the client's own next
self-report of `TimedOutScreen` to persist it.
-}
deriveTimedOutScreen : Float -> RegistryEntry -> Maybe Encode.Value
deriveTimedOutScreen now entry =
    if isExpired now entry then
        Just (Encode.object [ ( "tag", Encode.string "TimedOutScreen" ) ])

    else
        Nothing


{-| Project quiz completion onto the exact JSON shape `Sync.elm`'s `encodeScreen`
produces for `WinScreen`, embedding the real, already-verified win text
directly -- safe because this only ever derives once `quizJustCompleted` is
independently confirmed server-side. This is what makes the value persisted
here (and delivered on reconnect via `ClientStateRequest`) correct without any
separate re-send message; the *live* win moment is a different, untouched code
path that still uses the standalone `winTextEnvelope` (see Server.elm's
`ClientQuizAdvanced`/`ClientQuizAnswerSubmitted` handlers).
-}
deriveWinScreen : String -> { progress : Int, total : Int } -> Maybe Encode.Value
deriveWinScreen winText { progress, total } =
    if quizJustCompleted { next = progress, total = total } then
        Just (Encode.object [ ( "tag", Encode.string "WinScreen" ), ( "text", Encode.string winText ) ])

    else
        Nothing


{-| `deriveQuizScreen`, falling back to `deriveWinScreen` once progress has
reached the end -- the one combined function that covers every derivable state
of the quiz-progress family, from the first slide through the win screen.
-}
deriveQuizOrWinScreen : String -> { progress : Int, total : Int } -> Maybe Encode.Value
deriveQuizOrWinScreen winText args =
    case deriveQuizScreen args of
        Just screen ->
            Just screen

        Nothing ->
            deriveWinScreen winText args


{-| The screen tags whose persisted value is server-derived via
`deriveQuizScreen` rather than trusted from the client's report. Matched
against `innermostScreenTag` so a quiz slide can't hide inside the
`CheckingAnswerScreen`/`ConfirmingAnswerScreen` wrappers.
-}
quizSlideTags : List String
quizSlideTags =
    [ "BlankScreen", "VideoScreen", "QuestionScreen", "WrongAnswerScreen" ]


{-| The reported screen's tag, unwrapped through any
`CheckingAnswerScreen`/`ConfirmingAnswerScreen`/`BeginScreen` `nextScreen`
nesting (the serialized mirror of `Main.elm`'s `innerBlankIdx`). "" when
there's no decodable tag, which no screen family matches. The persisted/
self-reported state *is* the screen's own JSON directly (see Sync.elm's
encodeModel), so this operates on `stateValue` with no indirection.
-}
innermostScreenTag : Encode.Value -> String
innermostScreenTag stateValue =
    unwrapScreenTag stateValue


unwrapScreenTag : Encode.Value -> String
unwrapScreenTag screenValue =
    case Decode.decodeValue (Decode.field "tag" Decode.string) screenValue of
        Ok tag ->
            if tag == "CheckingAnswerScreen" || tag == "ConfirmingAnswerScreen" || tag == "BeginScreen" then
                Decode.decodeValue (Decode.field "nextScreen" Decode.value) screenValue
                    |> Result.map unwrapScreenTag
                    |> Result.withDefault ""

            else
                tag

        Err _ ->
            ""


{-| Record a confirmed quiz advance in a player's registry row: just the
progress counter -- the player's screen is never cached, it's synthesized
fresh at connect time from this counter (see `ClientStateRequest`).
-}
persistQuizScreenInRegistry : String -> { next : Int, total : Int } -> List RegistryEntry -> List RegistryEntry
persistQuizScreenInRegistry uuid { next } registry =
    updateEntryQuizProgress uuid next registry


{-| Project an IqTimerState onto the exact JSON shape `Sync.elm`'s `encodeScreen`
produces for `IQTestCountdownScreen`/`IQTestActiveScreen`/`IQTestScreen`/
`FakeFlashCaughtScreen`, so the persisted registry row can be derived from
server state instead of the client's own report.

Known, deliberate imprecision: `isFlashing`/`loudPlaying` don't track the
client's local 250ms flash animation or the 3s `StartLoudMusic` delay -- they
only matter for the brief window before `resumeIqTimer` re-syncs a
reconnecting client, which was already imprecise before this change. Likewise,
`IqIdleCaught` always derives the fake-flash-caught cutscene restarted at its
first sub-phase (`FfDelay`) rather than whatever sub-phase the client's local
animation had actually reached -- a reconnect mid-cutscene replays the cutscene
from the top instead of resuming it precisely, the same category of accepted
coarse-resume trade as the quiz-slide family's `WrongAnswerScreen` collapse
(see `deriveQuizScreen`).
-}
deriveIqScreen : IqTimerState -> Maybe Encode.Value
deriveIqScreen state =
    case state.phase of
        IqCounting ->
            Just <|
                Encode.object
                    [ ( "tag", Encode.string "IQTestCountdownScreen" )
                    , ( "state"
                      , Encode.object
                            [ ( "questionIdx", Encode.int state.questionIdx )
                            , ( "totalDings", Encode.int state.totalDings )
                            , ( "countdown", Encode.int state.countdownRemaining )
                            ]
                      )
                    ]

        IqAwaitingReady ->
            Just (deriveIqActiveScreen state { isFlashing = False, dingActive = False, fakeFlashActive = False, fakeIsTrap = False })

        IqDingScheduled ->
            Just (deriveIqActiveScreen state { isFlashing = False, dingActive = False, fakeFlashActive = False, fakeIsTrap = False })

        IqDingShown ->
            Just <|
                deriveIqActiveScreen state
                    { isFlashing = True
                    , dingActive = state.lastDing == RealDing
                    , fakeFlashActive = state.lastDing /= RealDing
                    , fakeIsTrap = state.lastDing == TrapFake
                    }

        IqIdleNotStarted ->
            Just <|
                Encode.object
                    [ ( "tag", Encode.string "IQTestScreen" )
                    , ( "state"
                      , Encode.object
                            [ ( "questionIdx", Encode.int state.questionIdx )
                            , ( "totalDings", Encode.int state.totalDings )
                            ]
                      )
                    ]

        IqIdleCaught ->
            let
                -- state.totalDings/dingCount were already updated by applyCatch (doubled/
                -- reset) before phase became IqIdleCaught, so the pre-catch values the
                -- client's own CaughtTrap construction used aren't recoverable exactly --
                -- halving the post-catch total approximates the original, and the
                -- numerator is fine at 0 since the restarted cutscene doesn't render it
                -- until well past FfDelay anyway.
                originalTotal =
                    state.totalDings // 2
            in
            Just <|
                Encode.object
                    [ ( "tag", Encode.string "FakeFlashCaughtScreen" )
                    , ( "state"
                      , Encode.object
                            [ ( "questionIdx", Encode.int state.questionIdx )
                            , ( "originalTotal", Encode.int originalTotal )
                            , ( "displayNumerator", Encode.int 0 )
                            , ( "displayDenominator", Encode.int originalTotal )
                            , ( "phase", Encode.string "FfDelay" )
                            ]
                      )
                    ]


deriveIqActiveScreen : IqTimerState -> { isFlashing : Bool, dingActive : Bool, fakeFlashActive : Bool, fakeIsTrap : Bool } -> Encode.Value
deriveIqActiveScreen state flags =
    Encode.object
        [ ( "tag", Encode.string "IQTestActiveScreen" )
        , ( "state"
          , Encode.object
                [ ( "questionIdx", Encode.int state.questionIdx )
                , ( "dingCount", Encode.int state.dingCount )
                , ( "totalDings", Encode.int state.totalDings )
                , ( "isFlashing", Encode.bool flags.isFlashing )
                , ( "dingActive", Encode.bool flags.dingActive )
                , ( "fakeFlashActive", Encode.bool flags.fakeFlashActive )
                , ( "fakeIsTrap", Encode.bool flags.fakeIsTrap )
                , ( "loudPlaying", Encode.bool (state.dingCount >= IQTest.iqLoudDingThreshold) )
                ]
          )
        ]


encodeIqPhase : IqPhase -> Encode.Value
encodeIqPhase phase =
    Encode.string <|
        case phase of
            IqCounting ->
                "IqCounting"

            IqAwaitingReady ->
                "IqAwaitingReady"

            IqDingScheduled ->
                "IqDingScheduled"

            IqDingShown ->
                "IqDingShown"

            IqIdleNotStarted ->
                "IqIdleNotStarted"

            IqIdleCaught ->
                "IqIdleCaught"


decodeIqPhase : Decode.Decoder IqPhase
decodeIqPhase =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "IqCounting" ->
                        Decode.succeed IqCounting

                    "IqAwaitingReady" ->
                        Decode.succeed IqAwaitingReady

                    "IqDingScheduled" ->
                        Decode.succeed IqDingScheduled

                    "IqDingShown" ->
                        Decode.succeed IqDingShown

                    "IqIdleNotStarted" ->
                        Decode.succeed IqIdleNotStarted

                    "IqIdleCaught" ->
                        Decode.succeed IqIdleCaught

                    -- Back-compat: a row persisted before the IqIdle split. Treated as
                    -- "not started" rather than "caught" -- the one accepted trade-off is
                    -- that a player genuinely mid-cutscene at the moment this ships sees
                    -- the plain begin screen instead of a cutscene replay on their next
                    -- resume. One-time migration shim, safe to remove after a deploy cycle.
                    "IqIdle" ->
                        Decode.succeed IqIdleNotStarted

                    _ ->
                        Decode.fail ("unknown IqPhase: " ++ s)
            )


encodeDingKind : DingKind -> Encode.Value
encodeDingKind kind =
    Encode.string <|
        case kind of
            RealDing ->
                "RealDing"

            TrapFake ->
                "TrapFake"

            PhaseFake ->
                "PhaseFake"


decodeDingKind : Decode.Decoder DingKind
decodeDingKind =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "RealDing" ->
                        Decode.succeed RealDing

                    "TrapFake" ->
                        Decode.succeed TrapFake

                    "PhaseFake" ->
                        Decode.succeed PhaseFake

                    _ ->
                        Decode.fail ("unknown DingKind: " ++ s)
            )


{-| Full round-trip codec for the registry's `iqTimer` snapshot -- every field,
including the two never visible to the client at all (`fakeFlashUsed`,
`in50PercentPhase`). This is what a restart rehydrates from (see
`init`/`FileRead`), so it must capture everything `deriveIqScreen` can't.
-}
encodeIqTimerStateFull : IqTimerState -> Encode.Value
encodeIqTimerStateFull state =
    Encode.object
        [ ( "epoch", Encode.int state.epoch )
        , ( "phase", encodeIqPhase state.phase )
        , ( "questionIdx", Encode.int state.questionIdx )
        , ( "countdownRemaining", Encode.int state.countdownRemaining )
        , ( "dingCount", Encode.int state.dingCount )
        , ( "totalDings", Encode.int state.totalDings )
        , ( "fakeFlashPoint", Encode.int state.fakeFlashPoint )
        , ( "fakeFlashUsed", Encode.bool state.fakeFlashUsed )
        , ( "in50PercentPhase", Encode.bool state.in50PercentPhase )
        , ( "lastDing", encodeDingKind state.lastDing )
        , ( "dingDelay", state.dingDelay |> Maybe.map Encode.float |> Maybe.withDefault Encode.null )
        ]


decodeIqTimerStateFull : Decode.Decoder IqTimerState
decodeIqTimerStateFull =
    Decode.map8
        (\epoch phase questionIdx countdownRemaining dingCount totalDings fakeFlashPoint fakeFlashUsed ->
            \in50PercentPhase lastDing dingDelay ->
                { epoch = epoch
                , phase = phase
                , questionIdx = questionIdx
                , countdownRemaining = countdownRemaining
                , dingCount = dingCount
                , totalDings = totalDings
                , fakeFlashPoint = fakeFlashPoint
                , fakeFlashUsed = fakeFlashUsed
                , in50PercentPhase = in50PercentPhase
                , lastDing = lastDing
                , dingDelay = dingDelay
                }
        )
        (Decode.field "epoch" Decode.int)
        (Decode.field "phase" decodeIqPhase)
        (Decode.field "questionIdx" Decode.int)
        (Decode.field "countdownRemaining" Decode.int)
        (Decode.field "dingCount" Decode.int)
        (Decode.field "totalDings" Decode.int)
        (Decode.field "fakeFlashPoint" Decode.int)
        (Decode.field "fakeFlashUsed" Decode.bool)
        |> Decode.andThen
            (\partial ->
                Decode.map3 partial
                    (Decode.field "in50PercentPhase" Decode.bool)
                    (Decode.field "lastDing" decodeDingKind)
                    (Decode.oneOf
                        [ Decode.field "dingDelay" (Decode.nullable Decode.float)
                        , Decode.succeed Nothing
                        ]
                    )
            )


{-| Projects one player's authoritative IqTimerState onto their registry row's
`iqTimer` field (so `init`/`FileRead` can rehydrate `iqTimers` after a
restart). `Nothing` clears it -- the player's screen is never cached, it's
synthesized fresh at connect time from this field (see `ClientStateRequest`);
`persistQuizScreenInRegistry` is the quiz-slide counterpart.
-}
persistIqTimerInRegistry : String -> Maybe IqTimerState -> List RegistryEntry -> List RegistryEntry
persistIqTimerInRegistry uuid maybeState registry =
    updateEntryIqTimer uuid (Maybe.map encodeIqTimerStateFull maybeState) registry


{-| Record a live IqTimerState change both in-memory and in the registry (so it
survives a restart). Returns the `writeRegistry` Cmd to batch alongside
whatever else the caller already returns.
-}
setIqTimer : String -> IqTimerState -> Model -> ( Model, Cmd Msg )
setIqTimer uuid state model =
    let
        newRegistry =
            persistIqTimerInRegistry uuid (Just state) model.registry
    in
    ( { model | iqTimers = Dict.insert uuid state model.iqTimers, registry = newRegistry }
    , writeRegistry newRegistry
    )


{-| The test finished (or was otherwise abandoned): drop the in-memory entry and
clear the persisted snapshot too, so a restart doesn't try to rehydrate it.
-}
clearIqTimer : String -> Model -> ( Model, Cmd Msg )
clearIqTimer uuid model =
    let
        newRegistry =
            persistIqTimerInRegistry uuid Nothing model.registry
    in
    ( { model | iqTimers = Dict.remove uuid model.iqTimers, registry = newRegistry }
    , writeRegistry newRegistry
    )


-- Send a payload to a player's *current* connection, resolved live via
-- connectedPlayers (their clientId can change across a disconnect/reconnect).
-- Silently drops the send if the player isn't currently connected.
sendToPlayer : String -> Model -> Encode.Value -> Cmd Msg
sendToPlayer uuid model payload =
    case Dict.get uuid model.connectedPlayers of
        Just clientId ->
            sendToClient { clientId = clientId, payload = payload }

        Nothing ->
            Cmd.none


scheduleCountdownStep : String -> Int -> Cmd Msg
scheduleCountdownStep uuid epoch =
    Process.sleep 1000
        |> Task.perform (\_ -> CountdownStep { uuid = uuid, epoch = epoch })


scheduleDing : String -> Int -> Float -> Cmd Msg
scheduleDing uuid epoch delay =
    Process.sleep delay
        |> Task.perform (\_ -> DingReady { uuid = uuid, epoch = epoch })


{-| Start (or restart) a player's countdown. The base count comes from the
server's own stored state -- the existing entry's `totalDings` (preserved across
fail/catch), or `iqQuestionCount` for the player's first start this session --
never from the client. Resets the run (fresh trap point, `dingCount` 0) while
preserving `fakeFlashUsed`/`in50PercentPhase`.
-}
startCountdown : String -> Model -> ( Model, Cmd Msg )
startCountdown uuid model =
    let
        prev =
            Dict.get uuid model.iqTimers

        baseTotal =
            prev |> Maybe.map .totalDings |> Maybe.withDefault IQTest.iqQuestionCount

        epoch =
            (prev |> Maybe.map .epoch |> Maybe.withDefault 0) + 1

        questionIdx =
            case prev of
                Just p ->
                    p.questionIdx

                Nothing ->
                    Dict.get uuid model.quizProgress |> Maybe.withDefault 0

        ( fakeFlashPoint, newSeed ) =
            Random.step (IQTest.fakeFlashPointGen baseTotal) model.seed

        newState =
            { epoch = epoch
            , phase = IqCounting
            , questionIdx = questionIdx
            , countdownRemaining = baseTotal
            , dingCount = 0
            , totalDings = baseTotal
            , fakeFlashPoint = fakeFlashPoint
            , fakeFlashUsed = prev |> Maybe.map .fakeFlashUsed |> Maybe.withDefault False
            , in50PercentPhase = prev |> Maybe.map .in50PercentPhase |> Maybe.withDefault False
            , lastDing = RealDing
            , dingDelay = Nothing
            }

        ( withTimer, persistCmd ) =
            setIqTimer uuid newState { model | seed = newSeed }
    in
    ( withTimer, Cmd.batch [ persistCmd, scheduleCountdownStep uuid epoch ] )


-- Schedule the next ding after a server-enforced random delay, moving the player
-- into the DingScheduled phase.
scheduleNextDing : String -> IqTimerState -> Model -> ( Model, Cmd Msg )
scheduleNextDing uuid state model =
    let
        ( delay, newSeed ) =
            Random.step IQTest.dingDelayGen model.seed

        ( withTimer, persistCmd ) =
            setIqTimer uuid { state | phase = IqDingScheduled, dingDelay = Just delay } { model | seed = newSeed }
    in
    ( withTimer
    , Cmd.batch [ persistCmd, scheduleDing uuid state.epoch delay ]
    )


{-| Re-arm a paused IQ timer once the player has reconnected *and* actually
rendered the corresponding IQ screen again (signalled by the client's
`iqResume`, sent right after `BeginPressed` flips `isBeginScreen` back off an
already-derived IQ screen). Bumping to a fresh epoch here isn't needed --
`ClientDisconnected` already bumped it, and nothing was scheduled against the
new epoch until now.

- `IqCounting`: resend the current tick immediately (so the UI doesn't wait up
  to 1s for the next natural tick) and re-arm the 1s loop.
- `IqDingScheduled`: replay the preserved `dingDelay` so the ding re-fires after
  exactly the same wait it would have without the disconnect, rather than rolling a
  new one. (`ClientDisconnected` rewinds an entry that was `IqDingShown` back to this
  phase, so a disconnect mid-ding also lands here -- see its docs.)
- `IqAwaitingReady`: nothing was ever rolled yet in this phase (the client hasn't sent
  `iqReadyForDing`) -- just arm the next ding with a fresh random delay.
- `IqDingShown`: resend the same ding fresh. In practice `ClientDisconnected` already
  rewinds any `IqDingShown` entry to `IqDingScheduled` before this ever runs, so this
  branch is a defensive fallback rather than a normally-reachable path.
- `IqIdleNotStarted`/`IqIdleCaught`: nothing to resume; the player will press
  Begin to send a fresh `iqStartCountdown`.
-}
resumeIqTimer : String -> Model -> ( Model, Cmd Msg )
resumeIqTimer uuid model =
    case Dict.get uuid model.iqTimers of
        Nothing ->
            ( model, Cmd.none )

        Just state ->
            case state.phase of
                IqCounting ->
                    ( model
                    , Cmd.batch
                        [ sendToPlayer uuid model (iqCountdownTickEnvelope state.countdownRemaining)
                        , scheduleCountdownStep uuid state.epoch
                        ]
                    )

                IqDingScheduled ->
                    case state.dingDelay of
                        Just delay ->
                            ( model, scheduleDing uuid state.epoch delay )

                        Nothing ->
                            -- Defensive fallback for entries persisted before this field existed.
                            scheduleNextDing uuid state model

                IqAwaitingReady ->
                    scheduleNextDing uuid state model

                IqDingShown ->
                    ( model
                    , sendToPlayer uuid
                        model
                        (iqDingEnvelope
                            { fake = dingIsFake state.lastDing
                            , trap = state.lastDing == TrapFake
                            , dingCount = state.dingCount
                            , totalDings = state.totalDings
                            }
                        )
                    )

                IqIdleNotStarted ->
                    ( model, Cmd.none )

                IqIdleCaught ->
                    ( model, Cmd.none )


writeRegistry : List RegistryEntry -> Cmd Msg
writeRegistry entries =
    writeFile
        { path = registryFilePath
        , contents = encodeRegistry entries
        , encoding = "utf8"
        , append = False
        }


{-| Remove a build after admin auth: drop it from the registry, kick any
connected player on that uuid, delete the file, persist, and ack the admin.
Runs only from AuthCompleted (post level-2 auth).
-}
performUndeploy : String -> String -> Model -> ( Model, Cmd Msg )
performUndeploy uuid clientId model =
    let
        maybePlayerClientId =
            Dict.get uuid model.connectedPlayers

        maybeTarget =
            model.registry
                |> List.filter (\e -> e.uuid == uuid)
                |> List.head

        newRegistry =
            List.filter (\e -> e.uuid /= uuid) model.registry
    in
    ( { model
        | registry = newRegistry
        , connectedPlayers = Dict.remove uuid model.connectedPlayers
        , distClients = Dict.remove clientId model.distClients
      }
    , Cmd.batch
        [ case maybePlayerClientId of
            Nothing ->
                Cmd.none

            Just playerClientId ->
                closeClient { clientId = playerClientId, reason = "admin undeployed build" }
        , case maybeTarget of
            Nothing ->
                Cmd.none

            Just target ->
                deleteBuildFile target.filename
        , writeRegistry newRegistry
        , sendToClient { clientId = clientId, payload = distUndeployAckEnvelope }
        ]
    )


{-| Open a build's state for editing after admin auth: mark it pending, kick any
connected player, hand the admin the whole merged server-state document
(winText, iqTimer, quizProgress, timerEndsAt, quizQuestions -- see
encodeServerStateFields; there is no separate screen field, since it's always
derived fresh from these), and move the admin into the EditingState stage
(which authorizes the following distStateEditSave). Runs only from
AuthCompleted (post level-2 auth).
-}
performStateEdit : String -> String -> Model -> ( Model, Cmd Msg )
performStateEdit uuid clientId model =
    let
        maybePlayerClientId =
            Dict.get uuid model.connectedPlayers

        maybeEntry =
            model.registry |> List.filter (\e -> e.uuid == uuid) |> List.head

        currentState =
            case maybeEntry of
                Just entry ->
                    encodeServerStateFields
                        { winText = entry.winText
                        , iqTimer = entry.iqTimer
                        , quizProgress = entry.quizProgress
                        , timerEndsAt = entry.timerEndsAt
                        , quizQuestions = entry.quizQuestions
                        , iqOfferUsed = entry.iqOfferUsed
                        }

                Nothing ->
                    Encode.object []

        newRegistry =
            setPendingStateEdit uuid model.registry
    in
    ( { model
        | pendingStateEdits = Set.insert uuid model.pendingStateEdits
        , registry = newRegistry
        , distClients = Dict.insert clientId (EditingState uuid) model.distClients
      }
    , Cmd.batch
        [ case maybePlayerClientId of
            Nothing ->
                Cmd.none

            Just playerClientId ->
                closeClient { clientId = playerClientId, reason = "admin editing state" }
        , writeRegistry newRegistry
        , stateEditReady { adminClientId = clientId, uuid = uuid, json = Encode.encode 0 currentState }
        ]
    )


init : () -> ( Model, Cmd Msg )
init () =
    ( { connectedPlayers = Dict.empty
      , distClients = Dict.empty
      , registry = []
      , pendingStateEdits = Set.empty
      , iqTimers = Dict.empty
      , seed = Random.initialSeed 0
      , quizProgress = Dict.empty
      , quizSongEnded = Dict.empty
      , iqOfferGrants = Dict.empty
      }
    , Cmd.batch
        [ readFile registryFilePath
        , Task.perform GotTime Time.now
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ClientConnected _ ->
            ( model, Cmd.none )

        ClientDisconnected clientId ->
            let
                cleanedDist =
                    Dict.remove clientId model.distClients

                maybeUuid =
                    findUuidByClient clientId model.connectedPlayers
            in
            case maybeUuid of
                Nothing ->
                    ( { model | distClients = cleanedDist }, Cmd.none )

                Just uuid ->
                    let
                        -- Leave the player's persisted state exactly as it was. The
                        -- jeopardy snapshot (isBeginScreen -> True) now happens lazily
                        -- on their next stateRequest (see ClientStateRequest below), so
                        -- a server stop/restart that never fires a disconnect still
                        -- resumes the player correctly.
                        baseModel =
                            { model
                                | connectedPlayers = Dict.remove uuid model.connectedPlayers
                                , distClients = cleanedDist
                            }
                    in
                    case Dict.get uuid model.iqTimers of
                        Just s ->
                            if s.phase == IqDingShown then
                                -- Disconnecting while a ding is shown and unresolved
                                -- rewinds it, not just pauses it: phase goes back to
                                -- IqDingScheduled so the resume (resumeIqTimer) replays
                                -- dingDelay's preserved wait and the ding re-fires as if
                                -- it hadn't happened yet, rather than the player either
                                -- dodging it or seeing it resent immediately.
                                setIqTimer uuid { s | epoch = s.epoch + 1, phase = IqDingScheduled } baseModel

                            else
                                -- Pause (don't drop) the live IQ timer: bump its epoch
                                -- so any in-flight Process.sleep becomes a stale no-op
                                -- when it fires, but keep every other field so a
                                -- reconnect (ClientIqResume) picks up exactly where
                                -- they left off.
                                ( { baseModel | iqTimers = Dict.insert uuid { s | epoch = s.epoch + 1 } model.iqTimers }, Cmd.none )

                        Nothing ->
                            ( baseModel, Cmd.none )

        MessageReceived { clientId, payload, now } ->
            case Decode.decodeValue decodeClientEnvelope payload of
                Ok (ClientStateRequest uuid) ->
                    if Set.member uuid model.pendingStateEdits then
                        ( model
                        , rejectAndClose { clientId = clientId, reason = "state is being edited by admin", payload = rejectEnvelope "state is being edited by admin" }
                        )

                    else if Dict.member uuid model.connectedPlayers then
                        ( model
                        , rejectAndClose { clientId = clientId, reason = "duplicate uuid", payload = rejectEnvelope "player already connected" }
                        )

                    else
                        case List.filter (\e -> e.uuid == uuid) model.registry of
                            [] ->
                                ( model
                                , rejectAndClose { clientId = clientId, reason = "unknown uuid", payload = rejectEnvelope "unknown uuid" }
                                )

                            entry :: _ ->
                                let
                                    connectedModel =
                                        { model
                                            | connectedPlayers = Dict.insert uuid clientId model.connectedPlayers
                                            -- Force a fresh song-ended confirmation after every
                                            -- reconnect, since the song replays from scratch
                                            -- client-side -- a stale entry from before the
                                            -- disconnect must not let a submit skip the replay.
                                            , quizSongEnded = Dict.remove uuid model.quizSongEnded
                                        }

                                    -- Establish the session deadline on this player's very
                                    -- first stateRequest ever; every later one just reuses
                                    -- whatever's already on file (see RegistryEntry.timerEndsAt).
                                    deadline =
                                        Maybe.withDefault (now + timeLimitMs) entry.timerEndsAt

                                    registryWithTimer =
                                        updateEntryTimer uuid deadline model.registry
                                in
                                if isExpired now { entry | timerEndsAt = Just deadline } then
                                    -- The server's own clock says this session is already over.
                                    -- Reply with only the timeout push -- never combined with a
                                    -- stateEnvelope in the same batch, since the client's
                                    -- stateEnvelope handling can set `screen` too and whichever
                                    -- message the client processed second would win (see the
                                    -- same ordering note on the ClientStateUpdate branch below).
                                    ( { connectedModel | registry = registryWithTimer }
                                    , Cmd.batch
                                        [ writeRegistry registryWithTimer
                                        , sendToClient { clientId = clientId, payload = timedOutEnvelope }
                                        ]
                                    )

                                else
                                    let
                                        total =
                                            List.length (questionsForUuid uuid model.registry)

                                        progress =
                                            Dict.get uuid model.quizProgress |> Maybe.withDefault 0

                                        -- Every player-facing screen is synthesized fresh here,
                                        -- straight from the server's own authoritative fields --
                                        -- there is nothing cached to read back (see RegistryEntry's
                                        -- doc comment). A live iqTimer entry always wins (mirrors the
                                        -- old ClientStateUpdate override-chain priority); otherwise
                                        -- fall back to the quiz-progress family. `progress >= total`
                                        -- (not just `==`) is deliberately more lenient than
                                        -- `quizJustCompleted` here -- extra insurance so a build
                                        -- replacement that changes the question count still resolves
                                        -- an already-earned win, on top of the mandatory admin
                                        -- edit:state reconcile that already gates every replacement.
                                        derived =
                                            case Dict.get uuid model.iqTimers of
                                                Just iqState ->
                                                    deriveIqScreen iqState

                                                Nothing ->
                                                    if total > 0 && progress >= total then
                                                        Just (Encode.object [ ( "tag", Encode.string "WinScreen" ), ( "text", Encode.string entry.winText ) ])

                                                    else
                                                        case deriveQuizOrWinScreen entry.winText { progress = progress, total = total } of
                                                            Just s ->
                                                                Just s

                                                            Nothing ->
                                                                -- Config unread/misconfigured (total <= 0):
                                                                -- mirrors Sync.elm's own decodeModel default
                                                                -- for a brand-new/undecodable player.
                                                                Just (Encode.object [ ( "tag", Encode.string "BlankScreen" ), ( "idx", Encode.int 0 ) ])

                                        -- Always wrap in BeginScreen: pressing Begin unwraps it
                                        -- locally with no round trip (see Main.elm's
                                        -- BeginPressed), and there's no idempotency risk since
                                        -- nothing derived above is ever itself BeginScreen-tagged.
                                        wrapped =
                                            Encode.object
                                                [ ( "tag", Encode.string "BeginScreen" )
                                                , ( "nextScreen", derived |> Maybe.withDefault (Encode.object []) )
                                                ]
                                    in
                                    ( { connectedModel | registry = registryWithTimer }
                                    , Cmd.batch
                                        [ writeRegistry registryWithTimer
                                        , sendToClient { clientId = clientId, payload = stateEnvelope wrapped }
                                        , sendToClient { clientId = clientId, payload = timerSyncEnvelope deadline }
                                        ]
                                    )

                Ok (ClientStateUpdate _) ->
                    -- The client's self-reported screen is no longer inspected or
                    -- persisted at all -- every screen that matters is synthesized fresh
                    -- from iqTimer/quizProgress/winText/quizQuestions/timerEndsAt at
                    -- connect time (see ClientStateRequest above), so there's nothing
                    -- left here to cache or correct. This message still arrives roughly
                    -- once a second as a liveness heartbeat; all that's left to do with
                    -- it is the same expiry check ClientStateRequest does.
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            let
                                expired =
                                    model.registry
                                        |> List.filter (\e -> e.uuid == uuid)
                                        |> List.head
                                        |> Maybe.map (isExpired now)
                                        |> Maybe.withDefault False
                            in
                            ( model
                            , sendToClient
                                { clientId = clientId
                                , payload =
                                    if expired then
                                        timedOutEnvelope

                                    else
                                        stateUpdateAckEnvelope
                                }
                            )

                Ok (ClientDistRegister info) ->
                    ( { model | distClients = Dict.insert clientId (AwaitingAuth info) model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok (ClientDistUpload upload) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == upload.uuid then
                                let
                                    binPath =
                                        "app-builds/" ++ upload.filename

                                    writeChunk =
                                        writeFile
                                            { path = binPath
                                            , contents = upload.contentsBase64
                                            , encoding = "base64"
                                            , append = upload.chunkIndex > 0
                                            }
                                in
                                if upload.isLast then
                                    let
                                        newEntry =
                                            { uuid = upload.uuid
                                            , filename = upload.filename
                                            , platform = info.platform
                                            , pendingStateEdit = False
                                            , winText = ""
                                            , iqTimer = Nothing
                                            , quizProgress = 0
                                            , timerEndsAt = Nothing

                                            -- Placeholder: this entry is a provisional row created
                                            -- right after the last upload chunk, immediately
                                            -- superseded by ClientDistComplete's own entry (same
                                            -- filename, filtered out below) once that message
                                            -- arrives with the real winText/quizQuestions/
                                            -- iqOfferDisabled.
                                            , quizQuestions = Nothing
                                            , iqOfferDisabled = False
                                            , iqOfferUsed = False
                                            }

                                        newRegistry =
                                            List.filter (\e -> e.filename /= upload.filename) model.registry
                                                ++ [ newEntry ]
                                    in
                                    ( { model
                                        | distClients = Dict.remove clientId model.distClients
                                        , registry = newRegistry
                                      }
                                    , Cmd.batch
                                        [ writeChunk
                                        , writeRegistry newRegistry
                                        , sendToClient { clientId = clientId, payload = distUploadAckEnvelope }
                                        ]
                                    )

                                else
                                    ( model, writeChunk )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ClientDistComplete { uuid, filename, winText, quizQuestions, iqOfferDisabled }) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == uuid then
                                let
                                    newEntry =
                                        { uuid = uuid
                                        , filename = filename
                                        , platform = info.platform
                                        , pendingStateEdit = False
                                        , winText = winText
                                        , iqTimer = Nothing
                                        , quizProgress = 0
                                        , timerEndsAt = Nothing
                                        , quizQuestions = Just quizQuestions
                                        , iqOfferDisabled = iqOfferDisabled
                                        , iqOfferUsed = False
                                        }

                                    newRegistry =
                                        List.filter (\e -> e.filename /= filename) model.registry
                                            ++ [ newEntry ]
                                in
                                ( { model
                                    | distClients = Dict.remove clientId model.distClients
                                    , registry = newRegistry
                                  }
                                , Cmd.batch
                                    [ writeRegistry newRegistry
                                    , sendToClient { clientId = clientId, payload = distCompleteAckEnvelope }
                                    ]
                                )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ClientDistStateEdit uuid) ->
                    -- Gate behind admin auth: stash the target uuid and request a
                    -- level-2 challenge. The actual edit prep runs in AuthCompleted
                    -- (performStateEdit) only after auth succeeds.
                    ( { model | distClients = Dict.insert clientId (AwaitingStateEditAuth uuid) model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok (ClientDistStateEditSave { json }) ->
                    -- Authorization is owned here (replaces the JS activeStateEdits set):
                    -- only a client in the EditingState stage may save, and the stage is
                    -- consumed on every save attempt (valid or invalid), mirroring the old
                    -- JS behavior. Invalid JSON therefore leaves the uuid stuck in
                    -- pendingStateEdits -- a pre-existing quirk (see tests/edit-state.test.js).
                    case Dict.get clientId model.distClients of
                        Just (EditingState editUuid) ->
                            let
                                clearedDist =
                                    Dict.remove clientId model.distClients
                            in
                            case Decode.decodeString decodeServerStateFields json of
                                Ok edited ->
                                    let
                                        newRegistry =
                                            model.registry
                                                |> List.map
                                                    (\e ->
                                                        if e.uuid == editUuid then
                                                            { e
                                                                | pendingStateEdit = False
                                                                , winText = edited.winText
                                                                , iqTimer = edited.iqTimer
                                                                , quizProgress = edited.quizProgress
                                                                , timerEndsAt = edited.timerEndsAt
                                                                , quizQuestions = edited.quizQuestions
                                                                , iqOfferUsed = edited.iqOfferUsed
                                                            }

                                                        else
                                                            e
                                                    )

                                        -- The admin now edits the real source-of-truth fields
                                        -- directly, so the server's live in-memory
                                        -- quizProgress/iqTimers (the actual authority while a
                                        -- player is connected) must be updated to match --
                                        -- otherwise a reconnecting player's next
                                        -- quizAdvanced/iqStartCountdown would still be checked
                                        -- against the stale pre-edit value. This replaces the old
                                        -- reconcileIqTimerAfterEdit/reconcileQuizProgressAfterEdit
                                        -- inference-from-screen-shape dance entirely.
                                        newQuizProgress =
                                            Dict.insert editUuid edited.quizProgress model.quizProgress

                                        newIqTimers =
                                            case edited.iqTimer |> Maybe.andThen (Decode.decodeValue decodeIqTimerStateFull >> Result.toMaybe) of
                                                Just iqState ->
                                                    Dict.insert editUuid iqState model.iqTimers

                                                Nothing ->
                                                    Dict.remove editUuid model.iqTimers
                                    in
                                    ( { model
                                        | registry = newRegistry
                                        , quizProgress = newQuizProgress
                                        , iqTimers = newIqTimers
                                        , pendingStateEdits = Set.remove editUuid model.pendingStateEdits
                                        , distClients = clearedDist
                                      }
                                    , Cmd.batch
                                        [ writeRegistry newRegistry
                                        , sendToClient { clientId = clientId, payload = distStateEditSaveAckEnvelope }
                                        ]
                                    )

                                Err _ ->
                                    ( { model | distClients = clearedDist }
                                    , sendToClient { clientId = clientId, payload = rejectEnvelope "invalid json" }
                                    )

                        _ ->
                            ( model, closeClient { clientId = clientId, reason = "unauthorized" } )

                Ok ClientDistList ->
                    ( { model | distClients = Dict.insert clientId AwaitingListAuth model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok (ClientDistReplaceComplete { newUuid, oldUuid, filename, quizQuestions, winText, iqOfferDisabled }) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == newUuid then
                                let
                                    oldEntry =
                                        model.registry
                                            |> List.filter (\e -> e.uuid == oldUuid)
                                            |> List.head

                                    newEntry =
                                        { uuid = newUuid
                                        , filename = filename
                                        , platform = info.platform
                                        , pendingStateEdit = True

                                        -- Unlike every field below, winText, quizQuestions, and
                                        -- iqOfferDisabled are resent fresh on every replace deploy
                                        -- (see scripts/deploy-replacement.js) rather than inherited
                                        -- from oldEntry -- a replacement build's songs/config may have
                                        -- changed, and reusing the old uuid's answers/reward text
                                        -- would silently mismatch the new build. See #77.
                                        , winText = winText
                                        , quizQuestions = Just quizQuestions
                                        , iqOfferDisabled = iqOfferDisabled

                                        -- Carry the IQ snapshot to the new uuid too.
                                        -- (model.iqTimers itself stays keyed by oldUuid until a restart
                                        -- rehydrates it under newUuid from this registry row -- a pre-existing
                                        -- gap in replacement handling, not something this change introduces.)
                                        , iqTimer = oldEntry |> Maybe.andThen .iqTimer

                                        -- Carry quiz progress forward too -- a build replacement
                                        -- shouldn't reset a returning player's earned progress.
                                        , quizProgress = oldEntry |> Maybe.map .quizProgress |> Maybe.withDefault 0

                                        -- Carry the session deadline forward too, for the same
                                        -- reason: a build replacement shouldn't grant (or cost)
                                        -- extra time on the 7-day clock.
                                        , timerEndsAt = oldEntry |> Maybe.andThen .timerEndsAt

                                        -- The one-time-ever skip-offer-granted fact is the real
                                        -- player's permanent state, not per-build authoring -- carry
                                        -- it forward like iqTimer/quizProgress/timerEndsAt above, not
                                        -- reset it like winText/quizQuestions/iqOfferDisabled above.
                                        , iqOfferUsed = oldEntry |> Maybe.map .iqOfferUsed |> Maybe.withDefault False
                                        }

                                    newRegistry =
                                        List.filter (\e -> e.uuid /= oldUuid && e.filename /= filename) model.registry
                                            ++ [ newEntry ]

                                    closeOldPlayerCmd =
                                        case Dict.get oldUuid model.connectedPlayers of
                                            Just playerClientId ->
                                                closeClient { clientId = playerClientId, reason = "build replaced" }

                                            Nothing ->
                                                Cmd.none
                                in
                                -- newUuid starts locked (pendingStateEdit = True): the admin must
                                -- resolve it via distStateEdit/distStateEditSave before players can
                                -- connect or download. Note: if that save is ever invalid JSON, this
                                -- uuid is stuck the same way the pre-existing edit-state quirk gets
                                -- stuck (see tests/edit-state.test.js) -- except every replacement now
                                -- requires a save to unlock, not just an optional admin edit.
                                ( { model
                                    | distClients = Dict.remove clientId model.distClients
                                    , connectedPlayers = Dict.remove oldUuid model.connectedPlayers
                                    , registry = newRegistry
                                    , pendingStateEdits = Set.insert newUuid model.pendingStateEdits
                                  }
                                , Cmd.batch
                                    [ closeOldPlayerCmd
                                    , writeRegistry newRegistry
                                    , sendToClient { clientId = clientId, payload = distReplaceCompleteAckEnvelope }
                                    ]
                                )

                            else
                                ( model, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

                Ok (ClientDistUndeploy uuid) ->
                    -- Gate behind admin auth; the removal runs in AuthCompleted
                    -- (performUndeploy) only after a level-2 challenge succeeds.
                    ( { model | distClients = Dict.insert clientId (AwaitingUndeployAuth uuid) model.distClients }
                    , requestAuth { clientId = clientId, level = 2 }
                    )

                Ok ClientIqStartCountdown ->
                    -- "Player pressed Begin." The count is the server's own, never
                    -- the client's -- see startCountdown. Only honored when there's
                    -- no live entry yet, or the existing one is idle (IqIdleNotStarted
                    -- or IqIdleCaught, post-catch waiting to restart) -- the honest
                    -- client's Begin button only renders on IQTestScreen in those
                    -- states, so a countdown already ticking/dinging in any other
                    -- phase is a stale/crafted request: ignore it rather than
                    -- silently restarting the test. Also blocked while an outstanding
                    -- skip-offer grant sits unconsumed for this uuid (see
                    -- Model.iqOfferGrants) -- both idle phases are exactly what a fail/
                    -- catch leaves behind once granted, so without this guard a stray
                    -- iqStartCountdown could hijack the offer screen into a real countdown
                    -- out from under it. ClientIqOfferDeclined releases the grant so a
                    -- genuine "declined, pressed Begin again" flow isn't stuck forever.
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            if Dict.member uuid model.iqOfferGrants then
                                ( model, Cmd.none )

                            else
                                case Dict.get uuid model.iqTimers of
                                    Nothing ->
                                        startCountdown uuid model

                                    Just state ->
                                        if state.phase == IqIdleNotStarted || state.phase == IqIdleCaught then
                                            startCountdown uuid model

                                        else
                                            ( model, Cmd.none )

                Ok ClientIqReadyForDing ->
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            case Dict.get uuid model.iqTimers of
                                Just state ->
                                    case state.phase of
                                        IqAwaitingReady ->
                                            -- First ding after the countdown: nothing to
                                            -- advance yet, just arm the first ding.
                                            scheduleNextDing uuid state model

                                        IqDingShown ->
                                            -- The outstanding ding was resolved; advance.
                                            case advanceOnClear state of
                                                Completed ->
                                                    let
                                                        ( withTimer, persistCmd ) =
                                                            clearIqTimer uuid model
                                                    in
                                                    ( withTimer
                                                    , Cmd.batch [ persistCmd, sendToPlayer uuid model iqTestCompleteEnvelope ]
                                                    )

                                                Advanced adv ->
                                                    let
                                                        ( m, dingCmd ) =
                                                            scheduleNextDing uuid adv.state model
                                                    in
                                                    ( m
                                                    , if adv.startLoud then
                                                        Cmd.batch [ sendToPlayer uuid model iqStartLoudEnvelope, dingCmd ]

                                                      else
                                                        dingCmd
                                                    )

                                        _ ->
                                            -- Stale/duplicate request in another phase: ignore.
                                            ( model, Cmd.none )

                                Nothing ->
                                    ( model, Cmd.none )

                Ok ClientIqCaught ->
                    -- Honor a catch only when a fake ding is actually outstanding.
                    -- The server doubles its own count and goes idle; the client is
                    -- meanwhile playing the cutscene and will send iqStartCountdown
                    -- (which resets the run) when the player presses Begin again --
                    -- unless the catch also grants the skip offer (see decideIqOffer
                    -- below), in which case iqStartCountdown is blocked until the
                    -- offer is resolved (see the guard above).
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            case Dict.get uuid model.iqTimers of
                                Just state ->
                                    if state.phase == IqDingShown && state.lastDing == TrapFake then
                                        let
                                            doubled =
                                                applyCatch state

                                            caught =
                                                { doubled | phase = IqIdleCaught }

                                            offerEntry =
                                                model.registry |> List.filter (\e -> e.uuid == uuid) |> List.head

                                            decision =
                                                decideIqOffer
                                                    { dingCountAtFail = state.dingCount
                                                    , totalDingsAtFail = caught.totalDings
                                                    , offerDisabled = offerEntry |> Maybe.map .iqOfferDisabled |> Maybe.withDefault False
                                                    , offerUsed = offerEntry |> Maybe.map .iqOfferUsed |> Maybe.withDefault False
                                                    }

                                            registryWithTimer =
                                                persistIqTimerInRegistry uuid (Just caught) model.registry

                                            finalRegistry =
                                                if decision.granted then
                                                    updateEntryIqOfferUsed uuid registryWithTimer

                                                else
                                                    registryWithTimer

                                            finalModel =
                                                { model
                                                    | iqTimers = Dict.insert uuid caught model.iqTimers
                                                    , registry = finalRegistry
                                                    , iqOfferGrants =
                                                        if decision.granted then
                                                            Dict.insert uuid state.questionIdx model.iqOfferGrants

                                                        else
                                                            model.iqOfferGrants
                                                }
                                        in
                                        ( finalModel
                                        , Cmd.batch
                                            [ writeRegistry finalRegistry
                                            , sendToClient { clientId = clientId, payload = iqOfferDecisionEnvelope decision }
                                            ]
                                        )

                                    else
                                        ( model, Cmd.none )

                                Nothing ->
                                    ( model, Cmd.none )

                Ok ClientIqResume ->
                    -- The client just restored a saved IQ screen (countdown/active)
                    -- after reconnecting. Re-arm whatever was paused for it -- a
                    -- no-op if there's nothing to resume (e.g. either idle phase, or
                    -- no entry).
                    case findUuidByClient clientId model.connectedPlayers of
                        Just uuid ->
                            resumeIqTimer uuid model

                        Nothing ->
                            ( model, Cmd.none )

                Ok ClientIqFailed ->
                    -- "A qualifying fail just happened" (DingWindowExpired timeout, or a
                    -- SpaceBarPressed miss -- see Game.IQTest.decideSpaceBar's
                    -- SpaceBarFailed case). Only a live, non-idle phase is a plausible
                    -- fail -- IqCounting/IqIdleNotStarted/IqIdleCaught can't have produced
                    -- one client-side, so a report from one of those is stale/crafted and
                    -- ignored. This is the first place a "fail" transition is defined
                    -- server-side at all: it moves the entry to IqIdleNotStarted (the
                    -- honest client's next screen is always IQTestScreen/the offer screen,
                    -- never a live phase, after this).
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            case Dict.get uuid model.iqTimers of
                                Just state ->
                                    if List.member state.phase [ IqAwaitingReady, IqDingScheduled, IqDingShown ] then
                                        let
                                            idled =
                                                { state | phase = IqIdleNotStarted }

                                            offerEntry =
                                                model.registry |> List.filter (\e -> e.uuid == uuid) |> List.head

                                            decision =
                                                decideIqOffer
                                                    { dingCountAtFail = state.dingCount
                                                    , totalDingsAtFail = state.totalDings
                                                    , offerDisabled = offerEntry |> Maybe.map .iqOfferDisabled |> Maybe.withDefault False
                                                    , offerUsed = offerEntry |> Maybe.map .iqOfferUsed |> Maybe.withDefault False
                                                    }

                                            registryWithTimer =
                                                persistIqTimerInRegistry uuid (Just idled) model.registry

                                            finalRegistry =
                                                if decision.granted then
                                                    updateEntryIqOfferUsed uuid registryWithTimer

                                                else
                                                    registryWithTimer

                                            finalModel =
                                                { model
                                                    | iqTimers = Dict.insert uuid idled model.iqTimers
                                                    , registry = finalRegistry
                                                    , iqOfferGrants =
                                                        if decision.granted then
                                                            Dict.insert uuid state.questionIdx model.iqOfferGrants

                                                        else
                                                            model.iqOfferGrants
                                                }
                                        in
                                        ( finalModel
                                        , Cmd.batch
                                            [ writeRegistry finalRegistry
                                            , sendToClient { clientId = clientId, payload = iqOfferDecisionEnvelope decision }
                                            ]
                                        )

                                    else
                                        ( model, Cmd.none )

                                Nothing ->
                                    ( model, Cmd.none )

                Ok ClientIqOfferDeclined ->
                    -- Releases an outstanding grant (see decideIqOffer/Model.iqOfferGrants)
                    -- so the ClientIqStartCountdown guard above no longer blocks the next
                    -- genuine "player pressed Begin". A decline with no outstanding grant
                    -- (stale/crafted/already-consumed) is a harmless no-op.
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            ( { model | iqOfferGrants = Dict.remove uuid model.iqOfferGrants }, Cmd.none )

                Ok (ClientQuizSongEnded idx) ->
                    -- "The song/video for question idx just finished playing." Accepted
                    -- only if idx is exactly the player's current expected question --
                    -- a stale/out-of-order report is silently ignored, same as a
                    -- mismatched ClientQuizAdvanced/ClientQuizAnswerSubmitted idx.
                    -- Recorded in memory only (see Model.quizSongEnded); required by
                    -- ClientQuizAnswerSubmitted below before it accepts an answer.
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            if quizBlockedByLiveIqTimer uuid model then
                                ( model, Cmd.none )

                            else
                                let
                                    current =
                                        Dict.get uuid model.quizProgress |> Maybe.withDefault 0
                                in
                                if idx == current then
                                    ( { model | quizSongEnded = Dict.insert uuid idx model.quizSongEnded }
                                    , sendToClient { clientId = clientId, payload = quizSongEndedAckEnvelope idx }
                                    )

                                else
                                    ( model, Cmd.none )

                Ok (ClientQuizAdvanced idx) ->
                    -- "The player just passed question idx" -- accepted only if it's
                    -- exactly the next one expected (see acceptQuizAdvance), so a
                    -- crafted client can't skip straight to a win. Only when the
                    -- server's own tally reaches totalQuestions does it grant winText.
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            let
                                -- A server-granted, not-yet-consumed skip offer for this
                                -- exact question (see decideIqOffer/Model.iqOfferGrants) is
                                -- the one thing allowed to bypass a live IQ timer -- accepting
                                -- the offer *is* the honest client's replacement for actually
                                -- passing the test. Deliberately scoped to an exact idx match,
                                -- not a blanket "any idle phase unblocks" relaxation, so the
                                -- #73/#75 cheat vector quizBlockedByLiveIqTimer exists to close
                                -- stays closed for every other case.
                                offerAccept =
                                    Dict.get uuid model.iqOfferGrants == Just idx
                            in
                            if quizBlockedByLiveIqTimer uuid model && not offerAccept then
                                ( model, Cmd.none )

                            else
                                let
                                    -- Fold the iqTimer-clear into the same in-memory Model/registry
                                    -- state the quizProgress bump below is computed from, and issue
                                    -- exactly ONE writeRegistry for the whole handler -- calling
                                    -- clearIqTimer here directly would fire its own writeRegistry
                                    -- with a stale (pre-bump) quizProgress snapshot, and batching
                                    -- that alongside a second writeRegistry below hits the same
                                    -- Cmd.batch port-ordering hazard already worked around for
                                    -- ClientIqFailed/ClientIqCaught (registry writes within one
                                    -- Cmd.batch aren't guaranteed to land in array order).
                                    baseModel =
                                        if offerAccept then
                                            { model
                                                | iqTimers = Dict.remove uuid model.iqTimers
                                                , iqOfferGrants = Dict.remove uuid model.iqOfferGrants
                                                , registry = persistIqTimerInRegistry uuid Nothing model.registry
                                            }

                                        else
                                            model

                                    current =
                                        Dict.get uuid baseModel.quizProgress |> Maybe.withDefault 0

                                    total =
                                        List.length (questionsForUuid uuid baseModel.registry)
                                in
                                case acceptQuizAdvance { current = current, idx = idx } of
                                    Nothing ->
                                        ( baseModel
                                        , if offerAccept then
                                            writeRegistry baseModel.registry

                                          else
                                            Cmd.none
                                        )

                                    Just next ->
                                        let
                                            newRegistry =
                                                persistQuizScreenInRegistry uuid { next = next, total = total } baseModel.registry

                                            newModel =
                                                { baseModel
                                                    | quizProgress = Dict.insert uuid next baseModel.quizProgress
                                                    , registry = newRegistry
                                                }

                                            winCmd =
                                                if quizJustCompleted { next = next, total = total } then
                                                    newRegistry
                                                        |> List.filter (\e -> e.uuid == uuid)
                                                        |> List.head
                                                        |> Maybe.map (\e -> sendToClient { clientId = clientId, payload = winTextEnvelope e.winText })
                                                        |> Maybe.withDefault Cmd.none

                                                else
                                                    Cmd.none
                                        in
                                        ( newModel, Cmd.batch [ writeRegistry newRegistry, winCmd ] )

                Ok (ClientQuizAnswerSubmitted { idx, answer }) ->
                    -- The server, not the client, holds the answers (see
                    -- questionsForUuid) and decides correctness via decideAnswer --
                    -- mirroring Game.Quiz's old client-side check, just moved here
                    -- (see #54/#32). idx must still be exactly the player's next
                    -- expected question (same acceptQuizAdvance gate as
                    -- ClientQuizAdvanced above), so a correct answer for a later idx
                    -- can't be used to skip ahead. It must also have a matching
                    -- ClientQuizSongEnded confirmation on file for the same idx --
                    -- otherwise a crafted client could submit before any song ever
                    -- played (see Model.quizSongEnded).
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            if quizBlockedByLiveIqTimer uuid model || Dict.get uuid model.quizSongEnded /= Just idx then
                                ( model, Cmd.none )

                            else
                                let
                                    current =
                                        Dict.get uuid model.quizProgress |> Maybe.withDefault 0

                                    questions =
                                        questionsForUuid uuid model.registry

                                    total =
                                        List.length questions
                                in
                                case acceptQuizAdvance { current = current, idx = idx } of
                                    Nothing ->
                                        ( model, Cmd.none )

                                    Just next ->
                                        case decideAnswer questions idx answer of
                                            NoQuestion ->
                                                ( model, Cmd.none )

                                            IncorrectAnswer ->
                                                let
                                                    revealAnswer =
                                                        getQuestion questions idx
                                                            |> Maybe.andThen (.answers >> List.head)
                                                            |> Maybe.map capitalize
                                                            |> Maybe.withDefault "Unknown"

                                                    -- Populate the IQ-test gate right now, at the
                                                    -- moment the wrong answer is scored -- not lazily
                                                    -- once the client presses Begin. This is the one
                                                    -- genuinely new piece of information the server
                                                    -- needs now that there's no persisted screen to
                                                    -- fall back on: without it, `iqTimer = Nothing`
                                                    -- couldn't tell "never gated" apart from "just
                                                    -- failed idx, about to retry" (see ClientStateRequest's
                                                    -- derivation). It also closes a pre-existing gap:
                                                    -- quizBlockedByLiveIqTimer already guards entry into
                                                    -- this whole handler, so model.iqTimers is
                                                    -- guaranteed Nothing here -- a crafted client could
                                                    -- otherwise skip the penalty forever by never
                                                    -- sending iqStartCountdown.
                                                    freshIqTimer =
                                                        { epoch = 0
                                                        , phase = IqIdleNotStarted
                                                        , questionIdx = idx
                                                        , countdownRemaining = 0
                                                        , dingCount = 0
                                                        , totalDings = IQTest.iqQuestionCount
                                                        , fakeFlashPoint = 0
                                                        , fakeFlashUsed = False
                                                        , in50PercentPhase = False
                                                        , lastDing = RealDing
                                                        , dingDelay = Nothing
                                                        }

                                                    ( withTimer, persistCmd ) =
                                                        setIqTimer uuid freshIqTimer model
                                                in
                                                ( withTimer
                                                , Cmd.batch
                                                    [ persistCmd
                                                    , sendToClient
                                                        { clientId = clientId
                                                        , payload = quizAnswerResultEnvelope { idx = idx, correct = False, revealAnswer = revealAnswer }
                                                        }
                                                    ]
                                                )

                                            _ ->
                                                -- CorrectContinue or CorrectWin: either way the
                                                -- answer for idx was right, so progress advances --
                                                -- exactly the ClientQuizAdvanced branch above, plus
                                                -- the result reply.
                                                let
                                                    newRegistry =
                                                        persistQuizScreenInRegistry uuid { next = next, total = total } model.registry

                                                    newModel =
                                                        { model
                                                            | quizProgress = Dict.insert uuid next model.quizProgress
                                                            , registry = newRegistry
                                                        }

                                                    resultCmd =
                                                        sendToClient
                                                            { clientId = clientId
                                                            , payload = quizAnswerResultEnvelope { idx = idx, correct = True, revealAnswer = "" }
                                                            }

                                                    winCmd =
                                                        if quizJustCompleted { next = next, total = total } then
                                                            newRegistry
                                                                |> List.filter (\e -> e.uuid == uuid)
                                                                |> List.head
                                                                |> Maybe.map (\e -> sendToClient { clientId = clientId, payload = winTextEnvelope e.winText })
                                                                |> Maybe.withDefault Cmd.none

                                                        else
                                                            Cmd.none
                                                in
                                                ( newModel, Cmd.batch [ writeRegistry newRegistry, resultCmd, winCmd ] )

                _ ->
                    ( model, Cmd.none )

        AuthCompleted { clientId, success, level } ->
            let
                isAdmin =
                    success && level >= 2

                failAuth m =
                    ( { m | distClients = Dict.remove clientId m.distClients }
                    , closeClient { clientId = clientId, reason = "Auth failed" }
                    )
            in
            case Dict.get clientId model.distClients of
                Just (AwaitingAuth info) ->
                    if isAdmin then
                        ( { model | distClients = Dict.insert clientId (AwaitingUpload info) model.distClients }
                        , sendToClient { clientId = clientId, payload = distRegisterAckEnvelope }
                        )

                    else
                        failAuth model

                Just (AwaitingUndeployAuth uuid) ->
                    if isAdmin then
                        performUndeploy uuid clientId model

                    else
                        failAuth model

                Just AwaitingListAuth ->
                    if isAdmin then
                        ( { model | distClients = Dict.remove clientId model.distClients }
                        , -- send-then-close in one JS tick; Cmd.batch would not guarantee ordering.
                          rejectAndClose
                            { clientId = clientId
                            , reason = "list complete"
                            , payload = distListResultEnvelope model.registry
                            }
                        )

                    else
                        failAuth model

                Just (AwaitingStateEditAuth uuid) ->
                    if isAdmin then
                        performStateEdit uuid clientId model

                    else
                        failAuth model

                _ ->
                    ( model, Cmd.none )

        FileRead path result ->
            if path == registryFilePath then
                case result of
                    Ok contents ->
                        let
                            parsedRegistry =
                                decodeRegistry contents

                            -- Rehydrate in-memory WS-connect gating from the persisted
                            -- flag so it agrees with on-disk download gating after a
                            -- restart mid-edit (otherwise connects would reopen while
                            -- downloads stayed locked until the next save).
                            rehydratedPendingStateEdits =
                                parsedRegistry
                                    |> List.filter .pendingStateEdit
                                    |> List.map .uuid
                                    |> Set.fromList

                            -- Rehydrate the server-authoritative IQ state too (IQ-only
                            -- stepping stone -- see RegistryEntry.iqTimer / IqTimerState's
                            -- doc comment). With this, a full process restart looks, to the
                            -- existing pause/resume-on-reconnect machinery
                            -- (ClientDisconnected's epoch bump + ClientIqResume ->
                            -- resumeIqTimer), just like every connected player having
                            -- simultaneously disconnected -- no new resume logic needed.
                            -- No epoch bump: nothing was scheduled against any epoch yet in
                            -- this fresh process, so whatever epoch was persisted is still valid.
                            rehydratedIqTimers =
                                parsedRegistry
                                    |> List.filterMap
                                        (\e ->
                                            e.iqTimer
                                                |> Maybe.andThen (Decode.decodeValue decodeIqTimerStateFull >> Result.toMaybe)
                                                |> Maybe.map (\s -> ( e.uuid, s ))
                                        )
                                    |> Dict.fromList

                            -- Rehydrate server-tracked quiz progress the same way, so a
                            -- restart doesn't require re-earning already-confirmed questions.
                            rehydratedQuizProgress =
                                parsedRegistry
                                    |> List.map (\e -> ( e.uuid, e.quizProgress ))
                                    |> Dict.fromList
                        in
                        ( { model
                            | registry = parsedRegistry
                            , pendingStateEdits = rehydratedPendingStateEdits
                            , iqTimers = rehydratedIqTimers
                            , quizProgress = rehydratedQuizProgress
                          }
                        , Cmd.none
                        )

                    Err _ ->
                        ( model, Cmd.none )

            else
                ( model, Cmd.none )

        WriteFileCompleted _ ->
            ( model, Cmd.none )

        GotTime posix ->
            -- Seed the RNG from wall-clock time so ding delays / trap points vary
            -- across server runs. Arrives once at startup, before any WS message.
            ( { model | seed = Random.initialSeed (Time.posixToMillis posix) }, Cmd.none )

        CountdownStep { uuid, epoch } ->
            case Dict.get uuid model.iqTimers of
                Just state ->
                    if state.epoch == epoch && state.phase == IqCounting then
                        let
                            newRemaining =
                                state.countdownRemaining - 1
                        in
                        if newRemaining > 0 then
                            let
                                ( withTimer, persistCmd ) =
                                    setIqTimer uuid { state | countdownRemaining = newRemaining } model
                            in
                            ( withTimer
                            , Cmd.batch
                                [ persistCmd
                                , sendToPlayer uuid model (iqCountdownTickEnvelope newRemaining)
                                , scheduleCountdownStep uuid epoch
                                ]
                            )

                        else
                            let
                                ( withTimer, persistCmd ) =
                                    setIqTimer uuid { state | countdownRemaining = 0, phase = IqAwaitingReady } model
                            in
                            ( withTimer
                            , Cmd.batch [ persistCmd, sendToPlayer uuid model (iqCountdownCompleteEnvelope state.dingCount) ]
                            )

                    else
                        -- Stale fire (paused by a disconnect, or a newer countdown started).
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        DingReady { uuid, epoch } ->
            case Dict.get uuid model.iqTimers of
                Just state ->
                    if state.epoch == epoch && state.phase == IqDingScheduled then
                        let
                            ( coin, newSeed ) =
                                Random.step IQTest.coinFlipGen model.seed

                            kind =
                                classifyDing coin state

                            ( withTimer, persistCmd ) =
                                setIqTimer uuid { state | phase = IqDingShown, lastDing = kind } { model | seed = newSeed }
                        in
                        ( withTimer
                        , Cmd.batch
                            [ persistCmd
                            , sendToPlayer uuid
                                model
                                (iqDingEnvelope
                                    { fake = dingIsFake kind
                                    , trap = kind == TrapFake
                                    , dingCount = state.dingCount
                                    , totalDings = state.totalDings
                                    }
                                )
                            ]
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )


-- Decides the FileRead Msg a readFile port response becomes: a decent error
-- message even in the (shouldn't-happen) case where the JS host reports
-- neither contents nor an error.
classifyFileRead : { path : String, contents : Maybe String, error : Maybe String } -> Msg
classifyFileRead { path, contents, error } =
    case ( contents, error ) of
        ( Just c, _ ) ->
            FileRead path (Ok c)

        ( _, Just e ) ->
            FileRead path (Err e)

        _ ->
            FileRead path (Err "unknown error")


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ onConnection ClientConnected
        , onDisconnection ClientDisconnected
        , onMessage MessageReceived
        , authResult AuthCompleted
        , writeFileResult WriteFileCompleted
        , readFileResult classifyFileRead
        ]


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }


port onConnection : (String -> msg) -> Sub msg

port onDisconnection : (String -> msg) -> Sub msg

port onMessage : ({ clientId : String, payload : Encode.Value, now : Float } -> msg) -> Sub msg

port sendToClient : { clientId : String, payload : Encode.Value } -> Cmd msg

port closeClient : { clientId : String, reason : String } -> Cmd msg

port rejectAndClose : { clientId : String, reason : String, payload : Encode.Value } -> Cmd msg

port readFile : String -> Cmd msg

port readFileResult : ({ path : String, contents : Maybe String, error : Maybe String } -> msg) -> Sub msg

port requestAuth : { clientId : String, level : Int } -> Cmd msg

port authResult : ({ clientId : String, success : Bool, level : Int, uuid : String } -> msg) -> Sub msg

port writeFile : { path : String, contents : String, encoding : String, append : Bool } -> Cmd msg

port writeFileResult : ({ path : String, ok : Bool, error : Maybe String } -> msg) -> Sub msg

port stateEditReady : { adminClientId : String, uuid : String, json : String } -> Cmd msg

port deleteBuildFile : String -> Cmd msg
