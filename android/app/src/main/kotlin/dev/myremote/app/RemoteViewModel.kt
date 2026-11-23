package dev.myremote.app

import android.app.Application
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.myremote.app.core.discovery.Endpoint
import dev.myremote.app.core.discovery.ReconnectTargetResolver
import dev.myremote.app.core.net.ClientIdentity
import dev.myremote.app.core.net.CommandResult
import dev.myremote.app.core.net.ConnectionState
import dev.myremote.app.core.net.RemoteClient
import dev.myremote.app.core.pairing.PairingError
import dev.myremote.app.core.pairing.PairingInfo
import dev.myremote.app.core.pairing.PairingResult
import dev.myremote.app.core.pairing.PairingUriParser
import dev.myremote.app.core.protocol.AckErrors
import dev.myremote.app.core.protocol.CmdAction
import dev.myremote.app.core.protocol.KeyName
import dev.myremote.app.core.trackpad.TrackpadAction
import dev.myremote.app.data.PairingStore
import dev.myremote.app.discovery.NsdAgentDiscovery
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus

/** Which screen to show. */
sealed interface PairingState {
    /** The stored pairing has not been read yet. */
    data object Loading : PairingState

    data object Unpaired : PairingState

    data class Paired(val info: PairingInfo) : PairingState
}

/** Short-lived feedback about a command, shown as a snackbar. */
sealed interface CommandFeedback {
    /** The current profile has no equivalent for the action; the trackpad is the fallback. */
    data object Unsupported : CommandFeedback

    data object AccessibilityDenied : CommandFeedback

    data object BadRequest : CommandFeedback

    data class Rejected(val error: String) : CommandFeedback

    data object Timeout : CommandFeedback

    data object NotConnected : CommandFeedback
}

class RemoteViewModel(application: Application) : AndroidViewModel(application) {
    private val store = PairingStore(application)
    private val discovery = NsdAgentDiscovery(application)
    private val httpClient = RemoteClient.defaultHttpClient()

    private val _pairing = MutableStateFlow<PairingState>(PairingState.Loading)
    val pairing: StateFlow<PairingState> = _pairing.asStateFlow()

    private val _connection = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connection: StateFlow<ConnectionState> = _connection.asStateFlow()

    private val _feedback = Channel<CommandFeedback>(capacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val feedback: Flow<CommandFeedback> = _feedback.receiveAsFlow()

    private var client: RemoteClient? = null
    private var clientScope: CoroutineScope? = null
    private var foreground = false

    /** Read by the reconnect resolver when mDNS finds nothing. */
    @Volatile
    private var lastKnown: Endpoint? = null

    /** True while the remote screen is what the user sees, i.e. a Mac is paired. */
    val isRemoteActive: Boolean get() = _pairing.value is PairingState.Paired

    init {
        viewModelScope.launch {
            val stored = store.pairing.first()
            // A pairing made while the store was still loading wins.
            if (_pairing.value == PairingState.Loading) {
                if (stored == null) _pairing.value = PairingState.Unpaired else activate(stored, justPaired = false)
            }
        }
    }

    /**
     * Validates a scanned or pasted pairing URI and, if it is good, stores it and starts connecting.
     *
     * @return null on success, otherwise why the URI was rejected.
     */
    fun pair(uri: String): PairingError? = when (val result = PairingUriParser.parse(uri)) {
        is PairingResult.Failure -> result.error
        is PairingResult.Success -> {
            viewModelScope.launch { store.save(result.info) }
            activate(result.info, justPaired = true)
            null
        }
    }

    fun forget() {
        deactivate()
        _pairing.value = PairingState.Unpaired
        viewModelScope.launch { store.clear() }
    }

    /** The activity became visible: connect. */
    fun onForeground() {
        foreground = true
        client?.connect()
    }

    /** The activity is no longer visible: a remote nobody is looking at should not hold a connection. */
    fun onBackground() {
        foreground = false
        client?.disconnect()
    }

    /** Starts over after a failure the client does not retry on its own. */
    fun retry() {
        client?.let {
            it.disconnect()
            if (foreground) it.connect()
        }
    }

    fun command(action: CmdAction) = request { it.command(action) }

    fun key(key: KeyName) = request { it.key(key) }

    fun text(text: String) {
        if (text.isNotEmpty()) request { it.text(text) }
    }

    fun trackpad(action: TrackpadAction) {
        val client = client ?: return
        when (action) {
            is TrackpadAction.Move -> client.pointer(action.dx, action.dy)
            is TrackpadAction.Scroll -> client.scroll(action.dx, action.dy)
            is TrackpadAction.Click -> client.click(action.button, action.count)
        }
    }

    private fun request(send: suspend (RemoteClient) -> CommandResult) {
        val client = client ?: return
        viewModelScope.launch {
            val feedback = when (val result = send(client)) {
                CommandResult.Ok -> null
                CommandResult.Timeout -> CommandFeedback.Timeout
                CommandResult.NotConnected -> CommandFeedback.NotConnected
                is CommandResult.Rejected -> when (result.error) {
                    AckErrors.UNSUPPORTED -> CommandFeedback.Unsupported
                    AckErrors.ACCESSIBILITY_DENIED -> CommandFeedback.AccessibilityDenied
                    AckErrors.BAD_REQUEST -> CommandFeedback.BadRequest
                    else -> CommandFeedback.Rejected(result.error)
                }
            }
            if (feedback != null) _feedback.trySend(feedback)
        }
    }

    private fun activate(info: PairingInfo, justPaired: Boolean) {
        deactivate()
        lastKnown = Endpoint(info.host, info.port)
        val scope = viewModelScope + SupervisorJob(viewModelScope.coroutineContext[Job])
        val newClient = RemoteClient(
            identity = ClientIdentity(fingerprint = info.fp, token = info.token, deviceName = deviceName()),
            resolver = ReconnectTargetResolver(
                agentId = info.id,
                discovery = discovery,
                lastKnown = { lastKnown ?: Endpoint(info.host, info.port) },
                // Straight after pairing the URI's host:port is as fresh as it gets.
                directFirst = justPaired,
            ),
            scope = scope,
            httpClient = httpClient,
        )
        scope.launch {
            newClient.state.collect { state ->
                _connection.value = state
                if (state is ConnectionState.Connected && state.endpoint != lastKnown) {
                    // Found somewhere new over mDNS: this is now the fallback address.
                    lastKnown = state.endpoint
                    store.updateEndpoint(info.id, state.endpoint.host, state.endpoint.port)
                }
            }
        }
        client = newClient
        clientScope = scope
        _pairing.value = PairingState.Paired(info)
        if (foreground) newClient.connect()
    }

    private fun deactivate() {
        client?.disconnect()
        clientScope?.cancel()
        client = null
        clientScope = null
        _connection.value = ConnectionState.Disconnected
    }

    private fun deviceName(): String {
        val app = getApplication<Application>()
        val userChosen = runCatching { Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
        return userChosen?.takeIf { it.isNotBlank() } ?: "${Build.MANUFACTURER} ${Build.MODEL}".trim()
    }

    override fun onCleared() {
        deactivate()
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
    }
}
