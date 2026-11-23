package dev.myremote.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** The remote is used in a dim living room next to a TV, so there is only a dark theme. */
private val RemoteColors = darkColorScheme(
    primary = Color(0xFF7FB0FF),
    onPrimary = Color(0xFF06223F),
    primaryContainer = Color(0xFF1B3A60),
    onPrimaryContainer = Color(0xFFD6E6FF),
    secondary = Color(0xFFB7C4D8),
    onSecondary = Color(0xFF16202C),
    secondaryContainer = Color(0xFF2A303A),
    onSecondaryContainer = Color(0xFFE6E9EE),
    background = Color(0xFF0B0D10),
    onBackground = Color(0xFFE6E9EE),
    surface = Color(0xFF0B0D10),
    onSurface = Color(0xFFE6E9EE),
    surfaceVariant = Color(0xFF1A1E24),
    onSurfaceVariant = Color(0xFFA9B1BD),
    surfaceContainerLowest = Color(0xFF0B0D10),
    surfaceContainerLow = Color(0xFF12151A),
    surfaceContainer = Color(0xFF171B21),
    surfaceContainerHigh = Color(0xFF20252D),
    surfaceContainerHighest = Color(0xFF2A303A),
    outline = Color(0xFF4A525E),
    outlineVariant = Color(0xFF2A303A),
    error = Color(0xFFFF8A80),
    onError = Color(0xFF3B0A06),
    errorContainer = Color(0xFF4A1612),
    onErrorContainer = Color(0xFFFFDAD5),
    tertiary = Color(0xFFFFC46B),
    onTertiary = Color(0xFF3A2600),
    tertiaryContainer = Color(0xFF3F2E0C),
    onTertiaryContainer = Color(0xFFFFE2B3),
    inverseSurface = Color(0xFFE6E9EE),
    inverseOnSurface = Color(0xFF16191E),
)

object StatusColors {
    val connected = Color(0xFF5BD68A)
    val busy = Color(0xFFFFC46B)
    val failed = Color(0xFFFF8A80)
    val idle = Color(0xFF6B7380)
}

@Composable
fun MyRemoteTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = RemoteColors, content = content)
}
