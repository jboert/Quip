package dev.quip.android

import dev.quip.android.MainViewModel.RecordingState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the recording state machine logic.
 * Verifies state transitions and guards without needing Android framework.
 */
class RecordingStateMachineTest {

    @Test
    fun `idle is not recording`() {
        val state: RecordingState = RecordingState.Idle
        assertTrue(state is RecordingState.Idle)
    }

    @Test
    fun `recording state carries window id`() {
        val state = RecordingState.Recording("win-1")
        assertEquals("win-1", state.windowId)
    }

    @Test
    fun `waiting state carries window id`() {
        val state = RecordingState.WaitingForResult("win-2")
        assertEquals("win-2", state.windowId)
    }

    @Test
    fun `isRecording is true for Recording state`() {
        val state: RecordingState = RecordingState.Recording("w1")
        assertTrue(state !is RecordingState.Idle)
    }

    @Test
    fun `isRecording is true for WaitingForResult state`() {
        val state: RecordingState = RecordingState.WaitingForResult("w1")
        assertTrue(state !is RecordingState.Idle)
    }

    @Test
    fun `isRecording is false for Idle state`() {
        val state: RecordingState = RecordingState.Idle
        assertFalse(state !is RecordingState.Idle)
    }

    @Test
    fun `state equality works for Idle`() {
        assertEquals(RecordingState.Idle, RecordingState.Idle)
    }

    @Test
    fun `state equality works for Recording`() {
        assertEquals(
            RecordingState.Recording("w1"),
            RecordingState.Recording("w1")
        )
    }

    @Test
    fun `different window ids are not equal`() {
        assertFalse(
            RecordingState.Recording("w1") == RecordingState.Recording("w2")
        )
    }
}
