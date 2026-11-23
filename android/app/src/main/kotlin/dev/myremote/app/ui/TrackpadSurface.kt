package dev.myremote.app.ui

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.changedToDownIgnoreConsumed
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.myremote.app.R
import dev.myremote.app.core.trackpad.TrackpadAction
import dev.myremote.app.core.trackpad.TrackpadGestureProcessor

/**
 * The touch surface. All gesture logic is in [TrackpadGestureProcessor]; this only feeds it
 * touches in dp and wakes it up when it has something due while no finger is moving.
 */
@Composable
fun TrackpadSurface(enabled: Boolean, onAction: (TrackpadAction) -> Unit, modifier: Modifier = Modifier) {
    val processor = remember { TrackpadGestureProcessor() }
    val view = LocalView.current
    val currentOnAction by rememberUpdatedState(onAction)
    val shape = RoundedCornerShape(28.dp)
    val label = stringResource(R.string.trackpad_label)

    Box(
        modifier = modifier
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            // Swipes that start at the screen edge should move the cursor, not go "back".
            .systemGestureExclusion()
            .semantics { contentDescription = label }
            .pointerInput(enabled) {
                processor.onCancel(SystemClock.uptimeMillis())
                if (!enabled) return@pointerInput
                val pxPerDp = density

                fun deliver(actions: List<TrackpadAction>) {
                    for (action in actions) {
                        if (action is TrackpadAction.Click) {
                            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                        }
                        currentOnAction(action)
                    }
                }

                awaitPointerEventScope {
                    while (true) {
                        val deadline = processor.nextDeadlineMs()
                        val event = if (deadline == null) {
                            awaitPointerEvent()
                        } else {
                            val wait = (deadline - SystemClock.uptimeMillis()).coerceAtLeast(1)
                            withTimeoutOrNull(wait) { awaitPointerEvent() }
                        }
                        if (event == null) {
                            deliver(processor.onTick(SystemClock.uptimeMillis()))
                            continue
                        }
                        for (change in event.changes) {
                            val id = change.id.value
                            val x = (change.position.x / pxPerDp).toDouble()
                            val y = (change.position.y / pxPerDp).toDouble()
                            val time = change.uptimeMillis
                            val actions = when {
                                change.changedToDownIgnoreConsumed() -> processor.onDown(id, x, y, time)
                                change.changedToUpIgnoreConsumed() -> processor.onUp(id, time)
                                change.pressed && change.positionChanged() -> processor.onMove(id, x, y, time)
                                else -> emptyList()
                            }
                            change.consume()
                            deliver(actions)
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.padding(24.dp).alpha(if (enabled) 1f else 0.5f),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = stringResource(R.string.trackpad_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
                textAlign = TextAlign.Center,
            )
        }
    }
}
