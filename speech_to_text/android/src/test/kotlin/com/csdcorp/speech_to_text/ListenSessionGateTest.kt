package com.csdcorp.speech_to_text

import com.csdcorp.speech_to_text.ListenSessionGate.Answer
import com.csdcorp.speech_to_text.ListenSessionGate.Start
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The plugin's bookkeeping of which session a recognizer callback belongs to.
 *
 * Each test calls the gate the way SpeechToTextPlugin does: [ListenSessionGate.requestStart] in
 * startListening, [ListenSessionGate.sessionStarted] when it starts a session on the recognizer,
 * [ListenSessionGate.deliversProgress] in onPartialResults / onEndOfSpeech / onRmsChanged,
 * [ListenSessionGate.answered] in onResults / onError, [ListenSessionGate.dropWaitingStart] in a
 * stop or cancel of a listen that is still waiting, [ListenSessionGate.sessionGone] when a session
 * is cancelled or its recognizer destroyed, and [ListenSessionGate.giveUpOnReplaced] when the
 * waiting time runs out.
 */
class ListenSessionGateTest {

    /** What the plugin does with a start the gate allows. */
    private fun ListenSessionGate.startIfNow(): Start {
        val start = requestStart()
        if (start == Start.NOW) sessionStarted()
        return start
    }

    @Test
    fun aListenWithNoSessionStillToAnswerStartsAtOnce() {
        val gate = ListenSessionGate()
        assertEquals(Start.NOW, gate.startIfNow())
        assertTrue(gate.deliversProgress())
        assertEquals(Answer.DELIVER, gate.answered())
        // Its session has answered: the next listen starts at once too.
        assertEquals(Start.NOW, gate.startIfNow())
        assertFalse(gate.startWaiting)
    }

    @Test
    fun theNextListenWaitsForTheStoppedSessionsAnswerAndDropsIt() {
        // The tv card: its session hears "TV", the card is accepted on that partial result and
        // stops the session. Its final result is still on its way.
        val gate = ListenSessionGate()
        gate.startIfNow()
        assertTrue(gate.deliversProgress())

        // The clock card asks for its session 50 ms later.
        assertEquals(Start.AFTER_REPLACED_ANSWER, gate.requestStart())
        assertTrue(gate.startWaiting)

        // What the tv card's session still reports is not the clock card's.
        assertFalse("partial results / end of speech / sound", gate.deliversProgress())

        // Its final result: dropped, and the clock card's session starts.
        assertEquals(Answer.DROP_AND_START, gate.answered())
        assertFalse(gate.startWaiting)
        gate.sessionStarted()

        // From here on everything is the clock card's.
        assertTrue(gate.deliversProgress())
        assertEquals(Answer.DELIVER, gate.answered())
    }

