package dev.myremote.app.core.net

import java.security.MessageDigest
import java.security.cert.CertificateException
import okhttp3.tls.HeldCertificate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class PinnedTrustManagerTest {
    private val pinned = HeldCertificate.Builder().commonName("agent").build()
    private val other = HeldCertificate.Builder().commonName("agent").build()

    @Test
    fun fingerprintIsLowercaseHexSha256OfTheDerEncoding() {
        val expected = MessageDigest.getInstance("SHA-256").digest(pinned.certificate.encoded)
            .joinToString("") { "%02x".format(it) }
        assertEquals(expected, Fingerprints.of(pinned.certificate))
        assertEquals(64, expected.length)
        // Known vector: SHA-256 of the empty input.
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", Fingerprints.sha256Hex(ByteArray(0)))
    }

    @Test
    fun acceptsExactlyThePinnedLeaf() {
        val trust = PinnedTrustManager(Fingerprints.of(pinned.certificate))
        trust.checkServerTrusted(arrayOf(pinned.certificate), "ECDHE_ECDSA")
        assertNull(trust.rejectedFingerprint)
    }

    @Test
    fun rejectsAnyOtherCertificateAndRecordsItsFingerprint() {
        val trust = PinnedTrustManager(Fingerprints.of(pinned.certificate))
        val e = assertThrows(PinMismatchException::class.java) {
            trust.checkServerTrusted(arrayOf(other.certificate), "ECDHE_ECDSA")
        }
        assertEquals(Fingerprints.of(other.certificate), e.actual)
        assertEquals(Fingerprints.of(other.certificate), trust.rejectedFingerprint)
    }

    @Test
    fun thePinAppliesToTheLeafNotToAnIssuerInTheChain() {
        // The pinned certificate signing some other leaf must not make that leaf acceptable.
        val ca = HeldCertificate.Builder().commonName("ca").certificateAuthority(0).build()
        val leaf = HeldCertificate.Builder().commonName("leaf").signedBy(ca).build()
        val trust = PinnedTrustManager(Fingerprints.of(ca.certificate))
        assertThrows(PinMismatchException::class.java) {
            trust.checkServerTrusted(arrayOf(leaf.certificate, ca.certificate), "ECDHE_ECDSA")
        }
    }

    @Test
    fun rejectsAnEmptyChainAndClientAuthentication() {
        val trust = PinnedTrustManager(Fingerprints.of(pinned.certificate))
        assertThrows(CertificateException::class.java) { trust.checkServerTrusted(emptyArray(), "ECDHE_ECDSA") }
        assertThrows(CertificateException::class.java) { trust.checkServerTrusted(null, "ECDHE_ECDSA") }
        assertThrows(CertificateException::class.java) { trust.checkClientTrusted(arrayOf(pinned.certificate), "ECDHE_ECDSA") }
        assertEquals(0, trust.acceptedIssuers.size)
    }

    @Test
    fun backoffFollowsTheContractSequence() {
        val backoff = Backoff()
        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 8_000L, 15_000L, 15_000L, 15_000L),
            (0..6).map(backoff::delayMs),
        )
        assertEquals(15_000L, backoff.delayMs(1_000))
    }
}
