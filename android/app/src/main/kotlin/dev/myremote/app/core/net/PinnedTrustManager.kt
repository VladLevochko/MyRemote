package dev.myremote.app.core.net

import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedTrustManager

object Fingerprints {
    private const val HEX = "0123456789abcdef"

    /** SHA-256 of [der] as 64 lowercase hex characters: the `fp` of PROTOCOL.md section 1. */
    fun sha256Hex(der: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(der)
        val out = StringBuilder(digest.size * 2)
        for (b in digest) {
            out.append(HEX[(b.toInt() shr 4) and 0xF]).append(HEX[b.toInt() and 0xF])
        }
        return out.toString()
    }

    fun of(certificate: X509Certificate): String = sha256Hex(certificate.encoded)
}

class PinMismatchException(val expected: String, val actual: String) :
    CertificateException("server certificate fingerprint $actual does not match the paired fingerprint")

/**
 * Trusts exactly one server leaf certificate, identified by its SHA-256 fingerprint, and nothing
 * else. The chain, validity dates and hostname are deliberately not checked: the agent's
 * certificate is self-signed and the fingerprint from the pairing QR code is the only authority
 * (PROTOCOL.md section 1).
 *
 * Extending [X509ExtendedTrustManager] keeps the platform from layering its own endpoint
 * identification on top.
 *
 * One instance is used per connection attempt so [rejectedFingerprint] can be read afterwards to
 * tell a pin mismatch from any other TLS failure.
 */
class PinnedTrustManager(expectedFingerprint: String) : X509ExtendedTrustManager() {
    private val expected = expectedFingerprint.lowercase()

    @Volatile
    var rejectedFingerprint: String? = null
        private set

    private fun verify(chain: Array<out X509Certificate>?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("server sent no certificate")
        val actual = Fingerprints.of(leaf)
        if (!MessageDigest.isEqual(actual.toByteArray(Charsets.US_ASCII), expected.toByteArray(Charsets.US_ASCII))) {
            rejectedFingerprint = actual
            throw PinMismatchException(expected, actual)
        }
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = verify(chain)

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        verify(chain)

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        verify(chain)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?): Unit =
        throw CertificateException("client certificates are not supported")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?): Unit =
        throw CertificateException("client certificates are not supported")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?): Unit =
        throw CertificateException("client certificates are not supported")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    fun newSslContext(): SSLContext =
        SSLContext.getInstance("TLS").apply { init(null, arrayOf(this@PinnedTrustManager), null) }
}
