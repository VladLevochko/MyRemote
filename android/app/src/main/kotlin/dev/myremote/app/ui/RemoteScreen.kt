package dev.myremote.app.ui

import android.content.res.Resources
import android.view.HapticFeedbackConstants
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.coerceAtMost
import androidx.compose.ui.unit.dp
import dev.myremote.app.CommandFeedback
import dev.myremote.app.R
import dev.myremote.app.core.net.ConnectionState
import dev.myremote.app.core.net.FailureReason
import dev.myremote.app.core.pairing.PairingInfo
import dev.myremote.app.core.protocol.CmdAction
import dev.myremote.app.core.protocol.KeyName
import dev.myremote.app.core.protocol.Profiles
import dev.myremote.app.core.protocol.RemoteState
import dev.myremote.app.core.trackpad.TrackpadAction
import dev.myremote.app.ui.theme.StatusColors
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/** Roughly the header's height: where the snackbar is placed. */
private val HEADER_HEIGHT = 60.dp

/** Holding a repeating button: the first repeat comes after the delay, the rest at the interval. */
private const val HOLD_REPEAT_DELAY_MS = 450L
private const val HOLD_REPEAT_INTERVAL_MS = 220L

/** Sizes of the thumb controls. The trackpad takes whatever height is left above them. */
private data class RemoteMetrics(val gap: Dp, val ringMax: Dp, val cornerButton: Dp) {
    companion object {
        val Regular = RemoteMetrics(gap = 12.dp, ringMax = 248.dp, cornerButton = 56.dp)

        /** For short screens, so the trackpad keeps a usable height. */
        val Compact = RemoteMetrics(gap = 8.dp, ringMax = 204.dp, cornerButton = 48.dp)
    }
}

