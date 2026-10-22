package com.csdcorp.speech_to_text

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.Looper
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowSpeechRecognizer
import java.nio.ByteBuffer
import java.time.Duration

/**
 * The real SpeechToTextPlugin on Robolectric's main looper, with a recognizer that records what
 * the plugin asks of it. The test plays the recognizer: it calls the plugin's RecognitionListener
 * methods the way the framework does, on the main thread, in the order Android delivers them.
 *
 * The defect (Speak Attack on Android, 2.3.43 (134)): a card accepted on a partial result stops
 * its listen; the next card's listen comes 50 ms later, while the stopped session still owes its
 * final result. The plugin started a session anyway — which Android refuses until the answer has
 * come — and that answer then went to Dart as the next listen's.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], shadows = [SpeechToTextPluginSessionTest.RecordingRecognizer::class])
class SpeechToTextPluginSessionTest {

    /** Records the plugin's calls on its SpeechRecognizer: start, stop, cancel. */
    @Implements(SpeechRecognizer::class)
    class RecordingRecognizer : ShadowSpeechRecognizer() {
        @Implementation
        override fun startListening(intent: Intent?) {
            recognizerCalls += "start"
            super.startListening(intent)
        }

        @Implementation
        fun stopListening() {
            recognizerCalls += "stop"
        }

        @Implementation
        fun cancel() {
            recognizerCalls += "cancel"
        }
    }

    /** What the plugin sends to Dart. */
    private class RecordingMessenger : BinaryMessenger {
        val sent = mutableListOf<String>()

        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            if (message == null) return
            message.flip()
            val call = StandardMethodCodec.INSTANCE.decodeMethodCall(message)
            sent += when (call.method) {
                "notifyStatus" -> "status:${call.arguments}"
                "textRecognition" -> {
                    val json = JSONObject(call.arguments as String)
                    val words = json.getJSONArray("alternates").getJSONObject(0).getString("recognizedWords")
                    if (json.getBoolean("finalResult")) "final:$words" else "partial:$words"
                }
                "notifyError" -> "error:${JSONObject(call.arguments as String).getString("errorMsg")}"
                "soundLevelChange" -> "sound"
                else -> call.method
            }
        }

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }

    private class Reply : MethodChannel.Result {
        var value: Any? = "none"
        override fun success(result: Any?) { value = result }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { value = "error:$errorCode" }
        override fun notImplemented() { value = "notImplemented" }
    }

    private lateinit var plugin: SpeechToTextPlugin
    private val messenger = RecordingMessenger()

    @Before
    fun setUp() {
        recognizerCalls.clear()
        val application = RuntimeEnvironment.getApplication()
        val context: Context = application
        shadowOf(application).grantPermissions(Manifest.permission.RECORD_AUDIO)
        val recognizerApp = ComponentName("com.example.recognizer", "com.example.recognizer.Service")
        shadowOf(context.packageManager).apply {
            addServiceIfNotPresent(recognizerApp)
            addIntentFilterForService(recognizerApp, IntentFilter(RecognitionService.SERVICE_INTERFACE))
        }
        plugin = SpeechToTextPlugin()
        SpeechToTextPlugin::class.java
            .getDeclaredMethod("onAttachedToEngine", Context::class.java, BinaryMessenger::class.java)
            .apply { isAccessible = true }
            .invoke(plugin, context, messenger)
        assertEquals(true, call("initialize").value)
        messenger.sent.clear()
    }

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    /** A method call from Dart, and everything it posts. */
    private fun call(method: String, arguments: Map<String, Any?> = emptyMap()): Reply {
        val reply = Reply()
        plugin.onMethodCall(MethodCall(method, arguments), reply)
        idle()
        return reply
    }

    private fun listen() = call("listen", mapOf("listenMode" to ListenMode.confirmation.ordinal))

    private fun readings(vararg words: String) = Bundle().apply {
        putStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION, arrayListOf(*words))
    }

    private fun later(millis: Long = 300) =
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(millis))

    /**
     * Before a final result that is not the previous one again: the plugin discards a final that
     * comes within 100 ms of the last, by the wall clock (`System.currentTimeMillis`), which
     * Robolectric's looper does not move.
     */
    private fun pastTheDuplicateWindow() = Thread.sleep(150)

    /** The tv card: its session hears "TV", the card is accepted on it and stops the session. */
    private fun tvCardAcceptedOnItsPartial() {
        assertEquals(true, listen().value)
        plugin.onPartialResults(readings("TV"))
        later()
        call("stop")
        assertEquals(listOf("start", "stop"), recognizerCalls)
        later(50)
        messenger.sent.clear()
    }

    @Test
    fun theNextListenWaitsForTheStoppedSessionsAnswerAndDropsIt() {
        tvCardAcceptedOnItsPartial()

        assertEquals(true, listen().value)
        assertEquals("no session while the stopped one is still to answer",
            listOf("start", "stop"), recognizerCalls)
        assertEquals(listOf("status:listening"), messenger.sent)

        // What the tv card's session still reports, and then its answer.
        plugin.onPartialResults(readings("TV and"))
        plugin.onRmsChanged(9.5f)
        plugin.onEndOfSpeech()
        plugin.onResults(readings("TV and the"))
        idle()
        assertEquals("none of it reaches Dart", listOf("status:listening"), messenger.sent)
        assertEquals("the answer starts the clock card's session",
            listOf("start", "stop", "start"), recognizerCalls)

        // The clock card's own session, delivered as always.
        plugin.onRmsChanged(9.5f)
        idle()
        plugin.onPartialResults(readings("clock"))
        later()
        pastTheDuplicateWindow()
        plugin.onEndOfSpeech()
        plugin.onResults(readings("clock"))
        idle()
        assertEquals(
            listOf("status:listening", "sound", "partial:clock", "status:notListening",
                "status:done", "final:clock"),
            messenger.sent)
    }

    @Test
    fun anErrorIsTheStoppedSessionsAnswerToo() {
        tvCardAcceptedOnItsPartial()
        listen()
        plugin.onError(SpeechRecognizer.ERROR_NO_MATCH)
        idle()
        assertEquals(listOf("status:listening"), messenger.sent)
        assertEquals(listOf("start", "stop", "start"), recognizerCalls)

        // The clock card's own error is delivered, and ends it.
        plugin.onError(SpeechRecognizer.ERROR_NO_MATCH)
        idle()
        assertEquals(
            listOf("status:listening", "status:notListening", "status:doneNoResult",
                "error:error_speech_timeout"),
            messenger.sent)
    }

    @Test
    fun aDuplicateOfTheStoppedSessionsAnswerIsDiscarded() {
        tvCardAcceptedOnItsPartial()
        listen()
        plugin.onResults(readings("TV"))
        plugin.onResults(readings("TV"))
        idle()
        assertEquals(listOf("status:listening"), messenger.sent)
        assertEquals(listOf("start", "stop", "start"), recognizerCalls)

        // Not taken for the clock card's answer: its session is still the one in flight, so the
        // listen after it waits for its answer.
        call("stop")
        listen()
        assertEquals(listOf("start", "stop", "start", "stop"), recognizerCalls)
        later()
        pastTheDuplicateWindow()
        plugin.onResults(readings("clock"))
        idle()
        assertEquals(listOf("start", "stop", "start", "stop", "start"), recognizerCalls)
    }

    @Test
    fun aSessionThatHasAnsweredIsNotWaitedFor() {
        listen()
        plugin.onPartialResults(readings("TV"))
        plugin.onEndOfSpeech()
        plugin.onResults(readings("TV"))
        call("stop")
        assertEquals("nothing to stop: the session ended", listOf("start"), recognizerCalls)
        later(50)
        messenger.sent.clear()

        listen()
        assertEquals("started at once, as before", listOf("start", "start"), recognizerCalls)
        plugin.onPartialResults(readings("clock"))
        idle()
        assertEquals(listOf("status:listening", "partial:clock"), messenger.sent)
    }

    @Test
    fun aStoppedSessionThatNeverAnswersIsCancelledAfterTheWait() {
        tvCardAcceptedOnItsPartial()
        listen()
        shadowOf(Looper.getMainLooper())
            .idleFor(Duration.ofMillis(ListenSessionGate.REPLACED_SESSION_TIMEOUT_MS - 1))
        assertEquals(listOf("start", "stop"), recognizerCalls)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1))
        assertEquals(listOf("start", "stop", "cancel", "start"), recognizerCalls)

        plugin.onPartialResults(readings("clock"))
        idle()
        assertEquals(listOf("status:listening", "partial:clock"), messenger.sent)
    }

    @Test
    fun aListenStoppedWhileItWaitsStartsNothing() {
        tvCardAcceptedOnItsPartial()
        listen()
        assertEquals(true, call("stop").value)
        assertEquals("its stop goes nowhere: it has no session",
            listOf("start", "stop"), recognizerCalls)

        plugin.onResults(readings("TV"))
        shadowOf(Looper.getMainLooper())
            .idleFor(Duration.ofMillis(ListenSessionGate.REPLACED_SESSION_TIMEOUT_MS * 2))
        assertEquals(listOf("start", "stop"), recognizerCalls)
        assertEquals(
            listOf("status:listening", "status:notListening", "status:doneNoResult"),
            messenger.sent)

        // The next listen finds nothing to wait for.
        listen()
        assertEquals(listOf("start", "stop", "start"), recognizerCalls)
    }

    @Test
    fun aListenCancelledWhileItWaitsCancelsNothing() {
        tvCardAcceptedOnItsPartial()
        listen()
        assertEquals(true, call("cancel").value)
        assertEquals(listOf("start", "stop"), recognizerCalls)
        plugin.onResults(readings("TV"))
        idle()
        assertEquals(
            listOf("status:listening", "status:notListening", "status:doneNoResult"),
            messenger.sent)
    }

    @Test
    fun aListenThatArrivesWhileACancelIsOnItsWayStartsAtTheCancel() {
        listen()
        plugin.onPartialResults(readings("TV"))
        // Dart cancels and listens again without waiting in between.
        plugin.onMethodCall(MethodCall("cancel", emptyMap<String, Any>()), Reply())
        plugin.onMethodCall(
            MethodCall("listen", mapOf("listenMode" to ListenMode.confirmation.ordinal)), Reply())
        idle()
        assertEquals(listOf("start", "cancel", "start"), recognizerCalls)
    }

    @Test
    fun aCancelledSessionIsNotWaitedFor() {
        listen()
        call("cancel")
        later(50)
        listen()
        assertEquals(listOf("start", "cancel", "start"), recognizerCalls)
    }

    @Test
    fun theFirstListenStartsAtOnceAsBefore() {
        assertEquals(true, listen().value)
        assertEquals(listOf("start"), recognizerCalls)
        plugin.onPartialResults(readings("TV"))
        idle()
        assertEquals(listOf("status:listening", "partial:TV"), messenger.sent)
    }

    @Test
    fun aListenWhileListeningIsStillRefused() {
        listen()
        assertEquals(false, listen().value)
        assertEquals(listOf("start"), recognizerCalls)
    }

    companion object {
        val recognizerCalls = mutableListOf<String>()
    }
}
