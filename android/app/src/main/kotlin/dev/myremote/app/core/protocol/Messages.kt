package dev.myremote.app.core.protocol

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Protocol version this client speaks (PROTOCOL.md, "MyRemote protocol v1"). */
const val PROTOCOL_VERSION = 1

/** `cmd.action` values, PROTOCOL.md section 4.2. */
@Serializable
enum class CmdAction {
    @SerialName("playPause") PlayPause,
    @SerialName("seekBackward") SeekBackward,
    @SerialName("seekForward") SeekForward,
    @SerialName("volumeUp") VolumeUp,
    @SerialName("volumeDown") VolumeDown,
    @SerialName("toggleMute") ToggleMute,
    @SerialName("toggleFullscreen") ToggleFullscreen,
    @SerialName("nextItem") NextItem,
    @SerialName("previousItem") PreviousItem,
    @SerialName("skip") Skip,
    @SerialName("toggleSubtitles") ToggleSubtitles,
}

/** `key.key` values, PROTOCOL.md section 4.2. */
@Serializable
enum class KeyName {
    @SerialName("up") Up,
    @SerialName("down") Down,
    @SerialName("left") Left,
    @SerialName("right") Right,
    @SerialName("enter") Enter,
    @SerialName("escape") Escape,
    @SerialName("space") Space,
    @SerialName("tab") Tab,
    @SerialName("backspace") Backspace,
}

@Serializable
enum class MouseButton {
    @SerialName("left") Left,
    @SerialName("right") Right,
}

/** Client to server messages. The wire `type` is added by [ProtocolCodec]. */
sealed interface ClientMessage {
    @OptIn(ExperimentalSerializationApi::class)
    @Serializable
    data class Hello(
        // Has a default for convenience but must always be on the wire.
        @EncodeDefault(EncodeDefault.Mode.ALWAYS) val v: Int = PROTOCOL_VERSION,
        val token: String,
        val device: String,
    ) : ClientMessage

    @Serializable
    data class Cmd(val action: CmdAction, val id: Long? = null) : ClientMessage

    @Serializable
    data class Key(val key: KeyName, val id: Long? = null) : ClientMessage

    @Serializable
    data class Pointer(val dx: Double, val dy: Double) : ClientMessage

    @Serializable
    data class Click(val button: MouseButton, val count: Int) : ClientMessage {
        init {
            require(count == 1 || count == 2) { "click count must be 1 or 2, was $count" }
        }
    }

    @Serializable
    data class Scroll(val dx: Double, val dy: Double) : ClientMessage

    @Serializable
    data class Text(val text: String, val id: Long? = null) : ClientMessage

    @Serializable
    data class Ping(val t: Long) : ClientMessage
}

@Serializable
data class AgentInfo(val id: String, val name: String)

@Serializable
data class FrontApp(val bundleId: String, val name: String)

/**
 * Server state, PROTOCOL.md section 4.4.
 *
 * [profile] stays a string so that a profile added by a newer agent does not break decoding;
 * see [Profiles] for the values defined by protocol v1.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class RemoteState(
    // Always written, including as an explicit null, because the contract defines the field as nullable.
    @EncodeDefault(EncodeDefault.Mode.ALWAYS) val frontApp: FrontApp? = null,
    val profile: String,
    val accessibility: Boolean,
)

object Profiles {
    const val YOUTUBE = "youtube"
    const val NETFLIX = "netflix"
    const val APPLE_TV = "appletv"
    const val GENERIC = "generic"
}

/** `ack.error` values defined by protocol v1. */
object AckErrors {
    const val ACCESSIBILITY_DENIED = "accessibility_denied"
    const val UNSUPPORTED = "unsupported"
    const val BAD_REQUEST = "bad_request"
}

/** `error.code` values defined by protocol v1. */
object ErrorCodes {
    const val UNAUTHORIZED = "unauthorized"
    const val UNSUPPORTED_VERSION = "unsupported_version"
    const val BAD_REQUEST = "bad_request"
}

/** WebSocket close codes the agent uses after a failed handshake. */
object CloseCodes {
    const val UNSUPPORTED_VERSION = 4400
    const val UNAUTHORIZED = 4401
}

/** Server to client messages. */
sealed interface ServerMessage {
    @Serializable
    data class Welcome(val v: Int, val agent: AgentInfo, val state: RemoteState) : ServerMessage

    @Serializable
    data class Ack(val id: Long, val ok: Boolean, val error: String? = null) : ServerMessage

    @Serializable
    data class State(val state: RemoteState) : ServerMessage

    @Serializable
    data class Pong(val t: Long) : ServerMessage

    @Serializable
    data class Error(val code: String, val message: String = "") : ServerMessage

    /** A `type` this client does not know. The contract says to ignore it silently. */
    data class Unknown(val type: String) : ServerMessage
}