    @Test
    fun anErrorIsAnAnswerToo() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        assertEquals(Start.AFTER_REPLACED_ANSWER, gate.requestStart())
        // onError(ERROR_NO_MATCH) from the replaced session.
        assertEquals(Answer.DROP_AND_START, gate.answered())
        gate.sessionStarted()
        // The new session's own error is delivered.
        assertEquals(Answer.DELIVER, gate.answered())
    }

    @Test
    fun aSessionThatAnsweredBeforeTheNextListenIsNotWaitedFor() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        assertEquals(Answer.DELIVER, gate.answered())
        assertEquals(Start.NOW, gate.startIfNow())
        assertTrue(gate.deliversProgress())
    }

    @Test
    fun aWaitingListenStoppedBeforeItStartsStartsNothing() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        assertEquals(Start.AFTER_REPLACED_ANSWER, gate.requestStart())

        // The card is paused while it waits.
        gate.dropWaitingStart()
        assertFalse(gate.startWaiting)

        // The replaced session is still dropped, and starts nothing now.
        assertFalse(gate.deliversProgress())
        assertEquals(Answer.DROP, gate.answered())

        // The next listen finds nothing to wait for.
        assertEquals(Start.NOW, gate.startIfNow())
    }

    @Test
    fun aListenAfterAWaitingOneWasStoppedWaitsAgain() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        assertEquals(Start.AFTER_REPLACED_ANSWER, gate.requestStart())
        gate.dropWaitingStart()

        // The replaced session has still not answered.
        assertEquals(Start.AFTER_REPLACED_ANSWER, gate.requestStart())
        assertEquals(Answer.DROP_AND_START, gate.answered())
        gate.sessionStarted()
        assertTrue(gate.deliversProgress())
    }

    @Test
    fun aReplacedSessionThatNeverAnswersIsGivenUpOn() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        assertEquals(Start.AFTER_REPLACED_ANSWER, gate.requestStart())

        // The waiting time runs out: the plugin cancels the replaced session and starts.
        assertTrue(gate.giveUpOnReplaced())
        assertFalse(gate.startWaiting)
        gate.sessionStarted()
        assertTrue(gate.deliversProgress())
        assertEquals(Answer.DELIVER, gate.answered())
    }

    @Test
    fun theWaitingTimeStartsNothingOnceTheWaitIsOver() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        gate.requestStart()
        assertEquals(Answer.DROP_AND_START, gate.answered())
        gate.sessionStarted()
        // A time-out that was not removed in time must not cancel the session that started.
        assertFalse(gate.giveUpOnReplaced())
        assertTrue(gate.deliversProgress())

        val stopped = ListenSessionGate()
        stopped.startIfNow()
        stopped.requestStart()
        stopped.dropWaitingStart()
        assertFalse("nothing is waiting", stopped.giveUpOnReplaced())

        assertFalse("nothing at all", ListenSessionGate().giveUpOnReplaced())
    }

    @Test
    fun aCancelledSessionIsNotWaitedFor() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        // cancel(): the session will not answer.
        assertFalse(gate.sessionGone())
        assertEquals(Start.NOW, gate.startIfNow())
        assertTrue(gate.deliversProgress())
    }

    @Test
    fun aListenThatCameInWhileACancelWasOnItsWayStartsAtTheCancel() {
        val gate = ListenSessionGate()
        gate.startIfNow()
        // cancel() is on its way to the recognizer when the next listen arrives.
        assertEquals(Start.AFTER_REPLACED_ANSWER, gate.requestStart())
        // The cancel reaches the recognizer: nothing more will come from that session.
        assertTrue(gate.sessionGone())
        gate.sessionStarted()
        assertTrue(gate.deliversProgress())
        assertEquals(Answer.DELIVER, gate.answered())
    }

    @Test
    fun anAnswerOfNoSessionIsDeliveredAsBefore() {
        // An error from a recognizer that could not even be bound, say.
        val gate = ListenSessionGate()
        assertTrue(gate.deliversProgress())
        assertEquals(Answer.DELIVER, gate.answered())
        assertEquals(Start.NOW, gate.startIfNow())
    }

    @Test
    fun aSecondAnswerAfterTheStartIsTakenForTheNewSessionsWhichIsWhyThePluginDropsDuplicatesFirst() {
        // Some devices deliver onResults twice within 100 ms. The plugin discards the second as a
        // duplicate before it asks the gate: asked, the gate would take it for the new session's
        // answer, and the listen after that would no longer wait.
        val gate = ListenSessionGate()
        gate.startIfNow()
        gate.requestStart()
        assertEquals(Answer.DROP_AND_START, gate.answered())
        gate.sessionStarted()
        assertEquals(Answer.DELIVER, gate.answered())
        assertEquals(Start.NOW, gate.requestStart())
    }

    @Test
    fun theWaitIsBounded() {
        // Far shorter than a Speak Attack card (3 s, and up to two more), far longer than the
        // network round trip the answer normally takes.
        assertTrue(ListenSessionGate.REPLACED_SESSION_TIMEOUT_MS in 1000L..2000L)
    }
}
