package dev.myremote.app.core.pairing

import dev.myremote.app.testutil.Fixtures
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingUriParserTest {
    @Serializable
    private data class Expect(val host: String, val port: Int, val id: String, val name: String, val fp: String, val token: String)

    @Serializable
    private data class ValidCase(val uri: String, val expect: Expect)

    @Serializable
    private data class InvalidCase(val uri: String, val reason: String)

    @Serializable
    private data class Cases(val valid: List<ValidCase>, val invalid: List<InvalidCase>)

    private val cases = Json.decodeFromString(Cases.serializer(), Fixtures.read("pairing/cases.json"))

    private val fp = "3b7f0c1d9a2e4f5061728394a5b6c7d8e9f00112233445566778899aabbccdde"
    private val token = "q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA"

    private fun uri(
        v: String? = "1",
        host: String? = "192.168.1.42",
        port: String? = "47110",
        id: String? = "0123456789abcdef",
        name: String? = "Mac",
        fp: String? = this.fp,
        token: String? = this.token,
    ): String = "myremote://pair?" + listOfNotNull(
        v?.let { "v=$it" }, host?.let { "host=$it" }, port?.let { "port=$it" }, id?.let { "id=$it" },
        name?.let { "name=$it" }, fp?.let { "fp=$it" }, token?.let { "token=$it" },
    ).joinToString("&")

    private fun errorOf(input: String): PairingError = when (val result = PairingUriParser.parse(input)) {
        is PairingResult.Failure -> result.error
        is PairingResult.Success -> throw AssertionError("expected a failure for $input but got ${result.info}")
    }

    private fun infoOf(input: String): PairingInfo = when (val result = PairingUriParser.parse(input)) {
        is PairingResult.Success -> result.info
        is PairingResult.Failure -> throw AssertionError("expected success for $input but got ${result.error}")
    }

    @Test
    fun acceptsEveryValidFixtureWithTheExpectedFields() {
        assertTrue(cases.valid.isNotEmpty())
        for (case in cases.valid) {
            val e = case.expect
            assertEquals(case.uri, PairingInfo(e.host, e.port, e.id, e.name, e.fp, e.token), infoOf(case.uri))
        }
    }

    @Test
    fun rejectsEveryInvalidFixtureWithTheMatchingReason() {
        assertTrue(cases.invalid.isNotEmpty())
        for (case in cases.invalid) {
            val error = errorOf(case.uri)
            val matches = when (case.reason) {
                "unsupported version" -> error == PairingError.UnsupportedVersion("2")
                "missing fp" -> error == PairingError.MissingParameter("fp")
                "fp is not 64 hex chars" -> error == PairingError.InvalidFingerprint
                "port out of range" -> error == PairingError.InvalidPort
                "token is not 32 bytes of base64url" -> error == PairingError.InvalidToken
                "wrong scheme" -> error == PairingError.WrongScheme("https")
                "wrong action" -> error == PairingError.WrongAction("other")
                "garbage" -> error == PairingError.NotAUri
                // A reason added to the fixtures later only has to be rejected.
                else -> true
            }
            assertTrue("'${case.reason}' was rejected as $error", matches)
        }
    }

    @Test
    fun everyParameterIsRequired() {
        assertEquals(PairingError.MissingParameter("v"), errorOf(uri(v = null)))
        assertEquals(PairingError.MissingParameter("host"), errorOf(uri(host = null)))
        assertEquals(PairingError.MissingParameter("port"), errorOf(uri(port = null)))
        assertEquals(PairingError.MissingParameter("id"), errorOf(uri(id = null)))
        assertEquals(PairingError.MissingParameter("name"), errorOf(uri(name = null)))
        assertEquals(PairingError.MissingParameter("fp"), errorOf(uri(fp = null)))
        assertEquals(PairingError.MissingParameter("token"), errorOf(uri(token = null)))
        assertEquals(PairingError.MissingParameter("v"), errorOf("myremote://pair"))
    }

    @Test
    fun versionIsCheckedBeforeEverythingElse() {
        // A v2 URI may have a different shape; the user should be told about the version, not about fields.
        assertEquals(PairingError.UnsupportedVersion("2"), errorOf("myremote://pair?v=2&somethingNew=1"))
        assertEquals(PairingError.UnsupportedVersion(""), errorOf(uri(v = "")))
        assertEquals(PairingError.UnsupportedVersion("01"), errorOf(uri(v = "01")))
    }

    @Test
    fun validatesHost() {
        for (bad in listOf("", "256.1.1.1", "1.2.3", "1.2.3.4.5", "ex%20ample.com", "-bad.local", "a..b", "%5B%3A%3A1%5D", "host%2Fpath")) {
            assertEquals("host=$bad", PairingError.InvalidHost, errorOf(uri(host = bad)))
        }
        for (good in listOf("10.0.2.2", "127.0.0.1", "macbook.local", "Vlads-MacBook-Pro.local", "mac")) {
            assertEquals(good, infoOf(uri(host = good)).host)
        }
    }

    @Test
    fun validatesPort() {
        for (bad in listOf("", "0", "65536", "99999", "-1", "47110x", "4.7", "123456")) {
            assertEquals("port=$bad", PairingError.InvalidPort, errorOf(uri(port = bad)))
        }
        assertEquals(1, infoOf(uri(port = "1")).port)
        assertEquals(65535, infoOf(uri(port = "65535")).port)
    }

    @Test
    fun validatesAgentIdFingerprintAndToken() {
        for (bad in listOf("", "0123456789abcde", "0123456789abcdef0", "0123456789ABCDEF", "0123456789abcdeg")) {
            assertEquals("id=$bad", PairingError.InvalidAgentId, errorOf(uri(id = bad)))
        }
        for (bad in listOf("", fp.dropLast(1), fp + "0", fp.uppercase(), fp.replaceFirst('3', 'x'))) {
            assertEquals("fp=$bad", PairingError.InvalidFingerprint, errorOf(uri(fp = bad)))
        }
        for (bad in listOf("", "short", token.dropLast(1), token + "A", token + "=", token.replaceFirst('q', '+'), token.replaceFirst('q', '/'))) {
            assertEquals("token=$bad", PairingError.InvalidToken, errorOf(uri(token = bad)))
        }
    }

    @Test
    fun decodesNameAsPercentEncodedUtf8() {
        assertEquals("Мій Mac", infoOf(uri(name = "%D0%9C%D1%96%D0%B9%20Mac")).name)
        assertEquals("Мій Mac", infoOf(uri(name = "Мій%20Mac")).name)
        assertEquals("C++ box & co", infoOf(uri(name = "C++%20box%20%26%20co")).name)
        assertEquals("a=b", infoOf(uri(name = "a=b")).name)
        for (bad in listOf("", "%20", "%", "%2", "%zz", "%FF")) {
            assertEquals("name=$bad", PairingError.InvalidName, errorOf(uri(name = bad)))
        }
    }

    @Test
    fun toleratesSurroundingWhitespaceUnknownParametersAndSchemeCase() {
        val expected = infoOf(uri())
        assertEquals(expected, infoOf("  \n${uri()}\n "))
        assertEquals(expected, infoOf(uri() + "&future=1&flag"))
        assertEquals(expected, infoOf(uri().replace("myremote://", "MyRemote://")))
    }

    @Test
    fun distinguishesGarbageSchemeAndAction() {
        for (garbage in listOf("", "   ", "not a uri at all", "hello", "myremote:pair?v=1", "my remote://pair?v=1")) {
            assertEquals("'$garbage'", PairingError.NotAUri, errorOf(garbage))
        }
        assertEquals(PairingError.WrongScheme("https"), errorOf("https://example.com/pair?v=1"))
        assertEquals(PairingError.WrongScheme("otherapp"), errorOf("otherapp://pair?v=1"))
        assertEquals(PairingError.WrongAction("other"), errorOf("myremote://other?v=1"))
        assertEquals(PairingError.WrongAction(""), errorOf("myremote://?v=1"))
        assertEquals(PairingError.WrongAction("pair/extra"), errorOf("myremote://pair/extra?v=1"))
    }
}
