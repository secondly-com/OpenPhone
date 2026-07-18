package org.openphone.assistant

import android.view.View
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import org.openphone.assistant.state.PendingConfirmation
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
)

object OpenPhoneHomeComposeHost {
    private val state = MutableStateFlow(HomeUiState())

    @JvmStatic
    fun createView(activity: OpenPhoneHomeActivity): View {
        state.value = HomeUiState()
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
                        status = "Approval needed",
                        mode = HomeAgentMode.Review,
                    )
                }
            }

            override fun clearPendingConfirmation() {
                state.update {
                    it.copy(
                        pending = null,
                        mode = if (it.mode == HomeAgentMode.Review) HomeAgentMode.Idle else it.mode,
                    )
                }
            }

            override fun showChat() = Unit
        })
        return ComposeView(activity).apply {
            setContent {
                val uiState by state.collectAsState()
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
                        onApprove = activity::onComposeApprove,
                        onDeny = activity::onComposeDeny,
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
) {
    var showTextInput by remember { mutableStateOf(false) }
    var composer by remember { mutableStateOf("") }
    var cumulativeZoom by remember { mutableStateOf(1f) }
    var transitionStarted by remember { mutableStateOf(false) }
    var now by remember { mutableStateOf(Date()) }

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
            .statusBarsPadding()
            .navigationBarsPadding()
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
            onApprove = onApprove,
            onDeny = onDeny,
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
                onShortTap = { showTextInput = true },
            )
            Text(
                text = when (state.mode) {
                    HomeAgentMode.Listening -> "Release to send"
                    HomeAgentMode.Thinking -> "Thinking"
                    HomeAgentMode.Running -> "Working"
                    HomeAgentMode.Review -> "Review needed"
                    else -> "Hold to talk · tap to type"
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
    onApprove: () -> Unit,
    onDeny: () -> Unit,
    modifier: Modifier = Modifier,
) {
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
                contentDescription = "Hold to talk to OpenPhone. Tap to type."
                role = Role.Button
            }
            .pointerInput(Unit) {
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
