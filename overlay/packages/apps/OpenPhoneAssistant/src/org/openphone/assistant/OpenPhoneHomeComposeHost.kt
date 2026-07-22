package org.openphone.assistant

import android.view.View
import android.view.TextureView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.openphone.assistant.state.PendingConfirmation
import org.openphone.assistant.jobs.BackgroundJobReviewManager
import org.openphone.assistant.runs.AgentRunProjection
import org.openphone.assistant.runs.AgentRunSummary
import org.openphone.assistant.surface.AdaptiveSurface
import org.openphone.assistant.surface.AdaptiveSurfaceView
import org.openphone.assistant.surface.SurfaceActionDispatcher
import org.openphone.assistant.surface.SurfaceActionResult
import org.openphone.assistant.surface.SurfaceRepository
import org.openphone.assistant.surface.SurfaceRuntimeNotifier
import org.openphone.assistant.ui.common.AssistantGlyph
import org.openphone.assistant.ui.common.AssistantIcon
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

enum class HomeAgentMode {
    Idle,
    Listening,
    Thinking,
    Running,
    Review,
    Error,
    Result,
}

data class HomeUiState(
    val mode: HomeAgentMode = HomeAgentMode.Idle,
    val status: String = "Ready",
    val resultText: String = "",
    val pending: PendingConfirmation? = null,
    val runs: List<AgentRunSummary> = emptyList(),
    val surface: AdaptiveSurface? = null,
    val surfaceActionStatus: String = "",
    val surfaceConfirmation: Boolean = false,
    val silentSpeechFrames: Int = 0,
    val silentSpeechCapturing: Boolean = false,
    val interfacesConnected: Boolean = false,
    val interfacesAuthBusy: Boolean = false,
    val agentRunning: Boolean = false,
)

object OpenPhoneHomeComposeHost {
    private val state = MutableStateFlow(HomeUiState())

