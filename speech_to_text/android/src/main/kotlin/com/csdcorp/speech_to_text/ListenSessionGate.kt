package com.csdcorp.speech_to_text

/**
 * Which listen a recognizer callback belongs to, and when the next listen may start its session.
 *
 * The plugin keeps one `SpeechRecognizer` and is its only `RecognitionListener`, so every
 * callback of every session arrives through the same object and none of them says which session
 * it is about. A session ends with exactly one answer: `onResults` or `onError`. Stopping it does
 * not end it: the recognizer first finishes what it heard, and with the default (network)
 * recognizer that answer is a round trip away. Until it has come,
 *
 *  - the recognizer refuses a new session on the same `SpeechRecognizer` — `ERROR_CLIENT` from
 *    Android 14 (`RecognitionService` already has a session for that listener), and
 *    `ERROR_RECOGNIZER_BUSY` on 11 to 13 — so a listen started then never hears anything; and
 *  - the answer, when it does come, cannot be told from an answer to the listen that came next.
 *
 * Both happened in Speak Attack on Android: a card accepted on a partial result was stopped, the
 * next card's listen came 50 ms later, its session was refused, and the first card's final
 * result then arrived and stood as the next card's only transcript ("TV" on the clock card).
 *
 * So a listen that comes while a session is still to answer does not start one. That session is
 * marked replaced: whatever it still reports is dropped, its answer included, and its answer is
 * what starts the waiting listen's session. One that has not answered within
 * [REPLACED_SESSION_TIMEOUT_MS] is cancelled, and the listen starts anyway.
 *
 * A listen that comes while no session is to answer starts exactly as it always did, and every
 * callback of its session is delivered as before.
 *
 * Bookkeeping only, with no Android types, so that it can be tested on the JVM. Called on the
 * main thread by [SpeechToTextPlugin], which does what each call answers.
 */
internal class ListenSessionGate {

    /** What [requestStart] answers. */
    enum class Start {
        /** No session is still to answer: start this listen's session now. */
        NOW,

        /** A replaced session is still to answer: start once it has ([Answer.DROP_AND_START]). */
        AFTER_REPLACED_ANSWER,
    }

    /** What [answered] answers. */
    enum class Answer {
        /** The current session's answer (or one that belongs to no session, as before): send it. */
        DELIVER,

        /** The replaced session's answer: drop it. */
        DROP,

        /** The replaced session's answer, and a listen was waiting for it: drop it, then start. */
        DROP_AND_START,
    }

    private enum class Session {
        /** No session is still to answer. */
        NONE,

        /** The current listen's session is running, or still to answer. */
        CURRENT,

        /** The session still to answer belongs to a listen that was replaced. */
        REPLACED,
    }

    private var session = Session.NONE

    /** The current listen asked for its session and waits for the replaced one's answer. */
    var startWaiting = false
        private set

    /** A listen asks for a session. */
    fun requestStart(): Start {
        if (session == Session.NONE) return Start.NOW
        session = Session.REPLACED
        startWaiting = true
        return Start.AFTER_REPLACED_ANSWER
    }

    /** The plugin started the current listen's session on the recognizer. */
    fun sessionStarted() {
        session = Session.CURRENT
        startWaiting = false
    }

    /**
     * Whether a callback that is not an answer — partial results, end of speech, a sound level —
     * is delivered. Only a replaced session's are not.
     */
    fun deliversProgress(): Boolean = session != Session.REPLACED

    /** An answer arrived: `onResults` or `onError`. */
    fun answered(): Answer {
        val replaced = session == Session.REPLACED
        session = Session.NONE
        if (!replaced) return Answer.DELIVER
        if (!startWaiting) return Answer.DROP
        startWaiting = false
        return Answer.DROP_AND_START
    }

    /**
     * The waiting listen was stopped or cancelled before its session started. The replaced
     * session is still to answer, and is still dropped when it does.
     */
    fun dropWaitingStart() {
        startWaiting = false
    }

    /**
     * The session will not answer: it was cancelled, or its recognizer destroyed. True when a
     * listen was waiting for it, which starts now.
     */
    fun sessionGone(): Boolean {
        session = Session.NONE
        if (!startWaiting) return false
        startWaiting = false
        return true
    }

    /**
     * The replaced session has not answered in time. True when a listen is waiting for it: the
     * plugin cancels the replaced session and starts that listen's.
     */
    fun giveUpOnReplaced(): Boolean {
        if (session != Session.REPLACED || !startWaiting) return false
        return sessionGone()
    }

    companion object {
        /**
         * How long a listen waits for the answer of the session it replaced. The answer to a
         * stopped session is normally a network round trip away; this is for one that never
         * comes. Past it the listen loses its first moments instead of the whole listen.
         */
        const val REPLACED_SESSION_TIMEOUT_MS = 1500L
    }
}