@Composable
fun RemoteScreen(
    pairing: PairingInfo,
    connection: ConnectionState,
    feedback: Flow<CommandFeedback>,
    onCommand: (CmdAction) -> Unit,
    onKey: (KeyName) -> Unit,
    onText: (String) -> Unit,
    onTrackpad: (TrackpadAction) -> Unit,
    onRetry: () -> Unit,
    onForget: () -> Unit,
) {
    val connected = connection as? ConnectionState.Connected
    val enabled = connected != null
    val resources = LocalResources.current
    val snackbar = remember { SnackbarHostState() }
    val profileName = profileLabel(connected?.state?.profile, resources)
    var showTextEntry by rememberSaveable { mutableStateOf(false) }
    var showForget by rememberSaveable { mutableStateOf(false) }

    KeepScreenOn(enabled)

    LaunchedEffect(feedback, profileName) {
        feedback.collect { item ->
            // A newer message replaces the one on screen instead of queueing behind it.
            snackbar.currentSnackbarData?.dismiss()
            launch { snackbar.showSnackbar(feedbackMessage(item, profileName, resources)) }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .windowInsetsPadding(WindowInsets.safeDrawing),
    ) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val metrics = if (maxHeight < 600.dp) RemoteMetrics.Compact else RemoteMetrics.Regular
            Column(
                modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp).padding(top = 4.dp, bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(metrics.gap),
            ) {
                Header(
                    name = connected?.agent?.name ?: pairing.name,
                    connection = connection,
                    onCommand = onCommand,
                    onForget = { showForget = true },
                )
                StatusBanner(connection = connection, onRetry = onRetry, onPairAgain = onForget)
                // Pointing is relative, so the pad works from wherever the thumb lands on it and
                // can take the upper part of the screen, which is a stretch to reach one-handed.
                TrackpadSurface(
                    enabled = enabled,
                    onAction = onTrackpad,
                    modifier = Modifier.fillMaxWidth().weight(1f).heightIn(min = 96.dp),
                )
                ThumbControls(metrics, enabled, onCommand, onKey, onShowTextEntry = { showTextEntry = true })
            }
        }
        // Messages appear under the header, over the top of the trackpad, so they never cover
        // the buttons: play/pause must stay reachable while one is showing.
        SnackbarHost(
            hostState = snackbar,
            modifier = Modifier.align(Alignment.TopCenter).padding(top = HEADER_HEIGHT),
        )
    }

    if (showTextEntry) {
        TextEntryDialog(onSend = onText, onKey = onKey, onDismiss = { showTextEntry = false })
    }
    if (showForget) {
        AlertDialog(
            onDismissRequest = { showForget = false },
            title = { Text(stringResource(R.string.forget_title, pairing.name)) },
            text = { Text(stringResource(R.string.forget_body)) },
            confirmButton = {
                TextButton(onClick = {
                    showForget = false
                    onForget()
                }) { Text(stringResource(R.string.forget_confirm)) }
            },
            dismissButton = { TextButton(onClick = { showForget = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun KeepScreenOn(on: Boolean) {
    val view = LocalView.current
    DisposableEffect(view, on) {
        view.keepScreenOn = on
        onDispose { view.keepScreenOn = false }
    }
}

// --- Header ---

@Composable
private fun Header(
    name: String,
    connection: ConnectionState,
    onCommand: (CmdAction) -> Unit,
    onForget: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val resources = LocalResources.current
    val (statusText, statusColor) = statusOf(connection, resources)
    val connected = connection as? ConnectionState.Connected
    val detail = connected?.state?.let { activityLabel(it, resources) }
    // Rarely needed while watching, so they live in the menu at the far end of the thumb's reach.
    val menuCommands = listOf(
        Triple(RemoteIcons.Subtitles, R.string.control_subtitles, CmdAction.ToggleSubtitles),
        Triple(RemoteIcons.Skip, R.string.control_skip, CmdAction.Skip),
        Triple(RemoteIcons.Next, R.string.control_next, CmdAction.NextItem),
        Triple(RemoteIcons.Previous, R.string.control_previous, CmdAction.PreviousItem),
    )

    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = name,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onBackground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(8.dp).background(statusColor, CircleShape))
                Spacer(Modifier.width(8.dp))
                Text(
                    text = if (detail == null) statusText else "$statusText · $detail",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(
                    RemoteIcons.More,
                    contentDescription = stringResource(R.string.menu_more),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                for ((icon, label, action) in menuCommands) {
                    DropdownMenuItem(
                        text = { Text(stringResource(label)) },
                        leadingIcon = { Icon(icon, contentDescription = null) },
                        enabled = connected != null,
                        onClick = {
                            menuOpen = false
                            onCommand(action)
                        },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.menu_forget)) },
                    onClick = {
                        menuOpen = false
                        onForget()
                    },
                )
            }
        }
    }
}

private fun statusOf(connection: ConnectionState, resources: Resources): Pair<String, Color> = when (connection) {
    ConnectionState.Disconnected -> resources.getString(R.string.status_disconnected) to StatusColors.idle
    is ConnectionState.Connected -> resources.getString(R.string.status_connected) to StatusColors.connected
    is ConnectionState.Connecting -> when (val previous = connection.lastFailure) {
        null -> resources.getString(R.string.status_connecting) to StatusColors.busy
        // Between retries the status keeps saying what is wrong instead of flickering.
        else -> failureStatus(previous, resources)
    }
    is ConnectionState.Failed -> failureStatus(connection.reason, resources)
}

private fun failureStatus(reason: FailureReason, resources: Resources): Pair<String, Color> = when (reason) {
    FailureReason.Unauthorized -> resources.getString(R.string.status_unauthorized) to StatusColors.failed
    FailureReason.UnsupportedVersion -> resources.getString(R.string.status_version) to StatusColors.failed
    is FailureReason.PinMismatch -> resources.getString(R.string.status_pin_mismatch) to StatusColors.failed
    FailureReason.HeartbeatTimeout -> resources.getString(R.string.status_retry_heartbeat) to StatusColors.busy
    FailureReason.HandshakeTimeout -> resources.getString(R.string.status_retry_handshake) to StatusColors.busy
    is FailureReason.ClosedByServer -> resources.getString(R.string.status_retry_closed) to StatusColors.busy
    is FailureReason.Network -> resources.getString(R.string.status_retry_network) to StatusColors.busy
}

/** Profile names defined by protocol v1; a profile from a newer agent is shown as sent. */
private fun profileLabel(profile: String?, resources: Resources): String = when (profile) {
    null, Profiles.GENERIC -> resources.getString(R.string.profile_generic)
    Profiles.YOUTUBE -> resources.getString(R.string.profile_youtube)
    Profiles.NETFLIX -> resources.getString(R.string.profile_netflix)
    Profiles.APPLE_TV -> resources.getString(R.string.profile_appletv)
    else -> profile
}

/** "YouTube · Google Chrome", or just the app name when no specific profile applies. */
private fun activityLabel(state: RemoteState, resources: Resources): String {
    val app = state.frontApp?.name?.takeIf { it.isNotBlank() }
    val profile = profileLabel(state.profile, resources)
    return when {
        app == null -> profile
        state.profile == Profiles.GENERIC -> app
        app == profile -> profile
        else -> "$profile · $app"
    }
}

// --- Banners ---

@Composable
private fun StatusBanner(connection: ConnectionState, onRetry: () -> Unit, onPairAgain: () -> Unit) {
    val failure = when (connection) {
        is ConnectionState.Failed -> connection.reason
        is ConnectionState.Connecting -> connection.lastFailure
        else -> null
    }
    when {
        connection is ConnectionState.Connected && !connection.state.accessibility -> Banner(
            title = stringResource(R.string.banner_accessibility_title),
            body = stringResource(R.string.banner_accessibility_body),
            container = MaterialTheme.colorScheme.tertiaryContainer,
            content = MaterialTheme.colorScheme.onTertiaryContainer,
        )

        failure == FailureReason.Unauthorized -> Banner(
            title = stringResource(R.string.status_unauthorized),
            body = stringResource(R.string.banner_unauthorized_body),
            container = MaterialTheme.colorScheme.errorContainer,
            content = MaterialTheme.colorScheme.onErrorContainer,
            actionLabel = stringResource(R.string.action_pair_again),
            onAction = onPairAgain,
        )

        failure == FailureReason.UnsupportedVersion -> Banner(
            title = stringResource(R.string.status_version),
            body = stringResource(R.string.banner_version_body),
            container = MaterialTheme.colorScheme.errorContainer,
            content = MaterialTheme.colorScheme.onErrorContainer,
            actionLabel = stringResource(R.string.action_retry),
            onAction = onRetry,
        )

        failure is FailureReason.PinMismatch -> Banner(
            title = stringResource(R.string.status_pin_mismatch),
            body = stringResource(R.string.banner_pin_body),
            container = MaterialTheme.colorScheme.errorContainer,
            content = MaterialTheme.colorScheme.onErrorContainer,
            actionLabel = stringResource(R.string.action_pair_again),
            onAction = onPairAgain,
        )
    }
}

@Composable
private fun Banner(
    title: String,
    body: String,
    container: Color,
    content: Color,
    actionLabel: String? = null,
    onAction: () -> Unit = {},
) {
    Surface(
        modifier = Modifier.fillMaxWidth().semantics { liveRegion = LiveRegionMode.Polite },
        shape = RoundedCornerShape(18.dp),
        color = container,
        contentColor = content,
    ) {
        Row(Modifier.padding(start = 14.dp, top = 12.dp, end = 14.dp, bottom = if (actionLabel == null) 12.dp else 4.dp)) {
            Icon(RemoteIcons.Warning, contentDescription = null, modifier = Modifier.padding(top = 2.dp).size(22.dp))
            Spacer(Modifier.width(12.dp))
            Column {
                Text(title, style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.height(2.dp))
                Text(body, style = MaterialTheme.typography.bodySmall)
                if (actionLabel != null) {
                    TextButton(onClick = onAction, modifier = Modifier.align(Alignment.End)) {
                        Text(actionLabel, color = content)
                    }
                }
            }
        }
    }
}

// --- Buttons ---

/**
 * The remote's button: a large flat target that gives a haptic tick the moment it is pressed
 * (not on release), so it can be used without looking at the phone.
 *
 * With [repeatOnHold] the action fires on press and then keeps firing while the button is held,
 * like the seek and volume keys of a physical remote.
 */
@Composable
private fun RemoteButton(
    onClick: () -> Unit,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    shape: Shape = CircleShape,
    containerColor: Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    contentColor: Color = MaterialTheme.colorScheme.onSurface,
    repeatOnHold: Boolean = false,
    content: @Composable () -> Unit,
) {
    val interactions = remember { MutableInteractionSource() }
    val view = LocalView.current
    val currentOnClick by rememberUpdatedState(onClick)
    // Set while a press has already fired the action, so the click that ends the press does not
    // fire it a second time. A click with no press before it (TalkBack, a keyboard) still works.
    var firedOnPress by remember { mutableStateOf(false) }

    // Keyed on `enabled` so that losing the connection mid-hold stops the repeats.
    LaunchedEffect(interactions, view, repeatOnHold, enabled) {
        var repeating: Job? = null
        interactions.interactions.collect { interaction ->
            when (interaction) {
                is PressInteraction.Press -> {
                    view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                    if (repeatOnHold) {
                        firedOnPress = true
                        repeating?.cancel()
                        repeating = launch {
                            currentOnClick()
                            delay(HOLD_REPEAT_DELAY_MS)
                            while (true) {
                                currentOnClick()
                                delay(HOLD_REPEAT_INTERVAL_MS)
                            }
                        }
                    }
                }

                is PressInteraction.Release -> repeating?.cancel()

                is PressInteraction.Cancel -> {
                    repeating?.cancel()
                    firedOnPress = false
                }
            }
        }
    }
    Surface(
        onClick = { if (firedOnPress) firedOnPress = false else onClick() },
        modifier = modifier.semantics { role = Role.Button },
        enabled = enabled,
        shape = shape,
        color = if (enabled) containerColor else containerColor.copy(alpha = containerColor.alpha * 0.45f),
        contentColor = if (enabled) contentColor else contentColor.copy(alpha = 0.38f),
        interactionSource = interactions,
    ) {
        Box(contentAlignment = Alignment.Center) { content() }
    }
}

@Composable
private fun IconRemoteButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    iconSize: Dp = 26.dp,
    containerColor: Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    contentColor: Color = MaterialTheme.colorScheme.onSurface,
    repeatOnHold: Boolean = false,
) {
    RemoteButton(onClick, enabled, modifier, CircleShape, containerColor, contentColor, repeatOnHold) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(iconSize))
    }
}

