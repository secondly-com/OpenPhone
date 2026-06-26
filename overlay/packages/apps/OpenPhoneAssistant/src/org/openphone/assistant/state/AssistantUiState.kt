package org.openphone.assistant.state

data class AssistantUiState(
    val route: AssistantRoute = AssistantRoute.Chat,
    val chat: ChatUiState = ChatUiState(),
    val advanced: AdvancedUiState = AdvancedUiState(),
    val pending: PendingConfirmation? = null,
)

enum class AssistantRoute {
    Chat,
    Advanced,
}

data class ChatUiState(
    val messages: List<ChatMessage> = emptyList(),
    val history: List<ChatSessionSummary> = emptyList(),
    val composerText: String = "",
    val isListening: Boolean = false,
    val isAgentRunning: Boolean = false,
    val activeTaskId: String? = null,
    val statusText: String = "OpenPhone is ready",
)

data class ChatMessage(
    val speaker: String,
    val body: String,
    val isUser: Boolean,
)

data class ChatSessionSummary(
    val id: String,
    val title: String,
    val updatedAtMillis: Long,
)

data class PendingConfirmation(
    val actionId: String,
    val toolName: String,
    val summary: String,
)

data class AdvancedUiState(
    val model: ModelConfig = ModelConfig(),
    val ota: OtaState = OtaState(),
    val grants: TaskGrants = TaskGrants(),
    val autonomyMode: String = "yolo",
    val developer: DeveloperState = DeveloperState(),
)

data class ModelConfig(
    val useRealtimeVision: Boolean = false,
    val useRealtime2: Boolean = false,
    val useLiveRealtimeVoice: Boolean = false,
    val useGeminiLiveVoice: Boolean = false,
    val useBroker: Boolean = false,
    val providerMode: String = "local_heuristic",
    val devApiKey: String = "",
    val geminiApiKey: String = "",
    val providerBaseUrl: String = "",
    val modelId: String = "",
    val providerApiKey: String = "",
    val brokerUrl: String = "",
    val brokerToken: String = "",
    val disclosure: String = "Local heuristic model. No network model call is made.",
)

data class OtaState(
    val feedUrl: String = "",
    val status: String = "No OTA check has run.",
    val canDownload: Boolean = false,
)

data class TaskGrants(
    val input: Boolean = true,
    val screenshot: Boolean = true,
    val clipboard: Boolean = false,
    val share: Boolean = false,
    val network: Boolean = false,
)

data class DeveloperState(
    val goal: String = "",
    val rawActionJson: String = "",
    val taskStatus: String = "OpenPhone is ready.",
    val screenContext: String = "Screen context has not been loaded.",
    val auditLog: String = "Audit log has not been loaded.",
)