    @JvmStatic
    fun createView(activity: OpenPhoneHomeActivity): View {
        state.value = HomeUiState()
        val runProjection = AgentRunProjection(activity)
        val surfaceRepository = SurfaceRepository(activity)
        val surfaceDispatcher = SurfaceActionDispatcher(
            activity,
            activity.phoneToolGatewayForSurfaces(),
        )
        activity.setComposeStateCallbacks(object : AssistantActivityBackend.ComposeStateCallbacks {
            override fun setTaskStatus(text: String) {
                state.update {
                    it.copy(
                        status = text.ifBlank { "Ready" },
                        mode = modeForStatus(text, it.mode),
                    )
                }
            }

            override fun setContextText(text: String) = Unit

            override fun setAuditText(text: String) = Unit

            override fun setModelDisclosure(text: String) = Unit

            override fun setModelConfig(
                useRealtime: Boolean,
                useRealtime2: Boolean,
                useLiveRealtimeVoice: Boolean,
                useGeminiLiveVoice: Boolean,
                useBroker: Boolean,
                apiKey: String,
                geminiApiKey: String,
                brokerUrl: String,
                brokerToken: String,
            ) = Unit

            override fun setOtaStatus(text: String, canDownload: Boolean) = Unit

            override fun setRuntimeStatus(
                text: String,
                activeTaskId: String?,
                running: Boolean,
                listening: Boolean,
            ) {
                state.update {
                    it.copy(
                        mode = when {
                            listening -> HomeAgentMode.Listening
                            running -> HomeAgentMode.Running
                            it.pending != null -> HomeAgentMode.Review
                            text.contains("error", ignoreCase = true) ||
                                text.contains("failed", ignoreCase = true) -> HomeAgentMode.Error
                            else -> modeForStatus(text, HomeAgentMode.Idle)
                        },
                        status = text.ifBlank { "Ready" },
                        agentRunning = running,
                    )
                }
            }

            override fun setAutonomyMode(mode: String) = Unit

            override fun setComposerText(text: String) = Unit

            override fun addConversationMessage(speaker: String, message: String) {
                if (speaker != "You" && message.isNotBlank()) {
                    state.update {
                        it.copy(
                            resultText = message.trim(),
                            status = "Ready",
                            mode = HomeAgentMode.Result,
                            agentRunning = false,
                        )
                    }
                }
            }

            override fun setPendingConfirmation(
                actionId: String,
                toolName: String,
                summary: String,
            ) {
                state.update {
                    it.copy(
                        pending = PendingConfirmation(actionId, toolName, summary),
                        surfaceConfirmation = false,
                        status = "Approval needed",
                        mode = HomeAgentMode.Review,
                    )
                }
            }

            override fun clearPendingConfirmation() {
                state.update {
                    it.copy(
                        pending = null,
                        surfaceConfirmation = false,
                        mode = if (it.mode == HomeAgentMode.Review) HomeAgentMode.Idle else it.mode,
                    )
                }
            }

            override fun showChat() = Unit
        })
        return ComposeView(activity).apply {
            setContent {
                val uiState by state.collectAsState()
                val scope = androidx.compose.runtime.rememberCoroutineScope()
                LaunchedEffect(runProjection) {
                    while (true) {
                        val projection = withContext(Dispatchers.IO) {
                            runProjection.snapshot(24) to surfaceRepository.currentVisible()
                        }
                        state.update {
                            it.copy(
                                runs = projection.first,
                                surface = projection.second,
                            )
                        }
                        delay(2_000L)
                    }
                }
                AiHomeTheme {
                    OpenPhoneHomeScreen(
                        state = uiState,
                        onVoiceStart = activity::onHomeVoiceHoldStarted,
                        onVoiceFinish = activity::onHomeVoiceHoldFinished,
                        onVoiceCancel = activity::onHomeVoiceHoldCancelled,
                        onMicrophoneStart = activity::onHomeMicrophonePressed,
                        onMicrophoneStop = activity::onHomeMicrophoneStopped,
                        onAgentStop = activity::onComposeStop,
                        onSubmitText = activity::submitHomeText,
                        onOpenApps = {
                            if (!activity.openAppSpace()) {
                                deliverLocalMessage("App Space is unavailable.")
                            }
                        },
                        onOpenAssistant = activity::openAssistant,
                        onConnectInterfaces = activity::connectInterfaces,
                        onApprove = {
                            val current = state.value
                            if (!current.surfaceConfirmation) {
                                activity.onComposeApprove()
                            } else {
                                val confirmationId = current.pending?.actionId.orEmpty()
                                scope.launch {
                                    val result = withContext(Dispatchers.IO) {
                                        surfaceDispatcher.resolveConfirmation(
                                            confirmationId,
                                            true,
                                        )
                                    }
                                    applySurfaceActionResult(result)
                                }
                            }
                        },
                        onDeny = {
                            val current = state.value
                            if (!current.surfaceConfirmation) {
                                activity.onComposeDeny()
                            } else {
                                val confirmationId = current.pending?.actionId.orEmpty()
                                scope.launch {
                                    val result = withContext(Dispatchers.IO) {
                                        surfaceDispatcher.resolveConfirmation(
                                            confirmationId,
                                            false,
                                        )
                                    }
                                    applySurfaceActionResult(result)
                                }
                            }
                        },
                        onSurfaceAction = { surface, actionId, input ->
                            scope.launch {
                                state.update { it.copy(surfaceActionStatus = "Working…") }
                                val result = withContext(Dispatchers.IO) {
                                    surfaceDispatcher.invoke(
                                        surface.surfaceId,
                                        surface.revision,
                                        actionId,
                                        input,
                                        "surface:${surface.surfaceId}:${surface.revision}:$actionId",
                                    )
                                }
                                applySurfaceActionResult(result)
                            }
                        },
                        onDismissSurface = { surface ->
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    surfaceRepository.dismiss(surface.surfaceId, "user_dismissed")
                                    SurfaceRuntimeNotifier.dismissed(
                                        activity,
                                        surface,
                                        "user_dismissed",
                                    )
                                }
                                state.update {
                                    it.copy(
                                        surface = null,
                                        surfaceActionStatus = "",
                                        pending = if (it.surfaceConfirmation) null else it.pending,
                                        surfaceConfirmation = false,
                                    )
                                }
                            }
                        },
                        onStopRun = { runId ->
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    runProjection.stop(runId)
                                }
                                val refreshed = withContext(Dispatchers.IO) {
                                    runProjection.snapshot(24)
                                }
                                state.update { it.copy(runs = refreshed) }
                            }
                        },
                        onPauseRun = { runId ->
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    runProjection.pause(runId)
                                }
                                val refreshed = withContext(Dispatchers.IO) {
                                    runProjection.snapshot(24)
                                }
                                state.update { it.copy(runs = refreshed) }
                            }
                        },
                        onResumeRun = { runId ->
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    runProjection.resume(runId)
                                }
                                val refreshed = withContext(Dispatchers.IO) {
                                    runProjection.snapshot(24)
                                }
                                state.update { it.copy(runs = refreshed) }
                            }
                        },
                        onResolveRunReview = { run, approved ->
                            scope.launch {
                                state.update {
                                    it.copy(
                                        status = if (approved) {
                                            "Executing approved action…"
                                        } else {
                                            "Applying denial…"
                                        },
                                        mode = HomeAgentMode.Running,
                                    )
                                }
                                val result = withContext(Dispatchers.IO) {
                                    BackgroundJobReviewManager.resolve(
                                        activity,
                                        run.pendingConfirmationId,
                                        approved,
                                    )
                                }
                                val refreshed = withContext(Dispatchers.IO) {
                                    runProjection.snapshot(24)
                                }
                                val resolved = JSONObject(result)
                                state.update {
                                    it.copy(
                                        runs = refreshed,
                                        status = if (
                                            resolved.optString("status") ==
                                            "background.review_resolved"
                                        ) {
                                            "Background job resumed"
                                        } else {
                                            "Review was already resolved"
                                        },
                                        mode = HomeAgentMode.Idle,
                                    )
                                }
                            }
                        },
                        onReadRun = { runId ->
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    runProjection.markRead(runId)
                                }
                                val refreshed = withContext(Dispatchers.IO) {
                                    runProjection.snapshot(24)
                                }
                                state.update { it.copy(runs = refreshed) }
                            }
                        },
                        onDismissRun = { runId ->
                            scope.launch {
                                withContext(Dispatchers.IO) {
                                    runProjection.dismiss(runId)
                                }
                                val refreshed = withContext(Dispatchers.IO) {
                                    runProjection.snapshot(24)
                                }
                                state.update { it.copy(runs = refreshed) }
                            }
                        },
                        onAttachSilentSpeechPreview = activity::attachSilentSpeechPreview,
                        onDetachSilentSpeechPreview = activity::detachSilentSpeechPreview,
                    )
                }
            }
        }
    }

    fun deliverLocalMessage(message: String) {
        state.update {
            it.copy(
                mode = HomeAgentMode.Error,
                status = message,
                resultText = message,
            )
        }
    }

    @JvmStatic
    fun deliverSilentSpeechTranscript(message: String) {
        val transcript = message.trim()
        if (transcript.isEmpty()) return
        state.update {
            it.copy(
                mode = HomeAgentMode.Thinking,
                status = "Silent Speech",
                resultText = transcript,
                silentSpeechFrames = 0,
                silentSpeechCapturing = false,
            )
        }
    }

    @JvmStatic
    fun beginSilentSpeechCapture() {
        state.update {
            it.copy(
                mode = HomeAgentMode.Listening,
                status = "Starting front camera…",
                resultText = "",
                silentSpeechFrames = 0,
                silentSpeechCapturing = true,
            )
        }
    }

    @JvmStatic
    fun silentSpeechCameraReady() {
        state.update {
            it.copy(mode = HomeAgentMode.Listening, status = "Mouth your request")
        }
    }

    @JvmStatic
    fun updateSilentSpeechFrame(count: Int) {
        state.update {
            it.copy(
                mode = HomeAgentMode.Listening,
                status = "Mouth your request",
                silentSpeechFrames = count,
                silentSpeechCapturing = true,
            )
        }
    }

    @JvmStatic
    fun beginSilentSpeechDecode(frameCount: Int) {
        state.update {
            it.copy(
                mode = HomeAgentMode.Thinking,
                status = "Reading your lips…",
                resultText = "",
                silentSpeechFrames = frameCount,
                silentSpeechCapturing = false,
            )
        }
    }

    @JvmStatic
    fun showSilentSpeechStatus(message: String) {
        state.update {
            it.copy(
                mode = HomeAgentMode.Idle,
                status = message,
                resultText = message,
                silentSpeechCapturing = false,
            )
        }
    }

    @JvmStatic
    fun failSilentSpeech(message: String) {
        state.update {
            it.copy(
                mode = HomeAgentMode.Error,
                status = "Silent Speech failed",
                resultText = message,
                silentSpeechFrames = 0,
                silentSpeechCapturing = false,
            )
        }
    }

    @JvmStatic
    fun cancelSilentSpeech() {
        state.update {
            it.copy(
                mode = HomeAgentMode.Idle,
                status = "Ready",
                resultText = "",
                silentSpeechFrames = 0,
                silentSpeechCapturing = false,
            )
        }
    }

    @JvmStatic
    fun setInterfacesConnectionState(
        signedIn: Boolean,
        busy: Boolean,
        message: String,
        error: Boolean,
    ) {
        state.update {
            it.copy(
                interfacesConnected = signedIn,
                interfacesAuthBusy = busy,
                mode = when {
                    error -> HomeAgentMode.Error
                    busy -> HomeAgentMode.Running
                    message.isNotBlank() -> HomeAgentMode.Result
                    else -> it.mode
                },
                status = message.ifBlank { it.status },
                resultText = message.ifBlank { it.resultText },
            )
        }
    }

    private fun applySurfaceActionResult(result: SurfaceActionResult) {
        if (result.status == "needs_confirmation") {
            val confirmationId = result.result.optString("confirmation_id", "")
            val tool = result.result.optString("tool", "")
            val summary = result.result.optString(
                "summary",
                result.message.ifBlank { "Approve this surface action?" },
            )
            state.update {
                it.copy(
                    pending = PendingConfirmation(confirmationId, tool, summary),
                    surfaceConfirmation = true,
                    surfaceActionStatus = "Approval required",
                    mode = HomeAgentMode.Review,
                )
            }
            return
        }
        val message = when (result.status) {
            "ok" -> "Done"
            "denied" -> "Action denied"
            "timeout" -> "Approval timed out"
            else -> result.message.ifBlank {
                result.code.replace('_', ' ').ifBlank { "Action failed" }
            }
        }
        state.update {
            it.copy(
                pending = if (it.surfaceConfirmation) null else it.pending,
                surfaceConfirmation = false,
                surfaceActionStatus = message,
                mode = if (result.status == "ok") HomeAgentMode.Result else HomeAgentMode.Error,
            )
        }
    }

    private fun modeForStatus(text: String, fallback: HomeAgentMode): HomeAgentMode {
        val clean = text.trim().lowercase(Locale.US)
        return when {
            clean.startsWith("listening") -> HomeAgentMode.Listening
            clean.startsWith("thinking") || clean.startsWith("reading") -> HomeAgentMode.Thinking
            clean.startsWith("working") || clean.startsWith("starting") -> HomeAgentMode.Running
            clean.contains("approval") || clean.contains("review") -> HomeAgentMode.Review
            clean.contains("failed") || clean.contains("error") ||
                clean.contains("unavailable") || clean == "try again" -> HomeAgentMode.Error
            clean == "done" -> HomeAgentMode.Result
            clean == "ready" || clean.contains("is ready") || clean == "stopped" -> HomeAgentMode.Idle
            else -> fallback
        }
    }
}