// --- Thumb controls ---

/**
 * Everything used while watching, in the lower part of the screen where the thumb of the hand
 * holding the phone rests: the playback ring, with one small button in each corner around it.
 * The layout is symmetric, so it works the same in either hand.
 */
@Composable
private fun ThumbControls(
    metrics: RemoteMetrics,
    enabled: Boolean,
    onCommand: (CmdAction) -> Unit,
    onKey: (KeyName) -> Unit,
    onShowTextEntry: () -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Narrow enough that the corner buttons clear the ring's edge on any screen width.
        val ring = (maxWidth - metrics.cornerButton * 1.4f).coerceAtMost(metrics.ringMax)
        val corner = Modifier.size(metrics.cornerButton)
        // Raised by half its own height: the very bottom of the screen makes the thumb curl, and
        // its relaxed arc sits higher up.
        Box(Modifier.fillMaxWidth().padding(bottom = ring / 2).height(ring)) {
            PlaybackRing(ring, enabled, onCommand, Modifier.align(Alignment.Center))
            IconRemoteButton(
                RemoteIcons.Back,
                stringResource(R.string.control_back),
                { onKey(KeyName.Escape) },
                enabled,
                corner.align(Alignment.TopStart),
            )
            IconRemoteButton(
                RemoteIcons.Fullscreen,
                stringResource(R.string.control_fullscreen),
                { onCommand(CmdAction.ToggleFullscreen) },
                enabled,
                corner.align(Alignment.TopEnd),
            )
            IconRemoteButton(
                RemoteIcons.Mute,
                stringResource(R.string.control_mute),
                { onCommand(CmdAction.ToggleMute) },
                enabled,
                corner.align(Alignment.BottomStart),
            )
            IconRemoteButton(
                RemoteIcons.Keyboard,
                stringResource(R.string.control_keyboard),
                onShowTextEntry,
                enabled,
                corner.align(Alignment.BottomEnd),
            )
        }
    }
}

