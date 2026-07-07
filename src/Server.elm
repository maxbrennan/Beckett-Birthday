port module Server exposing (..)

import Dict exposing (Dict)
import Game.IQTest as IQTest
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
    }


{-| Where a player is in the server-driven IQ test. The server owns all timing
and the whole ding/question count; the client only renders and reports raw input.
-}
type IqPhase
    = IqCounting -- pre-test countdown ticking down
    | IqAwaitingReady -- countdown done or a ding resolved; waiting for the client's iqReadyForDing
    | IqDingScheduled -- a random inter-ding delay is sleeping; ding not yet shown
    | IqDingShown -- a ding was emitted; waiting for the client to resolve it
    | IqIdle -- post-catch: waiting for the client to press Begin (iqStartCountdown) again


{-| Per-player IQ-test state, keyed by **uuid** (the durable player identity, not
the ephemeral `clientId` a WebSocket connection gets) so it survives a
disconnect/reconnect. Persists across fail-restart, catch-restart, and a
disconnect within a session -- only test completion removes it. The client
never supplies the count -- the server initializes it to `iqQuestionCount` and
doubles it on a catch.

On disconnect the entry is *paused*, not dropped: `ClientDisconnected` bumps
`epoch` (invalidating any in-flight `Process.sleep`) but keeps every field, and
`ClientIqResume` re-arms the appropriate schedule once the player is back and
has actually rendered the IQ screen again -- see `resumeIqTimer`.

**Persistence (IQ-only stepping stone):** every live change to this state is
also mirrored into the player's `RegistryEntry.iqTimer` field in
`builds.jsonl` (see `persistIqTimerInRegistry`/`setIqTimer`/`clearIqTimer`),
and wherever it's derivable, the persisted `state.screen` is overwritten to
match rather than left as whatever the client last self-reported (see
`deriveIqScreen`, and the override in the `ClientStateUpdate` handler). This
is what makes the client's IQ screen 100% derivable from the server's own
state instead of a second, independently-drifting copy, and it's also what
lets `init`/`FileRead` rehydrate `iqTimers` after a full process restart
(otherwise a restart would silently reset a mid-punishment-phase player back
to the baseline count). The IQ test is the *first* game phase moved to this
pattern -- every other screen still round-trips through the client's raw
`stateUpdate` verbatim (`updateEntryState`). Generalizing this beyond the IQ
test would mean extending `deriveIqScreen`/`persistIqTimerInRegistry` (or an
analogous per-phase deriver) beyond these IQ-specific types.
-}
type alias IqTimerState =
    { epoch : Int -- bumped on every start; stale Process.sleep fires are ignored
    , phase : IqPhase
    , questionIdx : Int -- which overall trivia slide this IQ test belongs to; not a cheat vector (see extractQuestionIdx), purely for display continuity
    , countdownRemaining : Int
    , dingCount : Int -- real dings cleared so far
    , totalDings : Int -- target count; the punishment phase decrements this toward iqQuestionCount
    , fakeFlashPoint : Int -- server-chosen trap position
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    , lastDing : DingKind -- kind of the ding most recently emitted
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
    | MessageReceived { clientId : String, payload : Encode.Value }
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
                { startLoud = newDingCount == 4
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


{-| The client's overall trivia slide index, read off whatever's already
persisted for this player. Not a cheat vector (unlike dingCount/totalDings) --
it only needs to be *some* reasonable value for display continuity, so it's
safe to source from the client/registry rather than tracking it as a real
anti-cheat field. Tries both shapes the registry can hold it in: the
IQTestScreen family nests it under `screen.state.questionIdx`, while
`WrongAnswerScreen`/`BlankScreen`/`QuestionScreen`/`VideoScreen` (see
`Sync.elm`'s `encodeScreen`) carry it as a top-level `screen.idx`.
-}
extractQuestionIdx : Encode.Value -> Int
extractQuestionIdx stateValue =
    Decode.decodeValue
        (Decode.oneOf
            [ Decode.at [ "screen", "state", "questionIdx" ] Decode.int
            , Decode.at [ "screen", "idx" ] Decode.int
            ]
        )
        stateValue
        |> Result.withDefault 0


{-| Project an IqTimerState onto the exact JSON shape `Sync.elm`'s `encodeScreen`
produces for `IQTestCountdownScreen`/`IQTestActiveScreen`, so the persisted
registry row can be derived from server state instead of the client's own
report. `IqIdle` covers both "mid fake-flash-caught cutscene" and "not yet
started" -- in both cases the correct persisted screen tag
(`FakeFlashCaughtScreen`/`IQTestScreen`) is one this function has no business
producing, so `Nothing` leaves the client's own report authoritative there,
exactly as before this change.

Known, deliberate imprecision: `isFlashing`/`loudPlaying` don't track the
client's local 250ms flash animation or the 3s `StartLoudMusic` delay -- they
only matter for the brief window before `resumeIqTimer` re-syncs a
reconnecting client, which was already imprecise before this change.
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

        IqIdle ->
            Nothing


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
                , ( "loudPlaying", Encode.bool (state.dingCount >= 4) )
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

            IqIdle ->
                "IqIdle"


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

                    "IqIdle" ->
                        Decode.succeed IqIdle

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
        ]


decodeIqTimerStateFull : Decode.Decoder IqTimerState
decodeIqTimerStateFull =
    Decode.map8
        (\epoch phase questionIdx countdownRemaining dingCount totalDings fakeFlashPoint fakeFlashUsed ->
            \in50PercentPhase lastDing ->
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
                Decode.map2 partial
                    (Decode.field "in50PercentPhase" Decode.bool)
                    (Decode.field "lastDing" decodeDingKind)
            )


{-| Projects one player's authoritative IqTimerState onto their registry row:
stores the full state (so `init`/`FileRead` can rehydrate `iqTimers` after a
restart) and, where derivable, overwrites just the `screen` key -- `pending`/
`now`/etc. stay exactly as the client last reported them. `Nothing` clears
`iqTimer` and leaves `.state` untouched entirely -- the client's own report
becomes authoritative again from that point on (e.g. once the test completes).
IQ-only for now; every other screen/player passes through unaffected.
-}
persistIqTimerInRegistry : String -> Maybe IqTimerState -> List RegistryEntry -> List RegistryEntry
persistIqTimerInRegistry uuid maybeState registry =
    let
        withIqTimer =
            updateEntryIqTimer uuid (Maybe.map encodeIqTimerStateFull maybeState) registry
    in
    case maybeState |> Maybe.andThen deriveIqScreen of
        Nothing ->
            withIqTimer

        Just screen ->
            List.map
                (\e ->
                    if e.uuid == uuid then
                        { e | state = Just (overwriteField "screen" screen (Maybe.withDefault (Encode.object []) e.state)) }

                    else
                        e
                )
                withIqTimer


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


{-| The IQ-relevant fields of whatever screen an admin state edit just saved.
`EditedIqOther` covers both "not an IQ screen" and "decode failed" -- either
way there's nothing to reconcile.
-}
type EditedIqScreen
    = EditedIqBegin { totalDings : Int }
    | EditedIqCountdown { countdown : Int, totalDings : Int }
    | EditedIqActive { dingCount : Int, totalDings : Int }
    | EditedIqOther


decodeEditedIqScreen : Decode.Decoder EditedIqScreen
decodeEditedIqScreen =
    Decode.oneOf
        [ Decode.at [ "screen", "tag" ] Decode.string
            |> Decode.andThen
                (\tag ->
                    case tag of
                        "IQTestScreen" ->
                            Decode.map (\td -> EditedIqBegin { totalDings = td })
                                (Decode.at [ "screen", "state", "totalDings" ] Decode.int)

                        "IQTestCountdownScreen" ->
                            Decode.map2 (\cd td -> EditedIqCountdown { countdown = cd, totalDings = td })
                                (Decode.at [ "screen", "state", "countdown" ] Decode.int)
                                (Decode.at [ "screen", "state", "totalDings" ] Decode.int)

                        "IQTestActiveScreen" ->
                            Decode.map2 (\dc td -> EditedIqActive { dingCount = dc, totalDings = td })
                                (Decode.at [ "screen", "state", "dingCount" ] Decode.int)
                                (Decode.at [ "screen", "state", "totalDings" ] Decode.int)

                        _ ->
                            Decode.succeed EditedIqOther
                )
        , Decode.succeed EditedIqOther
        ]


{-| The server's in-memory `iqTimers` is now the sole authority on the IQ
countdown/count, entirely separate from the persisted registry JSON an admin
edits with `edit:state`. Without this, an edited countdown/count is silently
clobbered the moment the server resends its own (unrelated) authoritative
value -- see the `iqResume`-driven resends in `resumeIqTimer`. So: whenever an
edit is saved, treat its IQ-relevant fields as the new authoritative state and
overwrite (or create) the player's `iqTimers` entry to match, keeping it
paused (no live schedule armed) exactly like a normal disconnect, so the next
`iqResume` (once the player reconnects and presses Begin again) arms it.
`fakeFlashUsed`/`in50PercentPhase` carry over from any existing entry (an edit
doesn't expose them); `fakeFlashPoint` is freshly drawn since the client no
longer has one to round-trip.
-}
reconcileIqTimerAfterEdit : String -> Encode.Value -> Model -> Model
reconcileIqTimerAfterEdit uuid parsedState model =
    let
        prev =
            Dict.get uuid model.iqTimers

        nextEpoch =
            (prev |> Maybe.map .epoch |> Maybe.withDefault 0) + 1

        carriedFakeFlashUsed =
            prev |> Maybe.map .fakeFlashUsed |> Maybe.withDefault False

        carriedIn50Percent =
            prev |> Maybe.map .in50PercentPhase |> Maybe.withDefault False

        questionIdx =
            prev |> Maybe.map .questionIdx |> Maybe.withDefault (extractQuestionIdx parsedState)

        -- Mirror the reconciled iqTimers entry into the registry too (model.registry
        -- here already has the admin's raw edit applied by the caller), so it
        -- survives a restart and so the persisted screen agrees with the
        -- reconciled state rather than the admin's raw JSON (see deriveIqScreen).
        persist state m =
            { m
                | iqTimers = Dict.insert uuid state m.iqTimers
                , registry = persistIqTimerInRegistry uuid (Just state) m.registry
            }
    in
    case Decode.decodeValue decodeEditedIqScreen parsedState of
        Ok (EditedIqBegin { totalDings }) ->
            persist
                { epoch = nextEpoch
                , phase = IqIdle
                , questionIdx = questionIdx
                , countdownRemaining = totalDings
                , dingCount = 0
                , totalDings = totalDings
                , fakeFlashPoint = prev |> Maybe.map .fakeFlashPoint |> Maybe.withDefault 0
                , fakeFlashUsed = carriedFakeFlashUsed
                , in50PercentPhase = carriedIn50Percent
                , lastDing = RealDing
                }
                model

        Ok (EditedIqCountdown { countdown, totalDings }) ->
            let
                ( fakeFlashPoint, newSeed ) =
                    Random.step (IQTest.fakeFlashPointGen totalDings) model.seed
            in
            persist
                { epoch = nextEpoch
                , phase = IqCounting
                , questionIdx = questionIdx
                , countdownRemaining = countdown
                , dingCount = 0
                , totalDings = totalDings
                , fakeFlashPoint = fakeFlashPoint
                , fakeFlashUsed = carriedFakeFlashUsed
                , in50PercentPhase = carriedIn50Percent
                , lastDing = RealDing
                }
                { model | seed = newSeed }

        Ok (EditedIqActive { dingCount, totalDings }) ->
            let
                ( fakeFlashPoint, newSeed ) =
                    Random.step (IQTest.fakeFlashPointGen totalDings) model.seed
            in
            persist
                { epoch = nextEpoch
                , phase = IqAwaitingReady
                , questionIdx = questionIdx
                , countdownRemaining = 0
                , dingCount = dingCount
                , totalDings = totalDings
                , fakeFlashPoint = fakeFlashPoint
                , fakeFlashUsed = carriedFakeFlashUsed
                , in50PercentPhase = carriedIn50Percent
                , lastDing = RealDing
                }
                { model | seed = newSeed }

        Ok EditedIqOther ->
            model

        Err _ ->
            model


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
                    model.registry
                        |> List.filter (\e -> e.uuid == uuid)
                        |> List.head
                        |> Maybe.andThen .state
                        |> Maybe.withDefault (Encode.object [])
                        |> extractQuestionIdx

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
            setIqTimer uuid { state | phase = IqDingScheduled } { model | seed = newSeed }
    in
    ( withTimer
    , scheduleDing uuid state.epoch delay
    )


{-| Re-arm a paused IQ timer once the player has reconnected *and* actually
rendered the corresponding IQ screen again (signalled by the client's
`iqResume`, sent right after `BeginPressed` restores an IQ screen from
`savedState`). Bumping to a fresh epoch here isn't needed -- `ClientDisconnected`
already bumped it, and nothing was scheduled against the new epoch until now.

- `IqCounting`: resend the current tick immediately (so the UI doesn't wait up
  to 1s for the next natural tick) and re-arm the 1s loop.
- `IqDingScheduled` / `IqAwaitingReady`: nothing was shown yet -- just arm the
  next ding (a fresh random delay; the exact remaining wait isn't tracked).
- `IqDingShown`: resend the same ding fresh, so the player gets a full
  250ms/2000ms window rather than whatever's left of the generic client-side
  pending-resume's rebased (and floor-clamped) window.
- `IqIdle`: nothing to resume; the player will press Begin to send a fresh
  `iqStartCountdown`.
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

                IqIdle ->
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
connected player, hand the current state to the admin, and move the admin into
the EditingState stage (which authorizes the following distStateEditSave).
Runs only from AuthCompleted (post level-2 auth).
-}
performStateEdit : String -> String -> Model -> ( Model, Cmd Msg )
performStateEdit uuid clientId model =
    let
        maybePlayerClientId =
            Dict.get uuid model.connectedPlayers

        currentState =
            model.registry
                |> List.filter (\e -> e.uuid == uuid)
                |> List.head
                |> Maybe.andThen .state
                |> Maybe.withDefault (Encode.object [])

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

                -- Pause (don't drop) any live IQ timer for this player: bump its
                -- epoch so any in-flight Process.sleep becomes a stale no-op when it
                -- fires, but keep every field (dingCount/totalDings/phase/...) so a
                -- reconnect (ClientIqResume) picks up exactly where they left off.
                pausedTimers =
                    case maybeUuid of
                        Just uuid ->
                            Dict.update uuid (Maybe.map (\s -> { s | epoch = s.epoch + 1 })) model.iqTimers

                        Nothing ->
                            model.iqTimers
            in
            case maybeUuid of
                Nothing ->
                    ( { model | distClients = cleanedDist, iqTimers = pausedTimers }, Cmd.none )

                Just uuid ->
                    -- Leave the player's persisted state exactly as it was. The
                    -- jeopardy snapshot (mid-game screen → savedState, reset to
                    -- BeginScreen) now happens lazily on their next stateRequest
                    -- (see ClientStateRequest below), so a server stop/restart that
                    -- never fires a disconnect still resumes the player correctly.
                    ( { model
                        | connectedPlayers = Dict.remove uuid model.connectedPlayers
                        , distClients = cleanedDist
                        , iqTimers = pausedTimers
                      }
                    , Cmd.none
                    )

        MessageReceived { clientId, payload } ->
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
                                    storedState =
                                        Maybe.withDefault (Encode.object []) entry.state

                                    -- If the player left mid-game (persisted screen is
                                    -- anything other than BeginScreen), snapshot that
                                    -- screen into savedState and reset to BeginScreen so
                                    -- they resume via the jeopardy Start flow. A player
                                    -- already on BeginScreen — or one who never started
                                    -- (empty state, no screen tag) — is delivered as-is,
                                    -- leaving their savedState and jeopardyPlaying flag
                                    -- untouched.
                                    screenTag =
                                        Decode.decodeValue (Decode.at [ "screen", "tag" ] Decode.string) storedState
                                            |> Result.withDefault ""

                                    connectedModel =
                                        { model | connectedPlayers = Dict.insert uuid clientId model.connectedPlayers }
                                in
                                if screenTag == "" || screenTag == "BeginScreen" then
                                    ( connectedModel
                                    , sendToClient { clientId = clientId, payload = stateEnvelope storedState }
                                    )

                                else
                                    let
                                        snapshotted =
                                            snapshotForJeopardy storedState

                                        newRegistry =
                                            updateEntryState uuid snapshotted model.registry
                                    in
                                    ( { connectedModel | registry = newRegistry }
                                    , Cmd.batch
                                        [ writeRegistry newRegistry
                                        , sendToClient { clientId = clientId, payload = stateEnvelope snapshotted }
                                        ]
                                    )

                Ok (ClientStateUpdate inner) ->
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            let
                                rawRegistry =
                                    updateEntryState uuid inner model.registry

                                -- IQ-only override, for now: if there's a live server-authoritative
                                -- IQ timer for this player, its derived screen wins over whatever
                                -- the client itself just self-reported, closing the drift/clobber
                                -- vector this whole persistence change exists to fix. Every other
                                -- screen/player still flows through untouched -- this is the
                                -- intentionally-scoped-down version of "the client's state should
                                -- be 100% derivable from the server's" (IQ-only, for now; see the
                                -- doc comment on IqTimerState).
                                newRegistry =
                                    case Dict.get uuid model.iqTimers of
                                        Just state ->
                                            persistIqTimerInRegistry uuid (Just state) rawRegistry

                                        Nothing ->
                                            rawRegistry

                                -- Deliver the win text only at win time, as its own message
                                -- (never bundled into the client), when the incoming state
                                -- shows the player is transitioning into the win screen.
                                winTextCmd =
                                    if stateIsWin inner then
                                        model.registry
                                            |> List.filter (\e -> e.uuid == uuid)
                                            |> List.head
                                            |> Maybe.map (\e -> sendToClient { clientId = clientId, payload = winTextEnvelope e.winText })
                                            |> Maybe.withDefault Cmd.none

                                    else
                                        Cmd.none
                            in
                            ( { model | registry = newRegistry }
                            , Cmd.batch
                                [ writeRegistry newRegistry
                                , sendToClient { clientId = clientId, payload = stateUpdateAckEnvelope }
                                , winTextCmd
                                ]
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
                                            , state = Nothing
                                            , pendingStateEdit = False
                                            , winText = ""
                                            , iqTimer = Nothing
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

                Ok (ClientDistComplete { uuid, filename, winText }) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == uuid then
                                let
                                    newEntry =
                                        { uuid = uuid
                                        , filename = filename
                                        , platform = info.platform
                                        , state = Nothing
                                        , pendingStateEdit = False
                                        , winText = winText
                                        , iqTimer = Nothing
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
                            case Decode.decodeString Decode.value json of
                                Ok parsedState ->
                                    let
                                        -- Apply the admin's raw edit first, then reconcile against
                                        -- *that* registry -- not the pre-edit one -- so the IQ
                                        -- reconciliation's registry write (iqTimer + re-derived
                                        -- screen) isn't discarded by this record update. Previously
                                        -- these were computed independently from the same pre-edit
                                        -- model and stitched together, which silently dropped
                                        -- whatever reconcileIqTimerAfterEdit put in .registry.
                                        rawEditedRegistry =
                                            updateEntryState editUuid parsedState model.registry

                                        reconciledModel =
                                            reconcileIqTimerAfterEdit editUuid parsedState { model | registry = rawEditedRegistry }
                                    in
                                    ( { reconciledModel
                                        | pendingStateEdits = Set.remove editUuid model.pendingStateEdits
                                        , distClients = clearedDist
                                      }
                                    , Cmd.batch
                                        [ writeRegistry reconciledModel.registry
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

                Ok (ClientDistReplaceComplete { newUuid, oldUuid, filename }) ->
                    case Dict.get clientId model.distClients of
                        Just (AwaitingUpload info) ->
                            if info.uuid == newUuid then
                                let
                                    oldEntry =
                                        model.registry
                                            |> List.filter (\e -> e.uuid == oldUuid)
                                            |> List.head

                                    oldState =
                                        oldEntry |> Maybe.andThen .state

                                    newEntry =
                                        { uuid = newUuid
                                        , filename = filename
                                        , platform = info.platform
                                        , state = oldState
                                        , pendingStateEdit = True
                                        , winText = oldEntry |> Maybe.map .winText |> Maybe.withDefault ""

                                        -- Carry the IQ snapshot to the new uuid too, same as state/winText.
                                        -- (model.iqTimers itself stays keyed by oldUuid until a restart
                                        -- rehydrates it under newUuid from this registry row -- a pre-existing
                                        -- gap in replacement handling, not something this change introduces.)
                                        , iqTimer = oldEntry |> Maybe.andThen .iqTimer
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
                    -- the client's -- see startCountdown.
                    case findUuidByClient clientId model.connectedPlayers of
                        Just uuid ->
                            startCountdown uuid model

                        Nothing ->
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
                    -- (which resets the run) when the player presses Begin again.
                    case findUuidByClient clientId model.connectedPlayers of
                        Nothing ->
                            ( model, Cmd.none )

                        Just uuid ->
                            case Dict.get uuid model.iqTimers of
                                Just state ->
                                    if state.phase == IqDingShown && state.lastDing == TrapFake then
                                        let
                                            caught =
                                                applyCatch state
                                        in
                                        setIqTimer uuid { caught | phase = IqIdle } model

                                    else
                                        ( model, Cmd.none )

                                Nothing ->
                                    ( model, Cmd.none )

                Ok ClientIqResume ->
                    -- The client just restored a saved IQ screen (countdown/active)
                    -- after reconnecting. Re-arm whatever was paused for it -- a
                    -- no-op if there's nothing to resume (e.g. IqIdle, or no entry).
                    case findUuidByClient clientId model.connectedPlayers of
                        Just uuid ->
                            resumeIqTimer uuid model

                        Nothing ->
                            ( model, Cmd.none )

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
                                parseRegistryJsonl contents

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
                        in
                        ( { model
                            | registry = parsedRegistry
                            , pendingStateEdits = rehydratedPendingStateEdits
                            , iqTimers = rehydratedIqTimers
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
                            , Cmd.batch [ persistCmd, sendToPlayer uuid model iqCountdownCompleteEnvelope ]
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


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ onConnection ClientConnected
        , onDisconnection ClientDisconnected
        , onMessage MessageReceived
        , authResult AuthCompleted
        , writeFileResult WriteFileCompleted
        , readFileResult
            (\{ path, contents, error } ->
                case ( contents, error ) of
                    ( Just c, _ ) ->
                        FileRead path (Ok c)

                    ( _, Just e ) ->
                        FileRead path (Err e)

                    _ ->
                        FileRead path (Err "unknown error")
            )
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

port onMessage : ({ clientId : String, payload : Encode.Value } -> msg) -> Sub msg

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