private val AiHomeColors = darkColorScheme(
    primary = Color(0xFF43B7FF),
    onPrimary = Color.Black,
    secondary = Color(0xFF5BE7D2),
    onSecondary = Color.Black,
    background = Color.Black,
    onBackground = Color(0xFFF5F8FF),
    surface = Color(0xFF080B12),
    onSurface = Color(0xFFF5F8FF),
    surfaceVariant = Color(0xFF111827),
    onSurfaceVariant = Color(0xFF9CA9BC),
    error = Color(0xFFFF6B75),
)

@Composable
private fun AiHomeTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = AiHomeColors, content = content)
}

@Composable
private fun OpenPhoneHomeScreen(
    state: HomeUiState,
    onVoiceStart: () -> Unit,
    onVoiceFinish: () -> Unit,
    onVoiceCancel: () -> Unit,
    onMicrophoneStart: () -> Unit,
    onMicrophoneStop: () -> Unit,
    onAgentStop: () -> Unit,
    onSubmitText: (String) -> Unit,
    onOpenApps: () -> Unit,
    onOpenAssistant: () -> Unit,
    onConnectInterfaces: () -> Unit,
    onApprove: () -> Unit,
    onDeny: () -> Unit,
    onSurfaceAction: (AdaptiveSurface, String, JSONObject) -> Unit,
    onDismissSurface: (AdaptiveSurface) -> Unit,
    onStopRun: (String) -> Unit,
    onPauseRun: (String) -> Unit,
    onResumeRun: (String) -> Unit,
    onResolveRunReview: (AgentRunSummary, Boolean) -> Unit,
    onReadRun: (String) -> Unit,
    onDismissRun: (String) -> Unit,
    onAttachSilentSpeechPreview: (TextureView) -> Unit,
    onDetachSilentSpeechPreview: (TextureView) -> Unit,
) {
    var showTextInput by remember { mutableStateOf(false) }
    var composer by remember { mutableStateOf("") }
    var cumulativeZoom by remember { mutableStateOf(1f) }
    var transitionStarted by remember { mutableStateOf(false) }
    var selectedRunId by remember { mutableStateOf<String?>(null) }
    var showAllRuns by remember { mutableStateOf(false) }
    var now by remember { mutableStateOf(Date()) }
    val selectedRun = state.runs.firstOrNull { it.id == selectedRunId }

    LaunchedEffect(Unit) {
        while (true) {
            now = Date()
            delay(30_000L)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .imePadding()
            .padding(horizontal = 24.dp, vertical = 18.dp),
    ) {
        // Keep the App Space pinch target behind the interactive controls. When this
        // detector lived on the root modifier it was an ancestor of the Silent Speech
        // hold button, so ordinary finger drift could let transform detection consume
        // the gesture and cancel an otherwise valid recording.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTransformGestures(
                        panZoomLock = true,
                        onGesture = { _: Offset, _: Offset, zoom: Float, _: Float ->
                            cumulativeZoom *= zoom
                            if (!transitionStarted && cumulativeZoom < 0.72f) {
                                transitionStarted = true
                                onOpenApps()
                            }
                            if (cumulativeZoom > 0.96f) {
                                transitionStarted = false
                            }
                        },
                    )
                },
        )

        HomeHeader(
            now = now,
            interfacesConnected = state.interfacesConnected,
            interfacesAuthBusy = state.interfacesAuthBusy,
            onOpenApps = onOpenApps,
            onOpenAssistant = onOpenAssistant,
            onConnectInterfaces = onConnectInterfaces,
            modifier = Modifier.align(Alignment.TopCenter),
        )

        HomeResult(
            state = state,
            selectedRun = selectedRun,
            showAllRuns = showAllRuns,
            onSelectRun = {
                selectedRunId = it.id
                showAllRuns = false
                if (it.unreadResult) onReadRun(it.id)
            },
            onCloseRuns = {
                selectedRunId = null
                showAllRuns = false
            },
            onStopRun = onStopRun,
            onPauseRun = onPauseRun,
            onResumeRun = onResumeRun,
            onResolveRunReview = onResolveRunReview,
            onDismissRun = onDismissRun,
            onApprove = onApprove,
            onDeny = onDeny,
            onSurfaceAction = onSurfaceAction,
            onDismissSurface = onDismissSurface,
            modifier = Modifier
                .align(Alignment.Center)
                .padding(bottom = 112.dp),
        )

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            AgentBubbleRow(
                runs = state.runs,
                onSelectRun = {
                    selectedRunId = it.id
                    showAllRuns = false
                    if (it.unreadResult) onReadRun(it.id)
                },
                onShowAll = {
                    selectedRunId = null
                    showAllRuns = true
                },
            )
            Spacer(Modifier.height(16.dp))
            AnimatedVisibility(visible = showTextInput) {
                HomeTextComposer(
                    text = composer,
                    onTextChange = { composer = it },
                    onSubmit = {
                        val request = composer.trim()
                        if (request.isNotEmpty()) {
                            onSubmitText(request)
                            composer = ""
                            showTextInput = false
                        }
                    },
                )
            }
            Spacer(Modifier.height(12.dp))
            HomeInputDock(
                state = state,
                showTextInput = showTextInput,
                onToggleKeyboard = { showTextInput = !showTextInput },
                onSilentSpeechStart = {
                    showTextInput = false
                    onVoiceStart()
                },
                onSilentSpeechFinish = onVoiceFinish,
                onSilentSpeechCancel = onVoiceCancel,
                onMicrophoneStart = {
                    showTextInput = false
                    onMicrophoneStart()
                },
                onMicrophoneStop = onMicrophoneStop,
                onAgentStop = onAgentStop,
                onAttachPreview = onAttachSilentSpeechPreview,
                onDetachPreview = onDetachSilentSpeechPreview,
            )
        }
    }
}

