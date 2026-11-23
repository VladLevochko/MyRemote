package dev.myremote.app.core.pairing

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.Base64

/** Everything a pairing URI carries (PROTOCOL.md section 3). */
data class PairingInfo(
    val host: String,
    val port: Int,
    val id: String,
    val name: String,
    val fp: String,
    val token: String,
)

/** Why a pairing URI was rejected. Each case maps to its own user-facing message. */
sealed interface PairingError {
    /** Empty input, or text that is not a URI at all. */
    data object NotAUri : PairingError

    /** A URI, but not `myremote://`. */
    data class WrongScheme(val scheme: String) : PairingError

    /** `myremote://` but not `myremote://pair`. */
    data class WrongAction(val action: String) : PairingError

    data class MissingParameter(val name: String) : PairingError

    data class UnsupportedVersion(val version: String) : PairingError

    data object InvalidHost : PairingError

    data object InvalidPort : PairingError

    data object InvalidAgentId : PairingError

    data object InvalidName : PairingError

    data object InvalidFingerprint : PairingError

    data object InvalidToken : PairingError
}

sealed interface PairingResult {
    data class Success(val info: PairingInfo) : PairingResult

    data class Failure(val error: PairingError) : PairingResult
}

/**
 * Parses and validates
 * `myremote://pair?v=1&host=..&port=..&id=..&name=..&fp=..&token=..`.
 *
 * All parameters are required, order is free and unknown parameters are ignored.
 */
object PairingUriParser {
    const val SCHEME = "myremote"
    const val ACTION = "pair"
    const val SUPPORTED_VERSION = "1"

    private val SCHEME_REGEX = Regex("^([A-Za-z][A-Za-z0-9+.-]*):(.*)$", RegexOption.DOT_MATCHES_ALL)
    private val AGENT_ID_REGEX = Regex("^[0-9a-f]{16}$")
    private val FINGERPRINT_REGEX = Regex("^[0-9a-f]{64}$")
    private val TOKEN_REGEX = Regex("^[A-Za-z0-9_-]{43}$")
    private val HOST_LABEL_REGEX = Regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
    private val DOTTED_DIGITS_REGEX = Regex("^[0-9.]+$")
    private const val TOKEN_BYTES = 32
    private const val MAX_HOST_LENGTH = 253

    fun parse(input: String): PairingResult {
        val text = input.trim()
        val schemeMatch = SCHEME_REGEX.matchEntire(text) ?: return fail(PairingError.NotAUri)
        val scheme = schemeMatch.groupValues[1]
        val rest = schemeMatch.groupValues[2]
        if (text.any { it.isWhitespace() }) return fail(PairingError.NotAUri)
        if (!scheme.equals(SCHEME, ignoreCase = true)) return fail(PairingError.WrongScheme(scheme))
        if (!rest.startsWith("//")) return fail(PairingError.NotAUri)

        val afterSlashes = rest.substring(2).substringBefore('#')
        val action = afterSlashes.substringBefore('?').trimEnd('/')
        if (action != ACTION) return fail(PairingError.WrongAction(action))
        val query = afterSlashes.substringAfter('?', missingDelimiterValue = "")

        val params = HashMap<String, String?>()
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val key = percentDecode(pair.substringBefore('=')) ?: continue
            // First occurrence wins; a value that is not valid percent-encoded UTF-8 is kept as null
            // so the field is reported as invalid rather than missing.
            if (key !in params) params[key] = percentDecode(pair.substringAfter('=', ""))
        }

        fun has(name: String) = params.containsKey(name)

        if (!has("v")) return fail(PairingError.MissingParameter("v"))
        val version = params["v"]
        if (version != SUPPORTED_VERSION) return fail(PairingError.UnsupportedVersion(version.orEmpty()))

        for (name in listOf("host", "port", "id", "name", "fp", "token")) {
            if (!has(name)) return fail(PairingError.MissingParameter(name))
        }

        val host = params["host"]?.takeIf(::isValidHost) ?: return fail(PairingError.InvalidHost)
        val port = params["port"]
            ?.takeIf { it.length in 1..5 && it.all { c -> c in '0'..'9' } }
            ?.toInt()
            ?.takeIf { it in 1..65535 }
            ?: return fail(PairingError.InvalidPort)
        val id = params["id"]?.takeIf { AGENT_ID_REGEX.matches(it) } ?: return fail(PairingError.InvalidAgentId)
        val name = params["name"]?.takeIf { it.isNotBlank() } ?: return fail(PairingError.InvalidName)
        val fp = params["fp"]?.takeIf { FINGERPRINT_REGEX.matches(it) }
            ?: return fail(PairingError.InvalidFingerprint)
        val token = params["token"]?.takeIf(::isValidToken) ?: return fail(PairingError.InvalidToken)

        return PairingResult.Success(PairingInfo(host = host, port = port, id = id, name = name, fp = fp, token = token))
    }

    private fun fail(error: PairingError) = PairingResult.Failure(error)

    /** IPv4 literal or DNS hostname, as the contract allows. */
    private fun isValidHost(host: String): Boolean {
        if (host.isEmpty() || host.length > MAX_HOST_LENGTH) return false
        if (DOTTED_DIGITS_REGEX.matches(host)) {
            val octets = host.split('.')
            return octets.size == 4 && octets.all { it.length in 1..3 && it.toInt() <= 255 }
        }
        return host.trimEnd('.').split('.').all { HOST_LABEL_REGEX.matches(it) }
    }

    /** 32 bytes as unpadded base64url, which is always exactly 43 characters. */
    private fun isValidToken(token: String): Boolean {
        if (!TOKEN_REGEX.matches(token)) return false
        return try {
            Base64.getUrlDecoder().decode(token).size == TOKEN_BYTES
        } catch (_: IllegalArgumentException) {
            false
        }
    }

    /**
     * RFC 3986 percent-decoding as UTF-8. A literal `+` stays a plus sign, since this is a URI
     * query and not an HTML form body. Returns null for malformed escapes or invalid UTF-8.
     */
    private fun percentDecode(value: String): String? {
        if ('%' !in value) return value
        val bytes = ByteBuffer.allocate(value.toByteArray(Charsets.UTF_8).size)
        var i = 0
        while (i < value.length) {
            val c = value[i]
            if (c == '%') {
                if (i + 2 >= value.length) return null
                val hi = Character.digit(value[i + 1], 16)
                val lo = Character.digit(value[i + 2], 16)
                if (hi < 0 || lo < 0) return null
                bytes.put(((hi shl 4) or lo).toByte())
                i += 3
            } else {
                // Unescaped run: copy as UTF-8, taking care not to split a surrogate pair.
                val end = if (c.isHighSurrogate() && i + 1 < value.length) i + 2 else i + 1
                bytes.put(value.substring(i, end).toByteArray(Charsets.UTF_8))
                i = end
            }
        }
        bytes.flip()
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(bytes)
                .toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }
}
