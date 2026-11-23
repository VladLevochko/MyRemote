package dev.myremote.app

import android.graphics.Color
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import dev.myremote.app.core.protocol.CmdAction
import dev.myremote.app.ui.MyRemoteApp
import dev.myremote.app.ui.theme.MyRemoteTheme

class MainActivity : ComponentActivity() {
    private val viewModel: RemoteViewModel by viewModels()
    private var lastVolumeRepeatMs = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        setContent {
            MyRemoteTheme {
                MyRemoteApp(viewModel)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        viewModel.onForeground()
    }

    override fun onStop() {
        viewModel.onBackground()
        super.onStop()
    }

    /**
     * While the remote is on screen the hardware volume buttons control the Mac instead of the
     * phone. Both down and up are consumed so the system volume panel does not appear.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val action = volumeAction(keyCode) ?: return super.onKeyDown(keyCode, event)
        // Holding the button repeats about every 50 ms, which is faster than a volume step
        // should be: let one repeat through per interval.
        val isRepeat = event.repeatCount > 0
        if (!isRepeat || event.eventTime - lastVolumeRepeatMs >= VOLUME_REPEAT_INTERVAL_MS) {
            lastVolumeRepeatMs = event.eventTime
            viewModel.command(action)
        }
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean =
        if (volumeAction(keyCode) != null) true else super.onKeyUp(keyCode, event)

    private fun volumeAction(keyCode: Int): CmdAction? {
        if (!viewModel.isRemoteActive) return null
        return when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> CmdAction.VolumeUp
            KeyEvent.KEYCODE_VOLUME_DOWN -> CmdAction.VolumeDown
            else -> null
        }
    }

    private companion object {
        const val VOLUME_REPEAT_INTERVAL_MS = 120L
    }
}
