package org.openphone.assistant

import android.view.View
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.ComposeView
import org.openphone.assistant.state.ChatHistoryStore
import org.openphone.assistant.state.AssistantViewModel
import org.openphone.assistant.state.PendingConfirmation
import org.openphone.assistant.ui.AssistantApp
import org.openphone.assistant.ui.OpenPhoneTheme

object AssistantComposeHost {
    @JvmStatic
    fun createView(activity: AssistantActivityBackend): View {
        val viewModel = AssistantViewModel(ChatHistoryStore(activity))
        activity.setComposeStateCallbacks(object : AssistantActivityBackend.ComposeStateCallbacks {
            override fun setTaskStatus(text: String) {
                viewModel.updateDeveloperState { it.copy(taskStatus = text) }
            }

            override fun setContextText(text: String) {
                viewModel.updateDeveloperState { it.copy(screenContext = text) }
            }

            override fun setAuditText(text: String) {
                viewModel.updateDeveloperState { it.copy(auditLog = text) }
            }

            override fun setModelDisclosure(text: String) {
                viewModel.updateModelConfig { it.copy(disclosure = text) }
            }

            override fun setModelConfig(
                useRealtime: Boolean,
                useRealtime2: Boolean,
                useLiveRealtimeVoice: Boolean,
                useGeminiLiveVoice: Boolean,
                useBroker: Boolean,
                providerMode: String,
                apiKey: String,
                geminiApiKey: String,
                providerBaseUrl: String,
                modelId: String,
                providerApiKey: String,
                brokerUrl: String,
                brokerToken: String,
            ) {
                viewModel.updateModelConfig {
                    it.copy(
                        useRealtimeVision = useRealtime,
                        useRealtime2 = useRealtime2,
                        useLiveRealtimeVoice = useLiveRealtimeVoice,
                        useGeminiLiveVoice = useGeminiLiveVoice,
                        useBroker = useBroker,
                        providerMode = providerMode,
                        devApiKey = apiKey,
                        geminiApiKey = geminiApiKey,
                        providerBaseUrl = providerBaseUrl,
                        modelId = modelId,
                        providerApiKey = providerApiKey,
                        brokerUrl = brokerUrl,
                        brokerToken = brokerToken,
                    )
                }
            }

            override fun setOtaStatus(text: String, canDownload: Boolean) {
                viewModel.updateOtaState { it.copy(status = text, canDownload = canDownload) }
            }

            override fun setRuntimeStatus(
                text: String,
                activeTaskId: String?,
                running: Boolean,
                listening: Boolean,
            ) {
                viewModel.setRuntimeStatus(text, activeTaskId, running, listening)
            }

            override fun setAutonomyMode(mode: String) {
                viewModel.setAutonomyMode(mode)
            }

            override fun setComposerText(text: String) {
                viewModel.setComposerText(text)
            }

            override fun addConversationMessage(speaker: String, message: String) {
                if (speaker == "You") {
                    viewModel.appendUserMessage(message)
                } else {
                    viewModel.appendAssistantMessage(message)
                }
            }

            override fun setPendingConfirmation(actionId: String, toolName: String, summary: String) {
                viewModel.setPendingConfirmation(PendingConfirmation(actionId, toolName, summary))
            }

            override fun clearPendingConfirmation() {
                viewModel.setPendingConfirmation(null)
            }

            override fun showChat() {
                viewModel.showChat()
            }
        })
        return ComposeView(activity).apply {
            setContent {
                val state by viewModel.state.collectAsState()
                OpenPhoneTheme {
                    AssistantApp(
                        state = state,
                        onShowAdvanced = {
                            viewModel.showAdvanced()
                            activity.onComposeShowAdvanced()
                        },
                        onShowChat = {
                            viewModel.showChat()
                            activity.onComposeShowChat()
                        },
                        onNewChat = {
                            viewModel.newChat()
                            activity.onComposeComposerTextChanged("")
                        },
                        onOpenChat = {
                            viewModel.openChatSession(it)
                            activity.onComposeComposerTextChanged("")
                        },
                        onOpenMemories = {},
                        onComposerTextChange = {
                            viewModel.setComposerText(it)
                        },
                        onSuggestionClick = {
                            viewModel.chooseSuggestion(it)
                        },
                        onComposerAction = {
                            val text = state.chat.composerText
                            activity.onComposeComposerTextChanged(text)
                            activity.onComposeSend()
                        },
                        onMicClick = activity::onComposeMic,
                        onStopClick = activity::onComposeStop,
                        onApprove = activity::onComposeApprove,
                        onDeny = activity::onComposeDeny,
                        onStartTask = activity::onComposeStartTask,
                        onRunAgent = activity::onComposeRunAgent,
                        onStopAgent = activity::onComposeStop,
                        onRefresh = activity::onComposeRefresh,
                        onReadScreen = activity::onComposeReadScreen,
                        onReadScreenshot = activity::onComposeReadScreenshot,
                        onExecuteBack = activity::onComposeExecuteBack,
                        onRunRawAction = activity::onComposeRunRawAction,
                        onExportTrace = activity::onComposeExportTrace,
                        onExportAudit = activity::onComposeExportAudit,
                        onCheckOta = activity::onComposeCheckOta,
                        onDownloadOta = activity::onComposeDownloadOta,
                        onModelConfigChange = {
                            viewModel.setModelConfig(it)
                            activity.onComposeModelConfigChanged(
                                it.useRealtimeVision,
                                it.useRealtime2,
                                it.useLiveRealtimeVoice,
                                it.useGeminiLiveVoice,
                                it.useBroker,
                                it.providerMode,
                                it.devApiKey,
                                it.geminiApiKey,
                                it.providerBaseUrl,
                                it.modelId,
                                it.providerApiKey,
                                it.brokerUrl,
                                it.brokerToken,
                            )
                        },
                        onOtaFeedUrlChange = {
                            viewModel.updateOtaState { state -> state.copy(feedUrl = it) }
                            activity.onComposeOtaFeedUrlChanged(it)
                        },
                        onTaskGrantsChange = {
                            viewModel.setTaskGrants(it)
                            activity.onComposeGrantsChanged(
                                it.input,
                                it.screenshot,
                                it.clipboard,
                                it.share,
                                it.network,
                            )
                        },
                        onAutonomyModeChange = {
                            viewModel.setAutonomyMode(it)
                            activity.onComposeAutonomyModeChanged(it)
                        },
                        onDeveloperGoalChange = {
                            viewModel.updateDeveloperState { state -> state.copy(goal = it) }
                            activity.onComposeComposerTextChanged(it)
                        },
                        onRawActionJsonChange = {
                            viewModel.updateDeveloperState { state -> state.copy(rawActionJson = it) }
                            activity.onComposeActionJsonChanged(it)
                        },
                    )
                }
            }
        }
    }
}
