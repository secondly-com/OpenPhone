package org.openphone.assistant.ui.runtimes

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import org.openphone.assistant.runtime.RuntimeRegistry
import org.openphone.assistant.state.AssistantViewModel
import org.openphone.assistant.state.RuntimeAdapterUiState
import org.openphone.assistant.state.RuntimesUiState
import org.openphone.assistant.ui.OpenPhoneTheme
import org.openphone.assistant.ui.chat.IconCapsule
import org.openphone.assistant.ui.common.AssistantGlyph
import org.openphone.assistant.ui.common.GlassSurface

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RuntimesScreen(
    state: RuntimesUiState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onReconnect: () -> Unit,
    onSelectChatRuntime: (String) -> Unit,
    onSelectVolumeRuntime: (String) -> Unit,
    onSelectBackgroundRuntime: (String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(18.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconCapsule(glyph = AssistantGlyph.Back, contentDescription = "Back", onClick = onBack)
            Text(
                text = "Runtimes",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 12.dp),
            )
            Spacer(Modifier.weight(1f))
            StatusBadge(state.status)
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(top = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            GlassSurface(modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Runtime routes", style = MaterialTheme.typography.titleMedium)
                    KeyValueLine("Chat", runtimeDisplayName(state.effectiveChatRuntime))
                    KeyValueLine("Volume buttons", runtimeDisplayName(state.volumeRuntime))
                    KeyValueLine("Watchers/background", runtimeDisplayName(state.backgroundRuntime))
                }
            }

            LocalRuntimeCard(
                chatSelected = state.chatRuntime == "builtin",
                volumeSelected = state.volumeRuntime == "builtin",
                backgroundSelected = state.backgroundRuntime == "builtin",
                onSelectChat = { onSelectChatRuntime("builtin") },
                onSelectVolume = { onSelectVolumeRuntime("builtin") },
                onSelectBackground = { onSelectBackgroundRuntime("builtin") },
            )

            GlassSurface(modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Remote runtime manager", style = MaterialTheme.typography.titleMedium)
                    KeyValueLine("Status", state.status)
                    KeyValueLine("Manager", state.managerStatus)
                    if (state.updatedAtMillis > 0L) {
                        KeyValueLine("Updated", ageText(state.updatedAtMillis))
                    }
                    if (state.lastAction.isNotBlank()) {
                        KeyValueLine("Last action", state.lastAction)
                    }
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Button(onClick = onRefresh) { Text("Refresh") }
                        OutlinedButton(onClick = onReconnect) { Text("Reconnect") }
                    }
                }
            }

            if (state.adapters.isEmpty()) {
                GlassSurface(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = "No runtimes are configured.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                state.adapters.forEach { adapter ->
                    RuntimeCard(
                        adapter = adapter,
                        chatSelected = state.chatRuntime == adapter.name,
                        volumeSelected = state.volumeRuntime == adapter.name,
                        backgroundSelected = state.backgroundRuntime == adapter.name,
                        onSelectChat = { onSelectChatRuntime(adapter.name) },
                        onSelectVolume = { onSelectVolumeRuntime(adapter.name) },
                        onSelectBackground = { onSelectBackgroundRuntime(adapter.name) },
                    )
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun LocalRuntimeCard(
    chatSelected: Boolean,
    volumeSelected: Boolean,
    backgroundSelected: Boolean,
    onSelectChat: () -> Unit,
    onSelectVolume: () -> Unit,
    onSelectBackground: () -> Unit,
) {
    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot("connected")
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 10.dp),
                ) {
                    Text(
                        text = "Phone",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = "Built-in OpenPhone agent and execution layer",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                StatusBadge("available")
            }
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SmallBadge("Always on")
                SmallBadge("Volume buttons")
                SmallBadge("Phone actions")
                if (chatSelected) SmallBadge("Chat")
                if (volumeSelected) SmallBadge("Volume")
                if (backgroundSelected) SmallBadge("Background")
            }
            RuntimeSurfaceButtons(
                chatSelected = chatSelected,
                volumeSelected = volumeSelected,
                backgroundSelected = backgroundSelected,
                enabled = true,
                onSelectChat = onSelectChat,
                onSelectVolume = onSelectVolume,
                onSelectBackground = onSelectBackground,
            )
        }
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun RuntimeCard(
    adapter: RuntimeAdapterUiState,
    chatSelected: Boolean,
    volumeSelected: Boolean,
    backgroundSelected: Boolean,
    onSelectChat: () -> Unit,
    onSelectVolume: () -> Unit,
    onSelectBackground: () -> Unit,
) {
    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(adapter.status)
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 10.dp),
                ) {
                    Text(
                        text = adapter.label.ifBlank { adapter.name },
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = runtimeTitle(adapter.name),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                StatusBadge(adapter.status)
            }
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SmallBadge(if (adapter.enabled) "Enabled" else "Disabled")
                SmallBadge(if (adapter.configured) "Configured" else "Missing URL")
                if (chatSelected) SmallBadge("Chat")
                if (volumeSelected) SmallBadge("Volume")
                if (backgroundSelected) SmallBadge("Background")
            }
            if (adapter.url.isNotBlank()) {
                KeyValueLine("Endpoint", adapter.url)
            }
            if (adapter.deviceId.isNotBlank()) {
                KeyValueLine("Device", adapter.deviceId)
            }
            RuntimeSurfaceButtons(
                chatSelected = chatSelected,
                volumeSelected = volumeSelected,
                backgroundSelected = backgroundSelected,
                enabled = adapter.enabled && adapter.configured,
                onSelectChat = onSelectChat,
                onSelectVolume = onSelectVolume,
                onSelectBackground = onSelectBackground,
            )
        }
    }
}

