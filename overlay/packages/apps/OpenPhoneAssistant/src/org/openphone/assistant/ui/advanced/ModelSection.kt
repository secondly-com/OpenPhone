package org.openphone.assistant.ui.advanced

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import org.openphone.assistant.state.ModelConfig
import org.openphone.assistant.ui.OpenPhoneTheme
import org.openphone.assistant.ui.common.GlassSurface

private const val PROVIDER_LOCAL = "local_heuristic"
private const val PROVIDER_OPENAI = "openai_responses"
private const val PROVIDER_COMPATIBLE = "openai_compatible_chat"
private const val PROVIDER_OLLAMA = "ollama_chat"
private const val PROVIDER_QWEN_OMNI = "qwen_omni_realtime"
private const val PROVIDER_BROKER = "remote_broker"

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ModelSection(state: ModelConfig, onChange: (ModelConfig) -> Unit) {
    val providerMode = state.providerMode.ifBlank {
        if (state.useBroker) PROVIDER_BROKER else PROVIDER_LOCAL
    }
    val qwenLive = state.useLiveRealtimeVoice &&
            !state.useGeminiLiveVoice &&
            providerMode == PROVIDER_QWEN_OMNI
    val openAiLive = state.useLiveRealtimeVoice &&
            !state.useGeminiLiveVoice &&
            providerMode != PROVIDER_QWEN_OMNI
    val geminiLive = state.useGeminiLiveVoice
    GlassSurface(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("AI Provider", style = MaterialTheme.typography.titleMedium)
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ProviderButton("Local", providerMode == PROVIDER_LOCAL) {
                    onChange(state.copy(
                        providerMode = PROVIDER_LOCAL,
                        useRealtimeVision = false,
                        useBroker = false,
                    ))
                }
                ProviderButton("OpenAI", providerMode == PROVIDER_OPENAI) {
                    onChange(state.copy(
                        providerMode = PROVIDER_OPENAI,
                        useRealtimeVision = true,
                        useBroker = false,
                    ))
                }
                ProviderButton("Compatible", providerMode == PROVIDER_COMPATIBLE) {
                    onChange(state.copy(
                        providerMode = PROVIDER_COMPATIBLE,
                        useRealtimeVision = true,
                        useLiveRealtimeVoice = false,
                        useBroker = false,
                    ))
                }
                ProviderButton("Ollama", providerMode == PROVIDER_OLLAMA) {
                    onChange(state.copy(
                        providerMode = PROVIDER_OLLAMA,
                        useRealtimeVision = true,
                        useLiveRealtimeVoice = false,
                        useBroker = false,
                    ))
                }
                ProviderButton("Qwen Omni", providerMode == PROVIDER_QWEN_OMNI) {
                    onChange(state.copy(
                        providerMode = PROVIDER_QWEN_OMNI,
                        useRealtimeVision = true,
                        useRealtime2 = false,
                        useBroker = false,
                    ))
                }
                ProviderButton("Broker", providerMode == PROVIDER_BROKER) {
                    onChange(state.copy(
                        providerMode = PROVIDER_BROKER,
                        useRealtimeVision = true,
                        useLiveRealtimeVoice = false,
                        useBroker = true,
                    ))
                }
            }
            ProviderFields(providerMode, state, onChange)
            Text("Voice", style = MaterialTheme.typography.titleMedium)
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (!openAiLive && !geminiLive) {
                    Button(
                        onClick = { onChange(state.copy(
                            useLiveRealtimeVoice = false,
                            useGeminiLiveVoice = false,
                        )) },
                    ) { Text("Classic") }
                } else {
                    OutlinedButton(
                        onClick = { onChange(state.copy(
                            useLiveRealtimeVoice = false,
                            useGeminiLiveVoice = false,
                        )) },
                    ) { Text("Classic") }
                }
                if (openAiLive) {
                    Button(onClick = { onChange(state.copy(
                        useRealtimeVision = true,
                        useRealtime2 = true,
                        useLiveRealtimeVoice = true,
                        useGeminiLiveVoice = false,
                        useBroker = false,
                        providerMode = PROVIDER_OPENAI,
                    )) }) { Text("Live Realtime 2") }
                } else {
                    OutlinedButton(onClick = { onChange(state.copy(
                        useRealtimeVision = true,
                        useRealtime2 = true,
                        useLiveRealtimeVoice = true,
                        useGeminiLiveVoice = false,
                        useBroker = false,
                        providerMode = PROVIDER_OPENAI,
                    )) }) { Text("Live Realtime 2") }
                }
                if (qwenLive) {
                    Button(onClick = { onChange(state.copy(
                        useRealtimeVision = true,
                        useRealtime2 = false,
                        useLiveRealtimeVoice = true,
                        useGeminiLiveVoice = false,
                        useBroker = false,
                        providerMode = PROVIDER_QWEN_OMNI,
                    )) }) { Text("Qwen Omni") }
                } else {
                    OutlinedButton(onClick = { onChange(state.copy(
                        useRealtimeVision = true,
                        useRealtime2 = false,
                        useLiveRealtimeVoice = true,
                        useGeminiLiveVoice = false,
                        useBroker = false,
                        providerMode = PROVIDER_QWEN_OMNI,
                    )) }) { Text("Qwen Omni") }
                }
                if (geminiLive) {
                    Button(onClick = { onChange(state.copy(
                        useLiveRealtimeVoice = false,
                        useGeminiLiveVoice = true,
                        useBroker = false,
                    )) }) { Text("Gemini Live") }
                } else {
                    OutlinedButton(onClick = { onChange(state.copy(
                        useLiveRealtimeVoice = false,
                        useGeminiLiveVoice = true,
                        useBroker = false,
                    )) }) { Text("Gemini Live") }
                }
            }
            Text(
                text = if (geminiLive) {
                    "Volume buttons start a Gemini Live session with streamed screen frames."
                } else if (qwenLive) {
                    "Volume buttons start a Qwen Omni realtime session through the configured endpoint."
                } else if (openAiLive) {
                    "Volume buttons start a live gpt-realtime-2 voice session."
                } else {
                    "Volume buttons use the current OpenPhone voice command flow."
                },
                style = MaterialTheme.typography.bodySmall,
            )
            if (geminiLive) {
                OutlinedTextField(
                    value = state.geminiApiKey,
                    onValueChange = { onChange(state.copy(geminiApiKey = it)) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("Gemini API key") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                )
            }
            Text(providerDisclosure(providerMode), style = MaterialTheme.typography.bodySmall)
            Text(voiceDisclosure(state), style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun ProviderButton(label: String, selected: Boolean, onClick: () -> Unit) {
    if (selected) {
        Button(onClick = onClick) { Text(label) }
    } else {
        OutlinedButton(onClick = onClick) { Text(label) }
    }
}

@Composable
private fun ProviderFields(providerMode: String, state: ModelConfig, onChange: (ModelConfig) -> Unit) {
    when (providerMode) {
        PROVIDER_OPENAI -> {
            OutlinedTextField(
                value = state.devApiKey,
                onValueChange = { onChange(state.copy(devApiKey = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("OpenAI API key") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
            )
            ModelIdField(state, onChange, "Model")
        }
        PROVIDER_COMPATIBLE -> {
            OutlinedTextField(
                value = state.providerBaseUrl,
                onValueChange = { onChange(state.copy(providerBaseUrl = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Base URL") },
                singleLine = true,
            )
            ModelIdField(state, onChange, "Model")
            OutlinedTextField(
                value = state.providerApiKey,
                onValueChange = { onChange(state.copy(providerApiKey = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("API key") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
            )
        }
        PROVIDER_OLLAMA -> {
            OutlinedTextField(
                value = state.providerBaseUrl,
                onValueChange = { onChange(state.copy(providerBaseUrl = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Ollama URL") },
                singleLine = true,
            )
            ModelIdField(state, onChange, "Model")
        }
        PROVIDER_QWEN_OMNI -> {
            OutlinedTextField(
                value = state.providerBaseUrl,
                onValueChange = { onChange(state.copy(providerBaseUrl = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Qwen Omni URL") },
                singleLine = true,
            )
            ModelIdField(state, onChange, "Model")
            OutlinedTextField(
                value = state.providerApiKey,
                onValueChange = { onChange(state.copy(providerApiKey = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("API key") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
            )
        }
        PROVIDER_BROKER -> {
            OutlinedTextField(
                value = state.brokerUrl,
                onValueChange = { onChange(state.copy(brokerUrl = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Broker URL") },
                singleLine = true,
            )
            ModelIdField(state, onChange, "Model")
            OutlinedTextField(
                value = state.brokerToken,
                onValueChange = { onChange(state.copy(brokerToken = it)) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Broker token") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
            )
        }
    }
}

@Composable
private fun ModelIdField(state: ModelConfig, onChange: (ModelConfig) -> Unit, label: String) {
    OutlinedTextField(
        value = state.modelId,
        onValueChange = { onChange(state.copy(modelId = it)) },
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label) },
        singleLine = true,
    )
}

private fun providerDisclosure(providerMode: String): String {
    return when (providerMode) {
        PROVIDER_OPENAI -> "OpenPhone sends task prompts, screen metadata, and task-scoped screenshots directly to OpenAI using the key stored on this device."
        PROVIDER_COMPATIBLE -> "OpenPhone sends model requests directly to the configured OpenAI-compatible endpoint. The endpoint should support chat completions and, for screen tasks, vision content."
        PROVIDER_OLLAMA -> "OpenPhone sends model requests directly to the configured Ollama /api/chat endpoint. Use a vision-capable model for screen tasks."
        PROVIDER_QWEN_OMNI -> "OpenPhone uses the configured Qwen Omni endpoint for OpenAI-compatible chat and live realtime sessions. The realtime URL may be a base HTTP URL or a full ws://.../v1/realtime URL."
        PROVIDER_BROKER -> "OpenPhone sends model requests to an optional remote OpenPhone broker. This is for shared policy or server-side provider key management, not required for BYOK."
        else -> "Local heuristic mode makes no network model call and only handles limited deterministic actions."
    }
}

private fun voiceDisclosure(state: ModelConfig): String {
    return if (state.useGeminiLiveVoice) {
        "Gemini Live uses gemini-3.1-flash-live-preview for a live speech-to-speech session with about one streamed screen frame per second. Phone actions still run through OpenPhone tools."
    } else if (state.useLiveRealtimeVoice && state.providerMode == PROVIDER_QWEN_OMNI) {
        "Qwen Omni live mode uses the configured OpenAI-compatible realtime WebSocket endpoint. Phone actions still run through OpenPhone tools."
    } else if (state.useLiveRealtimeVoice) {
        "Live Realtime 2 uses gpt-realtime-2 for a live speech-to-speech session. Mic audio streams while the session is active; phone actions still run through OpenPhone tools."
    } else if (state.useBroker) {
        "Classic voice uses the configured remote broker for transcription, then runs the OpenPhone agent."
    } else if (state.providerMode == PROVIDER_OPENAI) {
        "Classic voice records one command, transcribes it with OpenAI, then runs the OpenPhone agent."
    } else {
        "Classic voice transcription is not configured for this provider; type the task or choose OpenAI/broker voice."
    }
}

@Composable
internal fun SettingRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    androidx.compose.foundation.layout.Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Preview(showBackground = true)
@Composable
private fun ModelSectionPreview() {
    OpenPhoneTheme {
        ModelSection(
            ModelConfig(
                useRealtimeVision = true,
                useRealtime2 = true,
                useLiveRealtimeVoice = true,
            ),
            {},
        )
    }
}