@Composable
private fun HomeHeader(
    now: Date,
    interfacesConnected: Boolean,
    interfacesAuthBusy: Boolean,
    onOpenApps: () -> Unit,
    onOpenAssistant: () -> Unit,
    onConnectInterfaces: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val time = remember(now) { SimpleDateFormat("h:mm", Locale.getDefault()).format(now) }
    val date = remember(now) { SimpleDateFormat("EEE, MMM d", Locale.getDefault()).format(now) }
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text(
                text = time,
                color = MaterialTheme.colorScheme.onBackground,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Medium,
            )
            Text(
                text = date,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
        }
        Spacer(Modifier.weight(1f))
        HomeHeaderAction(
            label = when {
                interfacesAuthBusy -> "Connecting…"
                interfacesConnected -> "Interfaces ✓"
                else -> "Connect"
            },
            description = if (interfacesConnected) {
                "Interfaces account connected"
            } else {
                "Connect an Interfaces account"
            },
            onClick = onConnectInterfaces,
        )
        Spacer(Modifier.size(8.dp))
        HomeHeaderAction("Apps", "Open apps", onOpenApps)
        Spacer(Modifier.size(8.dp))
        HomeHeaderAction("•••", "Open OpenPhone history and settings", onOpenAssistant)
    }
}