@Composable
@OptIn(ExperimentalLayoutApi::class)
private fun RuntimeSurfaceButtons(
    chatSelected: Boolean,
    volumeSelected: Boolean,
    backgroundSelected: Boolean,
    enabled: Boolean,
    onSelectChat: () -> Unit,
    onSelectVolume: () -> Unit,
    onSelectBackground: () -> Unit,
) {
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RuntimeSurfaceButton("Chat", chatSelected, enabled, onSelectChat)
        RuntimeSurfaceButton("Volume", volumeSelected, enabled, onSelectVolume)
        RuntimeSurfaceButton("Background", backgroundSelected, enabled, onSelectBackground)
    }
}

@Composable
private fun RuntimeSurfaceButton(
    label: String,
    selected: Boolean,
    enabled: Boolean,
    onSelect: () -> Unit,
) {
    if (selected) {
        OutlinedButton(onClick = {}, enabled = false) { Text(label) }
    } else {
        Button(onClick = onSelect, enabled = enabled) { Text(label) }
    }
}

@Composable
private fun KeyValueLine(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value.ifBlank { "unknown" },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun StatusBadge(status: String) {
    SmallBadge(status.ifBlank { "unknown" })
}

@Composable
private fun SmallBadge(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSecondaryContainer,
        modifier = Modifier
            .clip(MaterialTheme.shapes.small)
            .background(MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.86f))
            .padding(horizontal = 10.dp, vertical = 5.dp),
    )
}

@Composable
private fun StatusDot(status: String) {
    Box(
        modifier = Modifier
            .size(11.dp)
            .clip(CircleShape)
            .background(statusColor(status)),
    )
}

private fun statusColor(status: String): Color =
    when (status.lowercase()) {
        "connected", "available" -> Color(0xFF0E8A4A)
        "connecting", "waiting_for_challenge", "handshaking" -> Color(0xFFB7791F)
        "degraded" -> Color(0xFFD97706)
        "disabled", "stopped", "not_configured" -> Color(0xFF768094)
        else -> Color(0xFFB42318)
    }

private fun runtimeTitle(name: String): String =
    RuntimeRegistry.label(name)

private fun runtimeDisplayName(name: String): String =
    RuntimeRegistry.label(name.ifBlank { "unknown" })

private fun ageText(updatedAtMillis: Long): String {
    val elapsedSeconds = ((System.currentTimeMillis() - updatedAtMillis) / 1000L).coerceAtLeast(0L)
    return when {
        elapsedSeconds < 5L -> "just now"
        elapsedSeconds < 60L -> "${elapsedSeconds}s ago"
        elapsedSeconds < 3600L -> "${elapsedSeconds / 60L}m ago"
        else -> "${elapsedSeconds / 3600L}h ago"
    }
}

