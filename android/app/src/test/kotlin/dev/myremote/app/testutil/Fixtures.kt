package dev.myremote.app.testutil

import java.io.File
import java.math.BigDecimal
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.fail

/** The shared contract fixtures in `protocol/fixtures`, located through a property set by Gradle. */
object Fixtures {
    val dir: File by lazy {
        val path = System.getProperty("myremote.fixturesDir")
            ?: error("system property myremote.fixturesDir is not set; run the tests through Gradle")
        File(path).also { check(it.isDirectory) { "fixtures directory not found: $it" } }
    }

    /** All `*.json` files in a fixtures subdirectory, by file name. */
    fun messages(subdir: String): Map<String, String> {
        val files = File(dir, subdir).listFiles { f -> f.extension == "json" }?.sortedBy { it.name }.orEmpty()
        check(files.isNotEmpty()) { "no fixtures in ${File(dir, subdir)}" }
        return files.associate { it.name to it.readText(Charsets.UTF_8) }
    }

    fun read(path: String): String = File(dir, path).readText(Charsets.UTF_8)
}

object JsonSemantics {
    /** Fails unless both texts are the same JSON value, ignoring key order and number spelling (0 vs 0.0). */
    fun assertSameJson(context: String, expected: String, actual: String) {
        val e = Json.parseToJsonElement(expected)
        val a = Json.parseToJsonElement(actual)
        if (!same(e, a)) fail("$context: JSON differs\n expected: $e\n   actual: $a")
    }

    fun same(a: JsonElement, b: JsonElement): Boolean = when {
        a is JsonNull || b is JsonNull -> a is JsonNull && b is JsonNull
        a is JsonObject && b is JsonObject -> a.keys == b.keys && a.keys.all { same(a.getValue(it), b.getValue(it)) }
        a is JsonArray && b is JsonArray -> a.size == b.size && a.indices.all { same(a[it], b[it]) }
        a is JsonPrimitive && b is JsonPrimitive -> when {
            a.isString || b.isString -> a.isString && b.isString && a.content == b.content
            else -> {
                val x = a.content.toBigDecimalOrNull()
                val y = b.content.toBigDecimalOrNull()
                if (x != null && y != null) x.compareTo(y) == 0 else a.content == b.content
            }
        }
        else -> false
    }

    private fun String.toBigDecimalOrNull(): BigDecimal? = try {
        BigDecimal(this)
    } catch (_: NumberFormatException) {
        null
    }
}