@Composable
private fun HomeHeaderAction(label: String, description: String, onClick: () -> Unit) {
    Text(
        text = label,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .clickable(onClick = onClick)
            .semantics {
                contentDescription = description
                role = Role.Button
            }
            .padding(horizontal = 14.dp, vertical = 10.dp),
    )
}

@Composable
private fun HomeResult(
    state: HomeUiState,
    selectedRun: AgentRunSummary?,
    showAllRuns: Boolean,
    onSelectRun: (AgentRunSummary) -> Unit,
    onCloseRuns: () -> Unit,
    onStopRun: (String) -> Unit,
    onPauseRun: (String) -> Unit,
    onResumeRun: (String) -> Unit,
    onResolveRunReview: (AgentRunSummary, Boolean) -> Unit,
    onDismissRun: (String) -> Unit,
    onApprove: () -> Unit,
    onDeny: () -> Unit,
    onSurfaceAction: (AdaptiveSurface, String, JSONObject) -> Unit,
    onDismissSurface: (AdaptiveSurface) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (selectedRun != null || showAllRuns) {
        HomeRunPanel(
            runs = if (showAllRuns) state.runs else listOfNotNull(selectedRun),
            showAll = showAllRuns,
            onSelectRun = onSelectRun,
            onClose = onCloseRuns,
            onStopRun = onStopRun,
            onPauseRun = onPauseRun,
            onResumeRun = onResumeRun,
            onResolveRunReview = onResolveRunReview,
            onDismissRun = onDismissRun,
            modifier = modifier,
        )
        return
    }
    val surface = state.surface
    if (surface != null && (state.pending == null || state.surfaceConfirmation)) {
        Column(
            modifier = modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            AdaptiveSurfaceView(
                surface = surface,
                actionStatus = state.surfaceActionStatus,
                onAction = { actionId, input ->
                    onSurfaceAction(surface, actionId, input)
                },
                onDismiss = { onDismissSurface(surface) },
            )
            if (state.surfaceConfirmation && state.pending != null) {
                Text(
                    state.pending.summary,
                    color = MaterialTheme.colorScheme.onSurface,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 12.dp),
                )
                Row(
                    modifier = Modifier.padding(top = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    ReviewAction("Deny", false, onDeny)
                    ReviewAction("Approve", true, onApprove)
                }
            }
        }
        return
    }
    val visibleText = if (state.silentSpeechCapturing ||
        (state.mode == HomeAgentMode.Thinking && state.silentSpeechFrames > 0)
    ) {
        ""
    } else {
        state.pending?.summary
            ?: state.resultText.ifBlank {
                if (state.mode == HomeAgentMode.Idle) "" else state.status
            }
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (visibleText.isNotBlank()) {
            Text(
                text = visibleText,
                color = if (state.mode == HomeAgentMode.Error) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onBackground
                },
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Medium,
            )
        }
        if (state.pending != null) {
            Row(
                modifier = Modifier.padding(top = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                ReviewAction("Deny", false, onDeny)
                ReviewAction("Approve", true, onApprove)
            }
        }
    }
}