/**
 * A disc with play/pause in the middle and four directions around it: seek to the sides, volume
 * up and down. Seek and volume repeat while held.
 */
@Composable
private fun PlaybackRing(
    diameter: Dp,
    enabled: Boolean,
    onCommand: (CmdAction) -> Unit,
    modifier: Modifier = Modifier,
) {
    val centre = diameter * 0.42f
    val inset = 6.dp
    // Each direction gets the full width of the band between the centre button and the edge.
    val zone = (diameter - centre) / 2 - inset * 2
    val disc = MaterialTheme.colorScheme.surfaceContainerHigh

    Box(modifier.size(diameter).background(if (enabled) disc else disc.copy(alpha = 0.45f), CircleShape)) {
        val directions = listOf(
            RingDirection(RemoteIcons.Plus, R.string.control_volume_up, CmdAction.VolumeUp, Alignment.TopCenter),
            RingDirection(RemoteIcons.Minus, R.string.control_volume_down, CmdAction.VolumeDown, Alignment.BottomCenter),
            RingDirection(RemoteIcons.SeekBack, R.string.control_seek_back, CmdAction.SeekBackward, Alignment.CenterStart),
            RingDirection(RemoteIcons.SeekForward, R.string.control_seek_forward, CmdAction.SeekForward, Alignment.CenterEnd),
        )
        for (direction in directions) {
            IconRemoteButton(
                icon = direction.icon,
                label = stringResource(direction.label),
                onClick = { onCommand(direction.action) },
                enabled = enabled,
                modifier = Modifier.align(direction.alignment).padding(inset).size(zone),
                iconSize = 30.dp,
                containerColor = Color.Transparent,
                repeatOnHold = true,
            )
        }
        IconRemoteButton(
            icon = RemoteIcons.PlayPause,
            label = stringResource(R.string.control_play_pause),
            onClick = { onCommand(CmdAction.PlayPause) },
            enabled = enabled,
            modifier = Modifier.align(Alignment.Center).size(centre),
            iconSize = centre * 0.46f,
            containerColor = MaterialTheme.colorScheme.primary,
            contentColor = MaterialTheme.colorScheme.onPrimary,
        )
    }
}