private fun fakeRuntimesState(
    status: String,
    managerStatus: String,
    chatRuntime: String = "builtin",
    effectiveChatRuntime: String = "builtin",
    volumeRuntime: String = "builtin",
    backgroundRuntime: String = "builtin",
    lastAction: String = "",
    adapters: List<RuntimeAdapterUiState> = emptyList(),
): RuntimesUiState {
    return RuntimesUiState(
        status = status,
        managerStatus = managerStatus,
        chatRuntime = chatRuntime,
        effectiveChatRuntime = effectiveChatRuntime,
        volumeRuntime = volumeRuntime,
        backgroundRuntime = backgroundRuntime,
        updatedAtMillis = System.currentTimeMillis() - 2000L,
        lastAction = lastAction,
        adapters = adapters,
    )
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun RuntimesScreenPreview_Connected() {
    OpenPhoneTheme {
        RuntimesScreen(
            state = fakeRuntimesState(
                status = "connected",
                managerStatus = "connected",
                chatRuntime = "openclaw",
                effectiveChatRuntime = "openclaw",
                lastAction = "Connected to OpenClaw",
                adapters = listOf(
                    RuntimeAdapterUiState(
                        name = "openclaw",
                        label = "OpenClaw",
                        status = "connected",
                        enabled = true,
                        configured = true,
                        url = "ws://127.0.0.1:18789",
                        deviceId = "openphone-preview-openclaw",
                    )
                ),
            ),
            onBack = {},
            onRefresh = {},
            onReconnect = {},
            onSelectChatRuntime = {},
            onSelectVolumeRuntime = {},
            onSelectBackgroundRuntime = {},
        )
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun RuntimesScreenPreview_Connecting() {
    OpenPhoneTheme {
        RuntimesScreen(
            state = fakeRuntimesState(
                status = "connecting",
                managerStatus = "connecting",
                chatRuntime = "openclaw",
                effectiveChatRuntime = "builtin",
                lastAction = "Connecting to OpenClaw...",
                adapters = listOf(
                    RuntimeAdapterUiState(
                        name = "openclaw",
                        label = "OpenClaw",
                        status = "connecting",
                        enabled = true,
                        configured = true,
                        url = "ws://127.0.0.1:18789",
                        deviceId = "openphone-preview-openclaw",
                    )
                ),
            ),
            onBack = {},
            onRefresh = {},
            onReconnect = {},
            onSelectChatRuntime = {},
            onSelectVolumeRuntime = {},
            onSelectBackgroundRuntime = {},
        )
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun RuntimesScreenPreview_AuthFailed() {
    OpenPhoneTheme {
        RuntimesScreen(
            state = fakeRuntimesState(
                status = "auth_failed",
                managerStatus = "auth_failed",
                chatRuntime = "openclaw",
                effectiveChatRuntime = "builtin",
                lastAction = "Authentication failed: invalid session key",
                adapters = listOf(
                    RuntimeAdapterUiState(
                        name = "openclaw",
                        label = "OpenClaw",
                        status = "auth_failed",
                        enabled = true,
                        configured = true,
                        url = "ws://127.0.0.1:18789",
                        deviceId = "openphone-preview-openclaw",
                    )
                ),
            ),
            onBack = {},
            onRefresh = {},
            onReconnect = {},
            onSelectChatRuntime = {},
            onSelectVolumeRuntime = {},
            onSelectBackgroundRuntime = {},
        )
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun RuntimesScreenPreview_DisabledManager() {
    OpenPhoneTheme {
        RuntimesScreen(
            state = fakeRuntimesState(
                status = "disabled",
                managerStatus = "not_created",
                chatRuntime = "builtin",
                effectiveChatRuntime = "builtin",
                lastAction = "Runtime manager disabled",
                adapters = listOf(
                    RuntimeAdapterUiState(
                        name = "openclaw",
                        label = "OpenClaw",
                        status = "disabled",
                        enabled = false,
                        configured = true,
                        url = "ws://127.0.0.1:18789",
                        deviceId = "openphone-preview-openclaw",
                    )
                ),
            ),
            onBack = {},
            onRefresh = {},
            onReconnect = {},
            onSelectChatRuntime = {},
            onSelectVolumeRuntime = {},
            onSelectBackgroundRuntime = {},
        )
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun RuntimesScreenPreview_NoRuntime() {
    OpenPhoneTheme {
        RuntimesScreen(
            state = fakeRuntimesState(
                status = "connected",
                managerStatus = "connected",
                chatRuntime = "builtin",
                effectiveChatRuntime = "builtin",
                lastAction = "No adapters configured",
                adapters = emptyList(),
            ),
            onBack = {},
            onRefresh = {},
            onReconnect = {},
            onSelectChatRuntime = {},
            onSelectVolumeRuntime = {},
            onSelectBackgroundRuntime = {},
        )
    }
}

@Preview(showBackground = true, widthDp = 390, heightDp = 844)
@Composable
private fun RuntimesScreenPreview_Degraded() {
    OpenPhoneTheme {
        RuntimesScreen(
            state = fakeRuntimesState(
                status = "degraded",
                managerStatus = "degraded",
                chatRuntime = "openclaw",
                effectiveChatRuntime = "openclaw",
                lastAction = "Hermes runtime is offline",
                adapters = listOf(
                    RuntimeAdapterUiState(
                        name = "openclaw",
                        label = "OpenClaw",
                        status = "connected",
                        enabled = true,
                        configured = true,
                        url = "ws://127.0.0.1:18789",
                        deviceId = "openphone-preview-openclaw",
                    ),
                    RuntimeAdapterUiState(
                        name = "hermes",
                        label = "Hermes",
                        status = "offline",
                        enabled = true,
                        configured = true,
                        url = "ws://127.0.0.1:18790",
                        deviceId = "openphone-preview-hermes",
                    )
                ),
            ),
            onBack = {},
            onRefresh = {},
            onReconnect = {},
            onSelectChatRuntime = {},
            onSelectVolumeRuntime = {},
            onSelectBackgroundRuntime = {},
        )
    }
}