@Composable
private fun HomeInputDock(
    state: HomeUiState,
    showTextInput: Boolean,
    onToggleKeyboard: () -> Unit,
    onSilentSpeechStart: () -> Unit,
    onSilentSpeechFinish: () -> Unit,
    onSilentSpeechCancel: () -> Unit,
    onMicrophoneStart: () -> Unit,
    onMicrophoneStop: () -> Unit,
    onAgentStop: () -> Unit,
    onAttachPreview: (TextureView) -> Unit,
    onDetachPreview: (TextureView) -> Unit,
) {
    val recording = state.silentSpeechCapturing
    val decoding = state.mode == HomeAgentMode.Thinking && state.silentSpeechFrames > 0
    val microphoneListening = state.mode == HomeAgentMode.Listening && !recording
    val agentRunning = state.agentRunning
    val sideControlsVisible = !recording && !decoding && !agentRunning

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(if (recording) 208.dp else 64.dp),
        ) {
            // Keep the TextureView attached while idle so the front camera can remain
            // prepared. Only the pixels are hidden; recording still begins exclusively
            // on the user's press.
            SilentSpeechCameraOrb(
                frameCount = state.silentSpeechFrames,
                onAttach = onAttachPreview,
                onDetach = onDetachPreview,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .size(196.dp)
                    .alpha(if (recording) 1f else 0.01f),
            )

            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(horizontal = 70.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(52.dp), contentAlignment = Alignment.Center) {
                    if (sideControlsVisible) {
                        InputModeButton(
                            selected = showTextInput,
                            enabled = state.mode != HomeAgentMode.Running,
                            label = "Keyboard input",
                            onClick = onToggleKeyboard,
                        ) {
                            KeyboardGlyph(
                                tint = if (showTextInput) Color.White else Color(0xFFD5DCEC),
                            )
                        }
                    }
                }

                if (agentRunning) {
                    AgentStopButton(onStop = onAgentStop)
                } else {
                    SilentSpeechHoldButton(
                        mode = state.mode,
                        recording = recording,
                        decoding = decoding,
                        onStart = onSilentSpeechStart,
                        onFinish = onSilentSpeechFinish,
                        onCancel = onSilentSpeechCancel,
                    )
                }

                Box(Modifier.size(52.dp), contentAlignment = Alignment.Center) {
                    if (sideControlsVisible) {
                        InputModeButton(
                            selected = microphoneListening,
                            enabled = state.mode != HomeAgentMode.Running,
                            label = if (microphoneListening) "Stop microphone" else "Microphone input",
                            selectedColor = Color(0xFFD9485F),
                            onClick = if (microphoneListening) onMicrophoneStop else onMicrophoneStart,
                        ) {
                            AssistantIcon(
                                glyph = AssistantGlyph.Mic,
                                tint = if (microphoneListening) Color.White else Color(0xFFD5DCEC),
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
        }

        Text(
            text = when {
                recording -> "Release to send"
                decoding -> "Reading your lips…"
                microphoneListening -> "Listening…"
                agentRunning -> "Tap to stop"
                state.mode == HomeAgentMode.Running -> "Working"
                state.mode == HomeAgentMode.Review -> "Review needed"
                else -> "Press and hold to record"
            },
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.labelMedium,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}

@Composable
private fun AgentStopButton(onStop: () -> Unit) {
    Box(
        modifier = Modifier
            .size(68.dp)
            .clip(CircleShape)
            .background(Color(0xFFD92D45))
            .border(2.dp, Color(0xFFFF7182), CircleShape)
            .clickable(onClick = onStop)
            .semantics {
                contentDescription = "Stop agent"
                role = Role.Button
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(22.dp)) {
            drawRoundRect(
                color = Color.White,
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(3.dp.toPx()),
            )
        }
    }
}

@Composable
private fun SilentSpeechCameraOrb(
    frameCount: Int,
    onAttach: (TextureView) -> Unit,
    onDetach: (TextureView) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .clip(CircleShape)
            .background(Color(0xFF080B12)),
        contentAlignment = Alignment.Center,
    ) {
        SilentSpeechCameraPreview(
            onAttach = onAttach,
            onDetach = onDetach,
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        listOf(
                            Color.Black.copy(alpha = 0.24f),
                            Color.Transparent,
                            Color.Black.copy(alpha = 0.38f),
                        ),
                    ),
                ),
        )
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.radialGradient(
                        listOf(Color.Transparent, Color.Black.copy(alpha = 0.30f)),
                    ),
                ),
        )
        MouthGlyph(
            tint = Color(0xFFFF5966),
            fill = Color(0x22FF5966),
            modifier = Modifier.size(width = 64.dp, height = 32.dp),
        )
        Canvas(Modifier.fillMaxSize()) {
            val progress = (frameCount / 450f).coerceIn(0f, 1f)
            drawCircle(
                color = Color.White.copy(alpha = 0.42f),
                style = Stroke(width = 1.dp.toPx()),
            )
            drawCircle(
                color = Color.White.copy(alpha = 0.42f),
                radius = size.minDimension / 2f - 5.dp.toPx(),
                style = Stroke(width = 1.5.dp.toPx()),
            )
            drawArc(
                color = Color(0xFFFF5966),
                startAngle = -90f,
                sweepAngle = 360f * progress,
                useCenter = false,
                style = Stroke(width = 5.dp.toPx(), cap = StrokeCap.Round),
            )
        }
    }
}

@Composable
private fun SilentSpeechCameraPreview(
    onAttach: (TextureView) -> Unit,
    onDetach: (TextureView) -> Unit,
    modifier: Modifier = Modifier,
) {
    var preview by remember { mutableStateOf<TextureView?>(null) }
    AndroidView(
        factory = { context ->
            TextureView(context).also {
                preview = it
                onAttach(it)
            }
        },
        modifier = modifier,
    )
    DisposableEffect(Unit) {
        onDispose {
            preview?.let(onDetach)
            preview = null
        }
    }
}

