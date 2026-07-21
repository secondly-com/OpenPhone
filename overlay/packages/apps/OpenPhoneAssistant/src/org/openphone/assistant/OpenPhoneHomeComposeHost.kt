package org.openphone.assistant

import android.view.View
import android.view.TextureView
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitLongPressOrCancellation
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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
                            running || activeTaskId != null -> HomeAgentMode.Running
                            it.pending != null -> HomeAgentMode.Review
                            text.contains("error", ignoreCase = true) ||
                                text.contains("failed", ignoreCase = true) -> HomeAgentMode.Error
                            else -> modeForStatus(text, HomeAgentMode.Idle)
                        },
                        status = text.ifBlank { "Ready" },
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
                        onSubmitText = activity::submitHomeText,
                        onOpenApps = {
                            if (!activity.openAppSpace()) {
                                deliverLocalMessage("App Space is unavailable.")
                            }
                        },
                        onOpenAssistant = activity::openAssistant,
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
            )
        }
    }

    @JvmStatic
    fun showSilentSpeechStatus(message: String) {
        state.update {
            it.copy(mode = HomeAgentMode.Idle, status = message, resultText = message)
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
                clean.contains("unavailable") -> HomeAgentMode.Error
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
    onSubmitText: (String) -> Unit,
    onOpenApps: () -> Unit,
    onOpenAssistant: () -> Unit,
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
            }
            .imePadding()
            .padding(horizontal = 24.dp, vertical = 18.dp),
    ) {
        HomeHeader(
            now = now,
            onOpenApps = onOpenApps,
            onOpenAssistant = onOpenAssistant,
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
            onAttachSilentSpeechPreview = onAttachSilentSpeechPreview,
            onDetachSilentSpeechPreview = onDetachSilentSpeechPreview,
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
            Spacer(Modifier.height(18.dp))
            VoiceOrb(
                mode = state.mode,
                onVoiceStart = onVoiceStart,
                onVoiceFinish = onVoiceFinish,
                onVoiceCancel = onVoiceCancel,
                onShortTap = {
                    when (state.mode) {
                        HomeAgentMode.Listening -> onVoiceFinish()
                        HomeAgentMode.Idle, HomeAgentMode.Error, HomeAgentMode.Result ->
                            onVoiceStart()
                        else -> Unit
                    }
                },
            )
            Text(
                text = when (state.mode) {
                    HomeAgentMode.Listening -> "Mouth your request · tap to send"
                    HomeAgentMode.Thinking -> if (state.silentSpeechFrames > 0) {
                        "Reading your lips…"
                    } else {
                        "Thinking"
                    }
                    HomeAgentMode.Running -> "Working"
                    HomeAgentMode.Review -> "Review needed"
                    else -> "Tap for Silent Speech"
                },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
    }
}

@Composable
private fun HomeHeader(
    now: Date,
    onOpenApps: () -> Unit,
    onOpenAssistant: () -> Unit,
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
    onAttachSilentSpeechPreview: (TextureView) -> Unit,
    onDetachSilentSpeechPreview: (TextureView) -> Unit,
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
    val visibleText = state.pending?.summary
        ?: state.resultText.ifBlank {
            if (state.mode == HomeAgentMode.Idle) "" else state.status
        }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (state.mode == HomeAgentMode.Listening) {
            SilentSpeechCameraPreview(
                onAttach = onAttachSilentSpeechPreview,
                onDetach = onDetachSilentSpeechPreview,
                modifier = Modifier
                    .size(220.dp)
                    .clip(CircleShape)
                    .border(
                        width = 3.dp,
                        color = Color(0xFFFF5B66),
                        shape = CircleShape,
                    ),
            )
            if (state.silentSpeechFrames > 0) {
                Text(
                    text = "${state.silentSpeechFrames} frames",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(top = 12.dp),
                )
            }
            Spacer(Modifier.height(22.dp))
        }
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

@Composable
private fun VoiceOrb(
    mode: HomeAgentMode,
    onVoiceStart: () -> Unit,
    onVoiceFinish: () -> Unit,
    onVoiceCancel: () -> Unit,
    onShortTap: () -> Unit,
) {
    val haptic = LocalHapticFeedback.current
    val transition = rememberInfiniteTransition(label = "voice-orb")
    val pulse by transition.animateFloat(
        initialValue = 0.82f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(if (mode == HomeAgentMode.Listening) 620 else 1500),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "voice-orb-pulse",
    )
    val active = mode == HomeAgentMode.Listening ||
        mode == HomeAgentMode.Thinking ||
        mode == HomeAgentMode.Running
    Box(
        modifier = Modifier
            .size(104.dp)
            .semantics {
                contentDescription =
                    "Tap to start Silent Speech. Tap again to send. You can also press and hold."
                role = Role.Button
            }
            .pointerInput(mode) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val longPress = awaitLongPressOrCancellation(down.id)
                    if (longPress == null) {
                        onShortTap()
                        return@awaitEachGesture
                    }
                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                    onVoiceStart()
                    val up = waitForUpOrCancellation()
                    if (up == null) {
                        onVoiceCancel()
                    } else {
                        onVoiceFinish()
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawCircle(
                brush = Brush.radialGradient(
                    colors = listOf(
                        Color(0x6643B7FF),
                        Color(0x222A7FFF),
                        Color.Transparent,
                    ),
                ),
                radius = size.minDimension * 0.5f * pulse,
            )
            drawCircle(
                color = if (active) Color(0xFF5BE7D2) else Color(0xFF43B7FF),
                radius = size.minDimension * 0.27f,
                style = Stroke(width = if (active) 6.dp.toPx() else 3.dp.toPx()),
            )
            drawCircle(
                brush = Brush.radialGradient(
                    listOf(Color(0xFF65D7FF), Color(0xFF0A4BCB)),
                ),
                radius = size.minDimension * 0.21f,
            )
        }
        Text(
            text = when (mode) {
                HomeAgentMode.Listening -> "■"
                HomeAgentMode.Thinking, HomeAgentMode.Running -> "•••"
                else -> "●"
            },
            color = Color.White,
            fontWeight = FontWeight.Bold,
        )
    }
}
