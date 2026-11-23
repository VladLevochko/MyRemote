package dev.myremote.app.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dev.myremote.app.core.pairing.PairingInfo
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.pairingDataStore: DataStore<Preferences> by preferencesDataStore(name = "pairing")

/**
 * The paired agent, kept in app-private storage: `id`, `name`, `fp`, `token` and the last known
 * `host`/`port`, as PROTOCOL.md section 3 requires. Excluded from backups by the manifest.
 */
class PairingStore(context: Context) {
    private val store = context.applicationContext.pairingDataStore

    val pairing: Flow<PairingInfo?> = store.data.map { prefs ->
        PairingInfo(
            host = prefs[HOST] ?: return@map null,
            port = prefs[PORT] ?: return@map null,
            id = prefs[ID] ?: return@map null,
            name = prefs[NAME] ?: return@map null,
            fp = prefs[FP] ?: return@map null,
            token = prefs[TOKEN] ?: return@map null,
        )
    }

    suspend fun save(info: PairingInfo) {
        store.edit { prefs ->
            prefs[HOST] = info.host
            prefs[PORT] = info.port
            prefs[ID] = info.id
            prefs[NAME] = info.name
            prefs[FP] = info.fp
            prefs[TOKEN] = info.token
        }
    }

    /** Remembers where the agent with [agentId] was last reached, unless the pairing changed meanwhile. */
    suspend fun updateEndpoint(agentId: String, host: String, port: Int) {
        store.edit { prefs ->
            if (prefs[ID] == agentId) {
                prefs[HOST] = host
                prefs[PORT] = port
            }
        }
    }

    suspend fun clear() {
        store.edit { it.clear() }
    }

    private companion object {
        val HOST = stringPreferencesKey("host")
        val PORT = intPreferencesKey("port")
        val ID = stringPreferencesKey("id")
        val NAME = stringPreferencesKey("name")
        val FP = stringPreferencesKey("fp")
        val TOKEN = stringPreferencesKey("token")
    }
}
