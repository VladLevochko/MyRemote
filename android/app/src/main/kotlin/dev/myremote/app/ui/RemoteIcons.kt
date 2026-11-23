package dev.myremote.app.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.dp

/**
 * The handful of glyphs the remote needs, as 24x24 vector paths. Kept in code so the app does not
 * pull in the full Material icon set for a dozen icons.
 */
object RemoteIcons {
    private fun icon(name: String, path: String): ImageVector =
        ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
            .addPath(pathData = addPathNodes(path), fill = SolidColor(Color.Black))
            .build()

    val PlayPause by lazy { icon("PlayPause", "M3,5v14l9,-7zM14,5h2.8v14H14zM18.2,5H21v14h-2.8z") }
    val SeekBack by lazy { icon("SeekBack", "M11,18V6l-8.5,6 8.5,6zM11.5,12l8.5,6V6l-8.5,6z") }
    val SeekForward by lazy { icon("SeekForward", "M4,18l8.5,-6L4,6v12zM13,6v12l8.5,-6L13,6z") }
    val Previous by lazy { icon("Previous", "M6,6h2v12H6zM9.5,12l8.5,6V6z") }
    val Next by lazy { icon("Next", "M6,18l8.5,-6L6,6v12zM16,6v12h2V6h-2z") }
    val Skip by lazy {
        icon("Skip", "M6.41,6L5,7.41 9.58,12 5,16.59 6.41,18l6,-6zM13,6l-1.41,1.41L16.17,12l-4.58,4.59L13,18l6,-6z")
    }
    val Mute by lazy {
        icon(
            "Mute",
            "M16.5,12c0,-1.77 -1.02,-3.29 -2.5,-4.03v2.21l2.45,2.45c0.03,-0.2 0.05,-0.41 0.05,-0.63z" +
                "M19,12c0,0.94 -0.2,1.82 -0.54,2.64l1.51,1.51C20.63,14.91 21,13.5 21,12c0,-4.28 -2.99,-7.86 -7,-8.77v2.06c2.89,0.86 5,3.54 5,6.71z" +
                "M4.27,3L3,4.27 7.73,9H3v6h4l5,5v-6.73l4.25,4.25c-0.67,0.52 -1.42,0.93 -2.25,1.18v2.06c1.38,-0.31 2.63,-0.95 3.69,-1.81L19.73,21 21,19.73l-9,-9L4.27,3z" +
                "M12,4L9.91,6.09 12,8.18V4z",
        )
    }
    val Subtitles by lazy {
        icon(
            "Subtitles",
            "M20,4H4c-1.1,0 -2,0.9 -2,2v12c0,1.1 0.9,2 2,2h16c1.1,0 2,-0.9 2,-2V6c0,-1.1 -0.9,-2 -2,-2z" +
                "M4,12h4v2H4v-2zM14,18H4v-2h10v2zM20,18h-4v-2h4v2zM20,14H10v-2h10v2z",
        )
    }
    val Fullscreen by lazy {
        icon("Fullscreen", "M7,14H5v5h5v-2H7v-3zM5,10h2V7h3V5H5v5zM17,17h-3v2h5v-5h-2v3zM14,5v2h3v3h2V5h-5z")
    }
    val Back by lazy { icon("Back", "M15.41,16.59L10.83,12l4.58,-4.59L14,6l-6,6 6,6z") }
    val Plus by lazy { icon("Plus", "M19,13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z") }
    val Minus by lazy { icon("Minus", "M19,13H5v-2h14v2z") }
    val Keyboard by lazy {
        icon(
            "Keyboard",
            "M20,5H4c-1.1,0 -1.99,0.9 -1.99,2L2,17c0,1.1 0.9,2 2,2h16c1.1,0 2,-0.9 2,-2V7c0,-1.1 -0.9,-2 -2,-2z" +
                "M11,8h2v2h-2V8zM11,11h2v2h-2v-2zM8,8h2v2H8V8zM8,11h2v2H8v-2zM7,13H5v-2h2v2zM7,10H5V8h2v2z" +
                "M16,17H8v-2h8v2zM16,13h-2v-2h2v2zM16,10h-2V8h2v2zM19,13h-2v-2h2v2zM19,10h-2V8h2v2z",
        )
    }
    val Backspace by lazy {
        icon(
            "Backspace",
            "M22,3H7c-0.69,0 -1.23,0.35 -1.59,0.88L0,12l5.41,8.11c0.36,0.53 0.9,0.89 1.59,0.89h15c1.1,0 2,-0.9 2,-2V5c0,-1.1 -0.9,-2 -2,-2z" +
                "M19,15.59L17.59,17 14,13.41 10.41,17 9,15.59 12.59,12 9,8.41 10.41,7 14,10.59 17.59,7 19,8.41 15.41,12 19,15.59z",
        )
    }
    val Warning by lazy { icon("Warning", "M1,21h22L12,2 1,21zM13,18h-2v-2h2v2zM13,14h-2v-4h2v4z") }
    val More by lazy {
        icon(
            "More",
            "M12,8c1.1,0 2,-0.9 2,-2s-0.9,-2 -2,-2 -2,0.9 -2,2 0.9,2 2,2zM12,10c-1.1,0 -2,0.9 -2,2s0.9,2 2,2 2,-0.9 2,-2 -0.9,-2 -2,-2z" +
                "M12,16c-1.1,0 -2,0.9 -2,2s0.9,2 2,2 2,-0.9 2,-2 -0.9,-2 -2,-2z",
        )
    }
    val QrCode by lazy {
        icon(
            "QrCode",
            "M3,3h8v8H3V3zM5,5v4h4V5H5zM13,3h8v8h-8V3zM15,5v4h4V5h-4zM3,13h8v8H3v-8zM5,15v4h4v-4H5z" +
                "M13,13h2v2h-2zM15,15h2v2h-2zM17,13h2v2h-2zM19,15h2v2h-2zM13,17h2v2h-2zM17,17h2v2h-2zM15,19h2v2h-2zM19,19h2v2h-2z",
        )
    }
}