private class RingDirection(
    val icon: ImageVector,
    @param:StringRes val label: Int,
    val action: CmdAction,
    val alignment: Alignment,
)

// --- Text entry ---

@Composable
private fun TextEntryDialog(onSend: (String) -> Unit, onKey: (KeyName) -> Unit, onDismiss: () -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    val focus = remember { FocusRequester() }

    fun send() {
        if (text.isNotEmpty()) {
            onSend(text)
            // Stay open: typing a search usually continues with Enter or more text.
            text = ""
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.text_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    modifier = Modifier.fillMaxWidth().focusRequester(focus),
                    label = { Text(stringResource(R.string.text_field_label)) },
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { send() }),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledTonalButton(onClick = { onKey(KeyName.Backspace) }, modifier = Modifier.weight(1f).heightIn(min = 48.dp)) {
                        Icon(RemoteIcons.Backspace, contentDescription = stringResource(R.string.control_backspace))
                    }
                    FilledTonalButton(onClick = { onKey(KeyName.Enter) }, modifier = Modifier.weight(1f).heightIn(min = 48.dp)) {
                        Text(stringResource(R.string.text_enter))
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = ::send, enabled = text.isNotEmpty()) { Text(stringResource(R.string.text_send)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.text_close)) } },
    )
    LaunchedEffect(Unit) { focus.requestFocus() }
}

// --- Feedback ---

private fun feedbackMessage(feedback: CommandFeedback, profileName: String, resources: Resources): String = when (feedback) {
    CommandFeedback.Unsupported -> resources.getString(R.string.feedback_unsupported, profileName)
    CommandFeedback.AccessibilityDenied -> resources.getString(R.string.feedback_accessibility)
    CommandFeedback.BadRequest -> resources.getString(R.string.feedback_bad_request)
    is CommandFeedback.Rejected -> resources.getString(R.string.feedback_rejected, feedback.error)
    CommandFeedback.Timeout -> resources.getString(R.string.feedback_timeout)
    CommandFeedback.NotConnected -> resources.getString(R.string.feedback_not_connected)
}
