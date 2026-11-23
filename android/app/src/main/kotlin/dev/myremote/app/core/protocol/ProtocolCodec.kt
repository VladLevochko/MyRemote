package dev.myremote.app.core.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

class ProtocolException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Encodes and decodes protocol messages as single JSON objects with a string `type` field.
 *
 * Unknown fields are ignored in both directions. An unknown server `type` decodes to
 * [ServerMessage.Unknown] rather than failing, so callers can skip it.
 */
object ProtocolCodec {
    private const val TYPE = "type"

    private val json = Json {
        ignoreUnknownKeys = true
        // Optional fields (`id`, `error`) are omitted when absent instead of written as null.
        encodeDefaults = false
    }

    private class Entry<T : Any>(val type: String, val klass: Class<T>, val serializer: KSerializer<T>) {
        fun encode(value: Any): JsonObject =
            json.encodeToJsonElement(serializer, klass.cast(value)!!).jsonObject

        fun decode(obj: JsonObject): T = json.decodeFromJsonElement(serializer, obj)
    }

    private inline fun <reified T : Any> entry(type: String, serializer: KSerializer<T>) =
        Entry(type, T::class.java, serializer)

    private val clientEntries: List<Entry<out ClientMessage>> = listOf(
        entry("hello", ClientMessage.Hello.serializer()),
        entry("cmd", ClientMessage.Cmd.serializer()),
        entry("key", ClientMessage.Key.serializer()),
        entry("pointer", ClientMessage.Pointer.serializer()),
        entry("click", ClientMessage.Click.serializer()),
        entry("scroll", ClientMessage.Scroll.serializer()),
        entry("text", ClientMessage.Text.serializer()),
        entry("ping", ClientMessage.Ping.serializer()),
    )

    private val serverEntries: List<Entry<out ServerMessage>> = listOf(
        entry("welcome", ServerMessage.Welcome.serializer()),
        entry("ack", ServerMessage.Ack.serializer()),
        entry("state", ServerMessage.State.serializer()),
        entry("pong", ServerMessage.Pong.serializer()),
        entry("error", ServerMessage.Error.serializer()),
    )

    fun encode(message: ClientMessage): String = encode(clientEntries, message)

    /** Encoding server messages is only needed by tests and fake agents. */
    fun encode(message: ServerMessage): String {
        require(message !is ServerMessage.Unknown) { "cannot encode an unknown message" }
        return encode(serverEntries, message)
    }

    /** @throws ProtocolException if [text] is not a known, well-formed client message. */
    fun decodeClient(text: String): ClientMessage {
        val (type, obj) = split(text)
        val entry = clientEntries.firstOrNull { it.type == type }
            ?: throw ProtocolException("unknown client message type '$type'")
        return decode(entry, obj)
    }

    /**
     * @return the typed message, or [ServerMessage.Unknown] for a `type` this client does not know.
     * @throws ProtocolException if [text] is not a JSON object with a string `type`, or if a known
     *   message is missing required fields.
     */
    fun decodeServer(text: String): ServerMessage {
        val (type, obj) = split(text)
        val entry = serverEntries.firstOrNull { it.type == type } ?: return ServerMessage.Unknown(type)
        return decode(entry, obj)
    }

    private fun encode(entries: List<Entry<*>>, message: Any): String {
        val entry = entries.first { it.klass.isInstance(message) }
        val body = entry.encode(message)
        return JsonObject(mapOf(TYPE to JsonPrimitive(entry.type)) + body).toString()
    }

    private fun <T : Any> decode(entry: Entry<T>, obj: JsonObject): T = try {
        entry.decode(obj)
    } catch (e: SerializationException) {
        throw ProtocolException("malformed '${entry.type}' message: ${e.message}", e)
    } catch (e: IllegalArgumentException) {
        throw ProtocolException("invalid '${entry.type}' message: ${e.message}", e)
    }

    private fun split(text: String): Pair<String, JsonObject> {
        val element = try {
            json.parseToJsonElement(text)
        } catch (e: SerializationException) {
            throw ProtocolException("not valid JSON", e)
        }
        val obj = element as? JsonObject ?: throw ProtocolException("message is not a JSON object")
        val type = (obj[TYPE] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: throw ProtocolException("message has no string 'type'")
        return type to obj
    }
}