@Composable
private fun InputModeButton(
    selected: Boolean,
    enabled: Boolean,
    label: String,
    selectedColor: Color = Color(0xFF2A7FFF),
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(CircleShape)
            .background(
                if (selected) selectedColor else Color(0xFF171C27).copy(alpha = 0.92f),
            )
            .border(1.dp, Color.White.copy(alpha = 0.20f), CircleShape)
            .clickable(enabled = enabled, onClick = onClick)
            .semantics {
                contentDescription = label
                role = Role.Button
            },
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

@Composable
private fun SilentSpeechHoldButton(
    mode: HomeAgentMode,
    recording: Boolean,
    decoding: Boolean,
    onStart: () -> Unit,
    onFinish: () -> Unit,
    onCancel: () -> Unit,
) {
    val currentMode by rememberUpdatedState(mode)
    val currentStart by rememberUpdatedState(onStart)
    val currentFinish by rememberUpdatedState(onFinish)
    val currentCancel by rememberUpdatedState(onCancel)
    val haptic = LocalHapticFeedback.current
    Box(
        modifier = Modifier
            .size(68.dp)
            .semantics {
                contentDescription = if (recording) {
                    "Release to send Silent Speech"
                } else {
                    "Press and hold for Silent Speech"
                }
                role = Role.Button
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val canStart = currentMode == HomeAgentMode.Idle ||
                        currentMode == HomeAgentMode.Error ||
                        currentMode == HomeAgentMode.Result
                    if (!canStart) {
                        waitForUpOrCancellation()
                        return@awaitEachGesture
                    }
                    down.consume()
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    currentStart()
                    if (waitForUpOrCancellation() == null) {
                        currentCancel()
                    } else {
                        currentFinish()
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (!recording) {
            Canvas(Modifier.fillMaxSize()) {
                drawCircle(
                    brush = Brush.radialGradient(
                        listOf(Color(0xFF65D7FF), Color(0xFF0A4BCB)),
                    ),
                    radius = size.minDimension * 0.48f,
                )
                drawCircle(
                    color = if (decoding) Color(0xFF5BE7D2) else Color(0xFF43B7FF),
                    radius = size.minDimension * 0.48f,
                    style = Stroke(width = 3.dp.toPx()),
                )
            }
            if (decoding) {
                Text("•••", color = Color.White, fontWeight = FontWeight.Bold)
            } else {
                MouthGlyph(
                    tint = Color.White,
                    fill = Color.White,
                    modifier = Modifier.size(width = 32.dp, height = 16.dp),
                )
            }
        }
    }
}

@Composable
private fun KeyboardGlyph(
    tint: Color,
    modifier: Modifier = Modifier.size(22.dp),
) {
    Canvas(modifier) {
        val strokeWidth = 1.8.dp.toPx()
        drawRoundRect(
            color = tint,
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(3.dp.toPx()),
            style = Stroke(width = strokeWidth),
        )
        val keyRadius = 1.05.dp.toPx()
        for (row in 0..1) {
            for (column in 0..4) {
                drawCircle(
                    color = tint,
                    radius = keyRadius,
                    center = Offset(
                        x = size.width * (0.18f + column * 0.16f),
                        y = size.height * (0.30f + row * 0.25f),
                    ),
                )
            }
        }
        drawLine(
            color = tint,
            start = Offset(size.width * 0.27f, size.height * 0.78f),
            end = Offset(size.width * 0.73f, size.height * 0.78f),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round,
        )
    }
}

@Composable
private fun MouthGlyph(
    tint: Color,
    fill: Color,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier) {
        val mouth = Path().apply {
            moveTo(size.width * 0.03f, size.height * 0.52f)
            cubicTo(
                size.width * 0.18f,
                size.height * 0.43f,
                size.width * 0.36f,
                size.height * 0.02f,
                size.width * 0.50f,
                size.height * 0.22f,
            )
            cubicTo(
                size.width * 0.64f,
                size.height * 0.02f,
                size.width * 0.82f,
                size.height * 0.43f,
                size.width * 0.97f,
                size.height * 0.52f,
            )
            cubicTo(
                size.width * 0.82f,
                size.height * 0.73f,
                size.width * 0.65f,
                size.height * 0.94f,
                size.width * 0.50f,
                size.height * 0.90f,
            )
            cubicTo(
                size.width * 0.35f,
                size.height * 0.94f,
                size.width * 0.18f,
                size.height * 0.73f,
                size.width * 0.03f,
                size.height * 0.52f,
            )
            close()
        }
        drawPath(mouth, fill)
        if (tint != fill) {
            drawPath(mouth, tint, style = Stroke(width = 2.dp.toPx()))
        }
    }
}

@Composable
private fun AgentBubbleRow(
    runs: List<AgentRunSummary>,
    onSelectRun: (AgentRunSummary) -> Unit,
    onShowAll: () -> Unit,
) {
    val visible = runs.take(3)
    if (visible.isEmpty()) return
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        visible.forEach { run ->
            AgentBubble(run = run, onClick = { onSelectRun(run) })
        }
        if (runs.size > visible.size) {
            Box(
                modifier = Modifier
                    .size(46.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable(onClick = onShowAll)
                    .semantics {
                        contentDescription = "Show all ${runs.size} OpenPhone runs"
                        role = Role.Button
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "+${runs.size - visible.size}",
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun AgentBubble(run: AgentRunSummary, onClick: () -> Unit) {
    val accent = when {
        run.needsAttention -> Color(0xFFFFC857)
        run.status == "failed" || run.failureLike() -> MaterialTheme.colorScheme.error
        run.kind == AgentRunSummary.KIND_WATCHER -> Color(0xFF5BE7D2)
        run.unreadResult -> Color(0xFF76C9FF)
        else -> Color(0xFF7186A8)
    }
    val label = when (run.kind) {
        AgentRunSummary.KIND_WATCHER -> "◎"
        AgentRunSummary.KIND_COMMITMENT -> "!"
        AgentRunSummary.KIND_SESSION -> "↗"
        else -> if (run.isLive) "●" else "✓"
    }
    Box(
        modifier = Modifier
            .size(52.dp)
            .clip(CircleShape)
            .background(Color(0xFF070A10))
            .border(if (run.needsAttention) 3.dp else 2.dp, accent, CircleShape)
            .clickable(onClick = onClick)
            .semantics {
                contentDescription = "${run.title}. ${run.status}."
                role = Role.Button
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = accent, fontWeight = FontWeight.Bold)
        if (run.unreadResult || run.needsAttention) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(11.dp)
                    .clip(CircleShape)
                    .background(if (run.needsAttention) Color(0xFFFFC857) else Color.White),
            )
        }
    }
}

private fun AgentRunSummary.failureLike(): Boolean =
    failureCountFromProgress(progressText) > 0

private fun failureCountFromProgress(progress: String): Int =
    if (progress.contains("failed", ignoreCase = true) ||
        progress.contains("error", ignoreCase = true)
    ) 1 else 0

@Composable
private fun HomeRunPanel(
    runs: List<AgentRunSummary>,
    showAll: Boolean,
    onSelectRun: (AgentRunSummary) -> Unit,
    onClose: () -> Unit,
    onStopRun: (String) -> Unit,
    onPauseRun: (String) -> Unit,
    onResumeRun: (String) -> Unit,
    onResolveRunReview: (AgentRunSummary, Boolean) -> Unit,
    onDismissRun: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(28.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, Color(0xFF263246), RoundedCornerShape(28.dp))
            .padding(20.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (showAll) "OpenPhone activity" else "Agent run",
                color = MaterialTheme.colorScheme.onSurface,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "Close",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .clip(RoundedCornerShape(14.dp))
                    .clickable(onClick = onClose)
                    .padding(8.dp),
            )
        }
        Spacer(Modifier.height(12.dp))
        if (runs.isEmpty()) {
            Text("No active work", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        runs.take(if (showAll) 8 else 1).forEach { run ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(18.dp))
                    .clickable { if (showAll) onSelectRun(run) }
                    .padding(vertical = 10.dp),
            ) {
                Text(
                    run.title.ifBlank { "OpenPhone work" },
                    color = MaterialTheme.colorScheme.onSurface,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "${run.kind.replace('_', ' ')} · ${run.phase.ifBlank { run.status }}",
                    color = if (run.needsAttention) {
                        Color(0xFFFFC857)
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(top = 3.dp),
                )
                if (run.progressText.isNotBlank()) {
                    Text(
                        run.progressText,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = if (showAll) 2 else 5,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
                if (!showAll && run.reviewSummary.isNotBlank() &&
                    run.reviewSummary != run.progressText
                ) {
                    Text(
                        run.reviewSummary,
                        color = MaterialTheme.colorScheme.onSurface,
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = 6,
                        modifier = Modifier.padding(top = 10.dp),
                    )
                }
                if (!showAll) {
                    if (run.pendingConfirmationId.isNotBlank()) {
                        Row(
                            modifier = Modifier.padding(top = 14.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            ReviewAction("Deny", false) {
                                onResolveRunReview(run, false)
                            }
                            ReviewAction("Approve", true) {
                                onResolveRunReview(run, true)
                            }
                        }
                    }
                    Row(
                        modifier = Modifier.padding(top = 14.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        if (run.canPause) {
                            RunAction("Pause", danger = false) {
                                onPauseRun(run.id)
                            }
                        }
                        if (run.canResume) {
                            RunAction("Resume", danger = false) {
                                onResumeRun(run.id)
                            }
                        }
                        if (run.canStop) {
                            RunAction("Stop", danger = true) { onStopRun(run.id) }
                        }
                        if (run.unreadResult || !run.isLive) {
                            RunAction("Dismiss", danger = false) {
                                onDismissRun(run.id)
                                onClose()
                            }
                        }
                    }
                }
            }
        }
        if (showAll && runs.size > 8) {
            Text(
                "${runs.size - 8} more",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
            )
        }
    }
}

@Composable
private fun RunAction(label: String, danger: Boolean, onClick: () -> Unit) {
    Text(
        label,
        color = if (danger) MaterialTheme.colorScheme.error
        else MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
    )
}

@Composable
private fun ReviewAction(label: String, primary: Boolean, onClick: () -> Unit) {
    Text(
        text = label,
        color = if (primary) Color.Black else MaterialTheme.colorScheme.onSurface,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .clip(RoundedCornerShape(24.dp))
            .background(
                if (primary) MaterialTheme.colorScheme.secondary
                else MaterialTheme.colorScheme.surfaceVariant,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 22.dp, vertical = 13.dp),
    )
}

@Composable
private fun HomeTextComposer(
    text: String,
    onTextChange: (String) -> Unit,
    onSubmit: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(28.dp))
            .background(MaterialTheme.colorScheme.surface)
            .border(1.dp, Color(0xFF263246), RoundedCornerShape(28.dp))
            .padding(horizontal = 18.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicTextField(
            value = text,
            onValueChange = onTextChange,
            textStyle = MaterialTheme.typography.bodyLarge.copy(
                color = MaterialTheme.colorScheme.onSurface,
            ),
            maxLines = 4,
            modifier = Modifier
                .weight(1f)
                .focusRequester(focusRequester)
                .padding(vertical = 10.dp),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (text.isBlank()) {
                        Text(
                            "Ask OpenPhone",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    inner()
                }
            },
        )
        Text(
            text = "Send",
            color = if (text.isBlank()) {
                MaterialTheme.colorScheme.onSurfaceVariant
            } else {
                MaterialTheme.colorScheme.primary
            },
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .clip(RoundedCornerShape(18.dp))
                .clickable(enabled = text.isNotBlank(), onClick = onSubmit)
                .padding(horizontal = 12.dp, vertical = 9.dp),
        )
    }
}
