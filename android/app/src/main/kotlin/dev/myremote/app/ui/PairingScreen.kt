package dev.myremote.app.ui

import android.content.Context
import android.content.res.Resources
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import dev.myremote.app.R
import dev.myremote.app.core.pairing.PairingError

/**
 * First-run screen: scan the agent's QR code, or paste the pairing link by hand.
 *
 * @param onPair validates and stores the URI; returns null on success or the reason it was rejected.
 */
@Composable
fun PairingScreen(onPair: (String) -> PairingError?) {
    val context = LocalContext.current
    val resources = LocalResources.current
    var link by rememberSaveable { mutableStateOf("") }
    var error by rememberSaveable { mutableStateOf<String?>(null) }

    fun submit(uri: String) {
        error = onPair(uri)?.let { describe(resources, it) }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            text = stringResource(R.string.pairing_title),
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
            text = stringResource(R.string.pairing_body),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Button(
            onClick = {
                error = null
                scanQrCode(
                    context = context,
                    onScanned = ::submit,
                    onUnavailable = { error = resources.getString(R.string.pairing_scanner_unavailable) },
                )
            },
            modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp),
        ) {
            Icon(RemoteIcons.QrCode, contentDescription = null, modifier = Modifier.size(24.dp))
            Spacer(Modifier.width(12.dp))
            Text(stringResource(R.string.pairing_scan), style = MaterialTheme.typography.titleMedium)
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            HorizontalDivider(Modifier.weight(1f))
            Text(
                stringResource(R.string.pairing_or),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            HorizontalDivider(Modifier.weight(1f))
        }

        OutlinedTextField(
            value = link,
            onValueChange = {
                link = it
                error = null
            },
            modifier = Modifier.fillMaxWidth(),
            label = { Text(stringResource(R.string.pairing_link_label)) },
            placeholder = { Text(stringResource(R.string.pairing_link_placeholder)) },
            textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            isError = error != null,
            minLines = 3,
            maxLines = 6,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { submit(link) }),
        )

        error?.let { message ->
            Text(
                text = message,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
            )
        }

        FilledTonalButton(
            onClick = { submit(link) },
            enabled = link.isNotBlank(),
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
        ) {
            Text(stringResource(R.string.pairing_connect), style = MaterialTheme.typography.titleMedium)
        }
        Spacer(Modifier.height(8.dp))
    }
}

/**
 * Opens Google's code scanner. It runs inside Google Play services, so this app needs no camera
 * permission; the price is that it is unavailable on devices without Play services or before the
 * scanner module has been downloaded.
 */
private fun scanQrCode(context: Context, onScanned: (String) -> Unit, onUnavailable: () -> Unit) {
    val options = GmsBarcodeScannerOptions.Builder()
        .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
        .build()
    try {
        GmsBarcodeScanning.getClient(context, options)
            .startScan()
            .addOnSuccessListener { barcode -> onScanned(barcode.rawValue.orEmpty()) }
            .addOnFailureListener { onUnavailable() }
        // Cancelling (back button) needs no reaction.
    } catch (_: RuntimeException) {
        onUnavailable()
    }
}

/** One specific message per rejection reason. */
private fun describe(resources: Resources, error: PairingError): String = when (error) {
    PairingError.NotAUri -> resources.getString(R.string.pairing_error_not_a_uri)
    is PairingError.WrongScheme -> resources.getString(R.string.pairing_error_wrong_scheme, error.scheme)
    is PairingError.WrongAction -> resources.getString(R.string.pairing_error_wrong_action)
    is PairingError.MissingParameter -> resources.getString(R.string.pairing_error_missing, error.name)
    is PairingError.UnsupportedVersion -> resources.getString(R.string.pairing_error_version, error.version)
    PairingError.InvalidHost -> resources.getString(R.string.pairing_error_host)
    PairingError.InvalidPort -> resources.getString(R.string.pairing_error_port)
    PairingError.InvalidAgentId -> resources.getString(R.string.pairing_error_id)
    PairingError.InvalidName -> resources.getString(R.string.pairing_error_name)
    PairingError.InvalidFingerprint -> resources.getString(R.string.pairing_error_fp)
    PairingError.InvalidToken -> resources.getString(R.string.pairing_error_token)
}
