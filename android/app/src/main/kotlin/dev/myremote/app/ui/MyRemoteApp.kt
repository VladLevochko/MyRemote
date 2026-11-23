package dev.myremote.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.myremote.app.PairingState
import dev.myremote.app.RemoteViewModel

@Composable
fun MyRemoteApp(viewModel: RemoteViewModel) {
    val pairing by viewModel.pairing.collectAsStateWithLifecycle()
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        when (val state = pairing) {
            // Reading the stored pairing takes a few milliseconds; an empty dark screen avoids a flash.
            PairingState.Loading -> Unit
            PairingState.Unpaired -> PairingScreen(onPair = viewModel::pair)
            is PairingState.Paired -> {
                val connection by viewModel.connection.collectAsStateWithLifecycle()
                RemoteScreen(
                    pairing = state.info,
                    connection = connection,
                    feedback = viewModel.feedback,
                    onCommand = viewModel::command,
                    onKey = viewModel::key,
                    onText = viewModel::text,
                    onTrackpad = viewModel::trackpad,
                    onRetry = viewModel::retry,
                    onForget = viewModel::forget,
                )
            }
        }
    }
}
