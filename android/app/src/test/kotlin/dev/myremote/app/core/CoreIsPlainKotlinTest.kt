package dev.myremote.app.core

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Everything under `core` must stay plain Kotlin so it can be reasoned about and tested on the
 * JVM: protocol, pairing, client, trackpad maths and target resolution. Android-specific code
 * lives outside this package behind interfaces.
 */
class CoreIsPlainKotlinTest {
    @Test
    fun corePackageImportsNothingFromAndroid() {
        val dir = File(System.getProperty("myremote.coreSourceDir") ?: error("myremote.coreSourceDir is not set"))
        val sources = dir.walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue("expected core sources in $dir", sources.size >= 5)
        val offenders = sources.flatMap { file ->
            file.readLines()
                .filter { it.startsWith("import android.") || it.startsWith("import androidx.") }
                .map { "${file.name}: $it" }
        }
        assertEquals(emptyList<String>(), offenders)
    }
}
