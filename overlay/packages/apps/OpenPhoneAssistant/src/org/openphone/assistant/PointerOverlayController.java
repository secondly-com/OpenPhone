package org.openphone.assistant;

import android.animation.ValueAnimator;
import android.content.Context;
import android.content.Intent;
import android.view.animation.PathInterpolator;
import android.graphics.BlurMaskFilter;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.RoundedCorner;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.openphone.assistant.context.ContextIndexStore;
import org.openphone.assistant.runtime.RuntimeConfig;
import org.openphone.assistant.runtime.RuntimeRegistry;
import org.openphone.assistant.jobs.AgentJobRecord;
import org.openphone.assistant.jobs.AgentJobStore;
import org.openphone.assistant.watchers.OpenPhoneWatcherScheduler;
import org.openphone.assistant.watchers.WatcherRecord;
import org.openphone.assistant.watchers.WatcherStore;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.WeakHashMap;

public final class PointerOverlayController {
    private static final String TAG = "OpenPhonePointer";

    interface ScreenAnswerProvider {
        void answerScreen(String prompt, ScreenAnswerCallback callback);
    }

    interface ScreenAnswerCallback {
        void onAnswer(String answer);
    }

    interface ConfirmationHandler {
        void approve();
        void deny();
    }

    private static final int CURSOR_SIZE = 34;
    private static final int RIPPLE_SIZE = 96;
    private static final int ISLAND_WIDTH = 288;
    private static final int ISLAND_HEIGHT = 90;
    private static final int ISLAND_SIDE_MARGIN = 28;
    private static final int ISLAND_EXPANDED_WIDTH = 940;
    private static final int ISLAND_EXPANDED_SIDE_MARGIN = 42;
    private static final int ISLAND_EXPANDED_MIN_HEIGHT = 112;
    private static final int ISLAND_EXPANDED_MAX_HEIGHT = 520;
    private static final int ISLAND_EXPANDED_PADDING_VERTICAL = 22;
    private static final int ISLAND_EXPANDED_PADDING_HORIZONTAL = 34;
    private static final int ISLAND_EXPANDED_PANEL_GAP = -8;
    private static final int ISLAND_DRAG_HANDLE_HEIGHT = 72;
    private static final float ISLAND_DRAG_EXPAND_THRESHOLD = 24f;
    private static final long ISLAND_RESIZE_MS = 260L;
    private static final long THINKING_DOTS_INTERVAL_MS = 420L;
    private static final long REPLY_AUTO_COLLAPSE_MS = 7000L;
    private static final int REPLY_MAX_LINES = 8;
    private static final int CAMERA_RESERVED_WIDTH = 96;
    private static final int CAMERA_ISLAND_FALLBACK_TOP = 42;
    private static final int ACTION_LABEL_GAP = 12;
    private static final int GLOW_STROKE_WIDTH = 76;
    private static final int GLOW_BLUR_RADIUS = 118;
    private static final int GLOW_CORE_STROKE_WIDTH = 8;
    private static final int GLOW_EDGE_INSET = 1;
    private static final long MAX_VISIBLE_MS = 5 * 60 * 1000;
    private static final long DONE_VISIBLE_MS = 2200;
    private static final Set<PointerOverlayController> sControllers =
            Collections.newSetFromMap(new WeakHashMap<>());
    private static String sLatestUserMessage = "";
    private static String sLatestAssistantMessage = "";
    private static long sLatestConversationAtMillis;
    private static final int STATUS_TAB_CHAT = 0;
    private static final int STATUS_TAB_WATCHERS = 1;
    private static final int STATUS_TAB_RUNS = 2;
    private static final int STATUS_TAB_RUNTIME = 3;
    private static final int OPENPHONE_ACCENT = 0xff72e0c4;
    private static final int OPENCLAW_ACCENT = 0xffe43d20;
    private static final int YOLO_ACCENT = 0xffffd166;

    private final Context mContext;
    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private final Runnable mWatchdogHide = this::hide;
    private final ScreenAnswerProvider mScreenAnswerProvider;
    private ConfirmationHandler mConfirmationHandler;
    private WindowManager mWindowManager;
    private FrameLayout mRoot;
    private FrameLayout mIslandRoot;
    // The "Ask OpenPhone" sheet (Screen / Chat / Search / Notifications /
    // Settings buttons floating below the island) was removed 2026-06-13 —
    // user feedback was that the buttons were clutter and the island should
    // only surface contextual actions (e.g. Approve / Deny in needs_review).
    private WindowManager.LayoutParams mIslandParams;
    private GlowBorderView mGlowView;
    private View mDot;
    private TextView mLeftIslandText;
    private TextView mRightIslandText;
    private LinearLayout mIslandCompactRow;
    private View mIslandDragHandle;
    private LinearLayout mIslandExpandedColumn;
    private LinearLayout mIslandTabRow;
    private TextView mChatTabButton;
    private TextView mWatchersTabButton;
    private TextView mRunsTabButton;
    private TextView mRuntimeTabButton;
    private ScrollView mIslandBodyScroll;
    private FrameLayout mIslandBodyFrame;
    private TextView mIslandBodyText;
    private LinearLayout mIslandChatColumn;
    private LinearLayout mIslandActionRow;
    private TextView mApproveButton;
    private TextView mDenyButton;
    private TextView mActionLabel;
    private String mMode = "idle";
    private String mStateDetail = "";
    private String mTranscriptText = "";
    private String mReplyText = "";
    private boolean mYoloActive;
    private int mWatchingCount;
    private boolean mIslandExpanded;
    private boolean mInspectExpanded;
    private boolean mLargeExpanded;
    private boolean mIslandDragExpanded;
    private float mIslandTouchDownY;
    private int mStatusTab = STATUS_TAB_CHAT;
    private int mThinkingDotsFrame;
    private final Runnable mReplyAutoCollapse = () -> {
        if ("reply".equals(mMode) || "transcript".equals(mMode)) {
            showMicButtonNow();
        }
    };
    private final Runnable mThinkingDotsTicker = new Runnable() {
        @Override
        public void run() {
            if (!"thinking".equals(mMode) && !"realtime".equals(mMode)) {
                return;
            }
            mThinkingDotsFrame = (mThinkingDotsFrame + 1) % 3;
            updateIslandViews();
            mHandler.postDelayed(this, THINKING_DOTS_INTERVAL_MS);
        }
    };
    private ValueAnimator mIslandResizeAnimator;

    PointerOverlayController(Context context) {
        this(context, null);
    }

    PointerOverlayController(Context context, ScreenAnswerProvider screenAnswerProvider) {
        mContext = context.getApplicationContext();
        mScreenAnswerProvider = screenAnswerProvider;
        synchronized (sControllers) {
            sControllers.add(this);
        }
    }

    /** Wire the inline Approve/Deny buttons in the expanded needs_review island. */
    void setConfirmationHandler(ConfirmationHandler handler) {
        mConfirmationHandler = handler;
    }

    void show(String taskId) {
        mHandler.post(() -> {
            mMode = "action_running";
            mInspectExpanded = false;
            ensurePointerLayer();
            showPointerDot();
            ensureIslandWindow();
            updateIslandViews();
            armWatchdog();
        });
    }

    void hide() {
        mHandler.post(() -> {
            mHandler.removeCallbacks(mWatchdogHide);
            mHandler.removeCallbacks(mReplyAutoCollapse);
            stopThinkingDots();
            if (mIslandResizeAnimator != null) {
                mIslandResizeAnimator.cancel();
                mIslandResizeAnimator = null;
            }
            if (mWindowManager == null) {
                return;
            }
            removePointerLayer();
            if (mIslandRoot != null) {
                try {
                    mWindowManager.removeView(mIslandRoot);
                } catch (RuntimeException ignored) {
                }
            }
            mRoot = null;
            mIslandRoot = null;
            mIslandParams = null;
            mDot = null;
            mGlowView = null;
            mLeftIslandText = null;
            mRightIslandText = null;
            mIslandCompactRow = null;
            mIslandDragHandle = null;
            mIslandExpandedColumn = null;
            mIslandTabRow = null;
            mChatTabButton = null;
            mWatchersTabButton = null;
            mRunsTabButton = null;
            mRuntimeTabButton = null;
            mIslandBodyScroll = null;
            mIslandBodyFrame = null;
            mIslandBodyText = null;
            mIslandChatColumn = null;
            mIslandActionRow = null;
            mApproveButton = null;
            mDenyButton = null;
            mActionLabel = null;
            mIslandExpanded = false;
            mInspectExpanded = false;
            mLargeExpanded = false;
            mIslandDragExpanded = false;
        });
    }

    void setIslandState(String state, String detail) {
        mHandler.post(() -> {
            String clean = state == null ? "" : state.trim();
            mStateDetail = detail == null ? "" : detail.trim();
            if (!clean.equals(mMode)) {
                mInspectExpanded = false;
                mLargeExpanded = false;
            }
            if (!"thinking".equals(clean) && !"realtime".equals(clean)) {
                stopThinkingDots();
            }
            switch (clean) {
                case "idle":
                    showMicButtonNow();
                    return;
                case "listening":
                    showListeningNow();
                    return;
                case "thinking":
                    mMode = clean;
                    removeAllPointerLayers();
                    ensureIslandWindow();
                    updateIslandViews();
                    startThinkingDots();
                    mHandler.removeCallbacks(mWatchdogHide);
                    return;
                case "realtime":
                    mMode = clean;
                    mInspectExpanded = false;
                    ensurePointerLayer();
                    hidePointerDot();
                    ensureIslandWindow();
                    updateIslandViews();
                    startThinkingDots();
                    mHandler.removeCallbacks(mWatchdogHide);
                    return;
                case "answer_ready":
                case "needs_review":
                case "error":
                    mMode = clean;
                    removeAllPointerLayers();
                    ensureIslandWindow();
                    updateIslandViews();
                    mHandler.removeCallbacks(mWatchdogHide);
                    if ("answer_ready".equals(clean)) {
                        mHandler.postDelayed(this::showMicButtonNow, DONE_VISIBLE_MS);
                    }
                    return;
                case "action_running":
                    mMode = clean;
                    ensurePointerLayer();
                    showPointerDot();
                    ensureIslandWindow();
                    updateIslandViews();
                    armWatchdog();
                    return;
                case "watching":
                    // Watching is an idle variant: the agent is not running but
                    // background watchers are. Stay interactive like idle.
                    mMode = "watching";
                    removeAllPointerLayers();
                    ensureIslandWindow();
                    updateIslandViews();
                    mHandler.removeCallbacks(mWatchdogHide);
                    return;
                default:
            }
        });
    }

    void setYoloActive(boolean yoloActive) {
        mHandler.post(() -> {
            if (mYoloActive == yoloActive) {
                return;
            }
            mYoloActive = yoloActive;
            if (mIslandCompactRow != null) {
                mIslandCompactRow.setBackground(chipBackground(mYoloActive, mIslandExpanded));
            }
            if (mIslandExpandedColumn != null) {
                mIslandExpandedColumn.setBackground(chipBackground(mYoloActive, false));
            }
            updateIslandViews();
        });
    }

    void setWatchingCount(int count) {
        mHandler.post(() -> {
            int bounded = Math.max(0, count);
            if (mWatchingCount == bounded) {
                return;
            }
            mWatchingCount = bounded;
            if ("idle".equals(mMode) || "watching".equals(mMode)) {
                mMode = bounded > 0 ? "watching" : "idle";
            }
            updateIslandViews();
        });
    }

    void showListening() {
        mHandler.post(this::showListeningNow);
    }

    private void showListeningNow() {
        stopThinkingDots();
        mMode = "listening";
        mInspectExpanded = false;
        mLargeExpanded = false;
        mTranscriptText = "";
        removeAllPointerLayers();
        ensureIslandWindow();
        updateIslandViews();
    }

    void showTranscript(String transcript) {
        mHandler.post(() -> {
            stopThinkingDots();
            mMode = "transcript";
            mInspectExpanded = false;
            mLargeExpanded = false;
            mTranscriptText = transcript == null ? "" : transcript.trim();
            mReplyText = "";
            rememberUserMessage(mTranscriptText);
            removeAllPointerLayers();
            ensureIslandWindow();
            updateIslandViews();
        });
    }

    /**
     * Show the assistant's reply text in an expanded multi-line island.
     * Auto-collapses to mic after {@link #REPLY_AUTO_COLLAPSE_MS}; tap the
     * island to keep it open.
     */
    void showReply(String reply) {
        final String clean = reply == null ? "" : reply.trim();
        if (clean.isEmpty()) {
            return;
        }
        mHandler.post(() -> {
            stopThinkingDots();
            mMode = "reply";
            mInspectExpanded = false;
            mLargeExpanded = false;
            mReplyText = clean;
            rememberAssistantMessage(clean);
            removeAllPointerLayers();
            ensureIslandWindow();
            updateIslandViews();
            mHandler.removeCallbacks(mReplyAutoCollapse);
            mHandler.postDelayed(mReplyAutoCollapse, REPLY_AUTO_COLLAPSE_MS);
            mHandler.removeCallbacks(mWatchdogHide);
        });
    }

    void showMicButton() {
        mHandler.post(this::showMicButtonNow);
    }

    private void showMicButtonNow() {
        stopThinkingDots();
        mMode = mWatchingCount > 0 ? "watching" : "idle";
        mInspectExpanded = false;
        mLargeExpanded = false;
        mTranscriptText = "";
        mReplyText = "";
        mStateDetail = "";
        removeAllPointerLayers();
        ensureIslandWindow();
        updateIslandViews();
        mHandler.removeCallbacks(mWatchdogHide);
        mHandler.removeCallbacks(mReplyAutoCollapse);
    }

    public static void publishWatchingCount(int count) {
        ArrayList<PointerOverlayController> controllers;
        synchronized (sControllers) {
            controllers = new ArrayList<>(sControllers);
        }
        for (PointerOverlayController controller : controllers) {
            controller.setWatchingCount(count);
        }
    }

    static void publishIdleState() {
        ArrayList<PointerOverlayController> controllers;
        synchronized (sControllers) {
            controllers = new ArrayList<>(sControllers);
        }
        for (PointerOverlayController controller : controllers) {
            controller.showMicButton();
        }
    }

    void pointerMove(float x, float y) {
        mHandler.post(() -> {
            armWatchdog();
            moveDotNow(x, y);
            pulseDot();
        });
    }

    void pointerTap(float x, float y, boolean longPress) {
        mHandler.post(() -> {
            armWatchdog();
            moveDotNow(x, y);
            showAction(longPress ? "Long press" : "Tap");
            pulseDot();
            addRipple(x, y, longPress);
        });
    }

    void pointerSwipe(float startX, float startY, float endX, float endY) {
        mHandler.post(() -> {
            armWatchdog();
            moveDotNow(startX, startY);
            showAction("Swipe");
            addSwipeTrail(startX, startY, endX, endY);
            mHandler.postDelayed(() -> moveDotNow(endX, endY), 180);
        });
    }

    void typingIndicator() {
        mHandler.post(() -> {
            armWatchdog();
            showAction("Typing");
            pulseDot();
        });
    }

    private void armWatchdog() {
        mHandler.removeCallbacks(mWatchdogHide);
        mHandler.postDelayed(mWatchdogHide, MAX_VISIBLE_MS);
    }

    private void startThinkingDots() {
        mHandler.removeCallbacks(mThinkingDotsTicker);
        mHandler.postDelayed(mThinkingDotsTicker, THINKING_DOTS_INTERVAL_MS);
    }

    private void stopThinkingDots() {
        mHandler.removeCallbacks(mThinkingDotsTicker);
        mThinkingDotsFrame = 0;
    }

    private void ensurePointerLayer() {
        if (mWindowManager == null) {
            mWindowManager = mContext.getSystemService(WindowManager.class);
        }
        if (mWindowManager == null) {
            return;
        }
        if (mRoot == null) {
            mRoot = new FrameLayout(mContext);
            mRoot.setClickable(false);
            mRoot.setFocusable(false);
            WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.TYPE_SYSTEM_ERROR,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                            | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT);
            params.gravity = Gravity.TOP | Gravity.LEFT;
            params.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
            try {
                mWindowManager.addView(mRoot, params);
            } catch (RuntimeException ignored) {
                mRoot = null;
                return;
            }
        }

        if (mGlowView == null) {
            mGlowView = new GlowBorderView(mContext);
            mRoot.addView(mGlowView, 0, new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT));
        }
        if (mActionLabel == null) {
            mActionLabel = new TextView(mContext);
            mActionLabel.setTextColor(0xff101418);
            mActionLabel.setTextSize(12);
            mActionLabel.setTypeface(Typeface.DEFAULT_BOLD);
            mActionLabel.setGravity(Gravity.CENTER);
            mActionLabel.setBackground(actionBackground());
            mActionLabel.setPadding(24, 10, 24, 10);
            mActionLabel.setAlpha(0f);
            FrameLayout.LayoutParams actionParams = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT);
            actionParams.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
            actionParams.topMargin = ISLAND_HEIGHT + ACTION_LABEL_GAP
                    + CAMERA_ISLAND_FALLBACK_TOP;
            mRoot.addView(mActionLabel, actionParams);
        }
        if (mDot == null) {
            mDot = new View(mContext);
            mDot.setBackground(cursorBackground());
            FrameLayout.LayoutParams dotParams = new FrameLayout.LayoutParams(
                    CURSOR_SIZE, CURSOR_SIZE);
            dotParams.leftMargin = 200;
            dotParams.topMargin = 400;
            mRoot.addView(mDot, dotParams);
        }
    }

    private void ensureIslandWindow() {
        if (mWindowManager == null) {
            mWindowManager = mContext.getSystemService(WindowManager.class);
        }
        if (mWindowManager == null) {
            return;
        }
        // Only one island may exist across all controller instances
        // (service + activities); the latest claimant wins.
        ArrayList<PointerOverlayController> controllers;
        synchronized (sControllers) {
            controllers = new ArrayList<>(sControllers);
        }
        for (PointerOverlayController other : controllers) {
            if (other != this) {
                other.removeIslandNow();
            }
        }
        if (mIslandRoot != null) {
            return;
        }
        mIslandRoot = new FrameLayout(mContext);
        // Important: do NOT make the FrameLayout itself clickable. When the
        // root is clickable, ACTION_DOWN claims the gesture before children
        // get it, so the inline Approve / Deny buttons (added later inside
        // mIslandActionRow) never receive their click. Instead we put the
        // tap handlers on the inner content views (compact row + body
        // text), and the action buttons attach their own OnClickListeners.
        mIslandRoot.setClickable(false);
        mIslandRoot.setFocusable(false);
        mIslandRoot.setBackgroundColor(Color.TRANSPARENT);
        LinearLayout row = new LinearLayout(mContext);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER);
        row.setClickable(true);
        row.setOnClickListener(this::handleIslandTap);
        row.setOnLongClickListener(this::handleIslandLongPress);
        row.setOnTouchListener(this::handleIslandTouch);
        row.setBackground(chipBackground(mYoloActive, false));
        row.setPadding(10, 0, 10, 0);
        mIslandRoot.addView(row, compactRowParams(false));
        mIslandCompactRow = row;

        mIslandDragHandle = new View(mContext);
        mIslandDragHandle.setBackgroundColor(Color.TRANSPARENT);
        mIslandDragHandle.setClickable(true);
        mIslandDragHandle.setOnLongClickListener(this::handleIslandLongPress);
        mIslandDragHandle.setOnTouchListener(this::handleIslandTouch);
        FrameLayout.LayoutParams dragHandleParams = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, ISLAND_DRAG_HANDLE_HEIGHT);
        dragHandleParams.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        dragHandleParams.topMargin = ISLAND_HEIGHT - 2;
        mIslandRoot.addView(mIslandDragHandle, dragHandleParams);

        mLeftIslandText = islandText();
        row.addView(mLeftIslandText, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.MATCH_PARENT, 1f));

        View cameraReserved = new View(mContext);
        row.addView(cameraReserved, new LinearLayout.LayoutParams(CAMERA_RESERVED_WIDTH,
                LinearLayout.LayoutParams.MATCH_PARENT));

        mRightIslandText = islandText();
        row.addView(mRightIslandText, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.MATCH_PARENT, 1f));

        // Expanded mode: a vertical column with the wrapped body text and an
        // optional action row (Approve/Deny in needs_review). Sits on top of
        // the compact row, hidden in compact modes.
        mIslandExpandedColumn = new LinearLayout(mContext);
        mIslandExpandedColumn.setOrientation(LinearLayout.VERTICAL);
        mIslandExpandedColumn.setGravity(Gravity.TOP);
        mIslandExpandedColumn.setVisibility(View.GONE);
        mIslandExpandedColumn.setBackground(chipBackground(mYoloActive, false));
        mIslandExpandedColumn.setPadding(ISLAND_EXPANDED_PADDING_HORIZONTAL,
                ISLAND_EXPANDED_PADDING_VERTICAL,
                ISLAND_EXPANDED_PADDING_HORIZONTAL,
                ISLAND_EXPANDED_PADDING_VERTICAL);

        mIslandTabRow = new LinearLayout(mContext);
        mIslandTabRow.setOrientation(LinearLayout.HORIZONTAL);
        mIslandTabRow.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
        mIslandTabRow.setVisibility(View.GONE);
        mChatTabButton = islandTabButton("Chat", STATUS_TAB_CHAT);
        mWatchersTabButton = islandTabButton("Watchers", STATUS_TAB_WATCHERS);
        mRunsTabButton = islandTabButton("Runs", STATUS_TAB_RUNS);
        mRuntimeTabButton = islandTabButton("Runtime", STATUS_TAB_RUNTIME);
        addTabButton(mIslandTabRow, mChatTabButton, 10);
        addTabButton(mIslandTabRow, mWatchersTabButton, 10);
        addTabButton(mIslandTabRow, mRunsTabButton, 10);
        addTabButton(mIslandTabRow, mRuntimeTabButton, 0);
        LinearLayout.LayoutParams tabRowLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        tabRowLp.bottomMargin = 14;
        mIslandExpandedColumn.addView(mIslandTabRow, tabRowLp);

        mIslandBodyScroll = new ScrollView(mContext);
        mIslandBodyScroll.setFillViewport(false);
        mIslandBodyScroll.setClipToPadding(false);
        mIslandBodyScroll.setOverScrollMode(View.OVER_SCROLL_IF_CONTENT_SCROLLS);
        mIslandBodyFrame = new FrameLayout(mContext);
        mIslandBodyScroll.addView(mIslandBodyFrame, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT));
        mIslandBodyFrame.setClickable(true);
        mIslandBodyFrame.setOnClickListener(this::handleIslandTap);
        mIslandBodyFrame.setOnLongClickListener(this::handleIslandLongPress);

        mIslandBodyText = new TextView(mContext);
        mIslandBodyText.setTextColor(0xfff4f7f8);
        mIslandBodyText.setTextSize(15);
        mIslandBodyText.setTypeface(Typeface.DEFAULT);
        mIslandBodyText.setLineSpacing(3f, 1.12f);
        mIslandBodyText.setMaxLines(REPLY_MAX_LINES);
        mIslandBodyText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        mIslandBodyText.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);
        mIslandBodyText.setClickable(true);
        mIslandBodyText.setOnClickListener(this::handleIslandTap);
        mIslandBodyText.setOnLongClickListener(this::handleIslandLongPress);
        mIslandBodyFrame.addView(mIslandBodyText, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT));

        mIslandChatColumn = new LinearLayout(mContext);
        mIslandChatColumn.setOrientation(LinearLayout.VERTICAL);
        mIslandChatColumn.setGravity(Gravity.START);
        mIslandChatColumn.setVisibility(View.GONE);
        mIslandBodyFrame.addView(mIslandChatColumn, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT));

        mIslandExpandedColumn.addView(mIslandBodyScroll, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        mIslandActionRow = new LinearLayout(mContext);
        mIslandActionRow.setOrientation(LinearLayout.HORIZONTAL);
        mIslandActionRow.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        mIslandActionRow.setVisibility(View.GONE);
        mDenyButton = islandActionButton("×", "Deny", 0xfff4f7f8, 0x33ffffff);
        mDenyButton.setOnClickListener(v -> {
            if (mConfirmationHandler != null) {
                mConfirmationHandler.deny();
            }
        });
        mApproveButton = islandActionButton("✓", "Approve", 0xff101418, 0xff20e36a);
        mApproveButton.setOnClickListener(v -> {
            if (mConfirmationHandler != null) {
                mConfirmationHandler.approve();
            }
        });
        LinearLayout.LayoutParams denyLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        denyLp.rightMargin = 12;
        mIslandActionRow.addView(mDenyButton, denyLp);
        mIslandActionRow.addView(mApproveButton, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        LinearLayout.LayoutParams actionRowLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        actionRowLp.topMargin = 14;
        mIslandExpandedColumn.addView(mIslandActionRow, actionRowLp);

        mIslandRoot.addView(mIslandExpandedColumn, expandedColumnParams(
                ISLAND_EXPANDED_MIN_HEIGHT));

        mIslandParams = new WindowManager.LayoutParams(
                ISLAND_WIDTH,
                compactIslandWindowHeight(),
                WindowManager.LayoutParams.TYPE_SYSTEM_ERROR,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT);
        mIslandParams.gravity = Gravity.TOP | Gravity.LEFT;
        mIslandParams.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        int compactWidth = compactIslandWidth();
        mIslandParams.width = compactWidth;
        mIslandParams.x = Math.max(0, (displayWidth() - compactWidth) / 2);
        mIslandParams.y = CAMERA_ISLAND_FALLBACK_TOP;
        try {
            mWindowManager.addView(mIslandRoot, mIslandParams);
            updateIslandViews();
        } catch (RuntimeException ignored) {
            mIslandRoot = null;
            mIslandParams = null;
            mLeftIslandText = null;
            mRightIslandText = null;
            mIslandCompactRow = null;
            mIslandDragHandle = null;
            mIslandBodyScroll = null;
            mIslandBodyFrame = null;
            mIslandBodyText = null;
            mIslandChatColumn = null;
        }
    }

    /**
     * Tap routing for the island. Tap performs the local island action first:
     * expand active/status states, expand/collapse inspectable terminal states,
     * or start voice from idle. Long-press stops an active run.
     */
    private void handleIslandTap(View view) {
        if (isActiveMode()) {
            Log.i(TAG, "island tap opens status mode=" + mMode);
            mInspectExpanded = !mInspectExpanded;
            mLargeExpanded = false;
            mStatusTab = STATUS_TAB_CHAT;
            updateIslandViews();
            return;
        }
        if ("error".equals(mMode) || "answer_ready".equals(mMode)) {
            mInspectExpanded = !mInspectExpanded;
            mLargeExpanded = false;
            updateIslandViews();
            return;
        }
        if ("reply".equals(mMode) || "transcript".equals(mMode)
                || "needs_review".equals(mMode)) {
            mHandler.removeCallbacks(mReplyAutoCollapse);
            if ("reply".equals(mMode) || "transcript".equals(mMode)) {
                mHandler.postDelayed(mReplyAutoCollapse, REPLY_AUTO_COLLAPSE_MS);
            }
            return;
        }
        if ("idle".equals(mMode) || "watching".equals(mMode)) {
            if (mInspectExpanded) {
                mInspectExpanded = false;
                mLargeExpanded = false;
            } else {
                launchAiHome();
                return;
            }
            updateIslandViews();
        }
    }

    private void launchAiHome() {
        Intent intent = new Intent(mContext, OpenPhoneHomeActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        try {
            mContext.startActivity(intent);
        } catch (RuntimeException e) {
            Log.w(TAG, "Unable to launch OpenPhone Home", e);
        }
    }

    private boolean handleIslandLongPress(View view) {
        if (!isActiveMode()) {
            return false;
        }
        Log.i(TAG, "island long press stops active task mode=" + mMode);
        launchStopAgent();
        return true;
    }

    private boolean isActiveMode() {
        return "listening".equals(mMode) || "action_running".equals(mMode)
                || "thinking".equals(mMode) || "realtime".equals(mMode);
    }

    private boolean handleIslandTouch(View view, MotionEvent event) {
        if (!"idle".equals(mMode) && !"watching".equals(mMode)) {
            return false;
        }
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                mIslandTouchDownY = event.getRawY();
                mIslandDragExpanded = false;
                return true;
            case MotionEvent.ACTION_MOVE:
                if (!mIslandDragExpanded
                        && event.getRawY() - mIslandTouchDownY > ISLAND_DRAG_EXPAND_THRESHOLD) {
                    mIslandDragExpanded = true;
                    mInspectExpanded = true;
                    mLargeExpanded = true;
                    mStatusTab = STATUS_TAB_CHAT;
                    updateIslandViews();
                    return true;
                }
                return mIslandDragExpanded;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                if (!mIslandDragExpanded && event.getActionMasked() == MotionEvent.ACTION_UP
                        && event.getRawY() - mIslandTouchDownY > ISLAND_DRAG_EXPAND_THRESHOLD) {
                    mInspectExpanded = true;
                    mLargeExpanded = true;
                    mStatusTab = STATUS_TAB_CHAT;
                    updateIslandViews();
                    return true;
                }
                if (mIslandDragExpanded) {
                    mIslandDragExpanded = false;
                    return true;
                }
                if (event.getActionMasked() == MotionEvent.ACTION_UP) {
                    handleIslandTap(view);
                }
                return true;
            default:
                return false;
        }
    }

    /**
     * No-op. The "Ask OpenPhone" sheet was removed; the field is kept in the
     * controller so legacy code paths that still call removeAiSheet during
     * cleanup do not need to be touched.
     */
    private void removeAiSheet() {
        // intentionally empty
    }

    private void removeIslandNow() {
        mHandler.removeCallbacks(mWatchdogHide);
        if (mIslandResizeAnimator != null) {
            mIslandResizeAnimator.cancel();
            mIslandResizeAnimator = null;
        }
        if (mWindowManager == null) {
            mWindowManager = mContext.getSystemService(WindowManager.class);
        }
        if (mWindowManager == null) {
            return;
        }
        removePointerLayer();
        if (mIslandRoot != null) {
            try {
                mWindowManager.removeView(mIslandRoot);
            } catch (RuntimeException ignored) {
            }
        }
        removeAiSheet();
        mRoot = null;
        mIslandRoot = null;
        mIslandParams = null;
        mDot = null;
        mGlowView = null;
        mLeftIslandText = null;
        mRightIslandText = null;
        mIslandCompactRow = null;
        mIslandDragHandle = null;
        mIslandExpandedColumn = null;
        mIslandTabRow = null;
        mChatTabButton = null;
        mWatchersTabButton = null;
        mRunsTabButton = null;
        mRuntimeTabButton = null;
        mIslandBodyScroll = null;
        mIslandBodyFrame = null;
        mIslandBodyText = null;
        mIslandChatColumn = null;
        mIslandActionRow = null;
        mApproveButton = null;
        mDenyButton = null;
        mActionLabel = null;
        mIslandExpanded = false;
        mInspectExpanded = false;
        mLargeExpanded = false;
        mIslandDragExpanded = false;
    }

    private TextView islandText() {
        TextView view = new TextView(mContext);
        view.setTextColor(0xfff4f7f8);
        view.setTextSize(14);
        view.setTypeface(Typeface.DEFAULT_BOLD);
        view.setGravity(Gravity.CENTER);
        view.setSingleLine(true);
        view.setEllipsize(android.text.TextUtils.TruncateAt.END);
        return view;
    }

    private TextView islandTabButton(String label, int tab) {
        TextView view = new TextView(mContext);
        view.setText(label);
        view.setContentDescription(label);
        view.setTextSize(12);
        view.setTypeface(Typeface.DEFAULT_BOLD);
        view.setGravity(Gravity.CENTER);
        view.setSingleLine(true);
        view.setPadding(20, 10, 20, 10);
        view.setMinHeight(40);
        view.setClickable(true);
        view.setFocusable(true);
        view.setOnClickListener(v -> {
            if (mStatusTab == tab) {
                return;
            }
            mStatusTab = tab;
            updateIslandViews();
        });
        return view;
    }

    private static void addTabButton(LinearLayout row, TextView button, int rightMargin) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.rightMargin = Math.max(0, rightMargin);
        row.addView(button, lp);
    }

    private void updateTabViews(boolean visible) {
        if (mIslandTabRow == null) {
            return;
        }
        mIslandTabRow.setVisibility(visible ? View.VISIBLE : View.GONE);
        if (!visible) {
            return;
        }
        styleTabButton(mChatTabButton, mStatusTab == STATUS_TAB_CHAT);
        styleTabButton(mWatchersTabButton, mStatusTab == STATUS_TAB_WATCHERS);
        styleTabButton(mRunsTabButton, mStatusTab == STATUS_TAB_RUNS);
        styleTabButton(mRuntimeTabButton, mStatusTab == STATUS_TAB_RUNTIME);
    }

    private static void styleTabButton(TextView button, boolean selected) {
        if (button == null) {
            return;
        }
        button.setTextColor(selected ? 0xff101418 : 0xfff4f7f8);
        button.setBackground(tabBackground(selected));
    }

    private void updateIslandViews() {
        if (mLeftIslandText == null || mRightIslandText == null
                || mIslandBodyText == null || mIslandChatColumn == null) {
            return;
        }
        IslandPresentation presentation = presentationForMode();
        mLeftIslandText.setText(presentation.leftText);
        mRightIslandText.setText(presentation.rightText);
        mRightIslandText.setTextColor(presentation.accentColor);
        mIslandBodyText.setText(presentation.bodyText);
        mIslandBodyText.setTextSize(presentation.showTabs ? 13 : 15);
        mIslandBodyText.setMaxLines(Integer.MAX_VALUE);
        mIslandBodyText.setEllipsize(null);
        updateBodyContentViews(presentation);
        updateTabViews(presentation.showTabs);
        if (presentation.expanded) {
            applyExpandedIslandLayout(presentation);
        } else {
            applyCompactIslandLayout();
        }
    }

    private void updateBodyContentViews(IslandPresentation presentation) {
        boolean showChat = presentation.showTabs && mStatusTab == STATUS_TAB_CHAT;
        boolean showRuntime = presentation.showTabs && mStatusTab == STATUS_TAB_RUNTIME;
        if (showChat) {
            mIslandBodyText.setVisibility(View.GONE);
            mIslandChatColumn.setVisibility(View.VISIBLE);
            populateChatColumn();
        } else if (showRuntime) {
            mIslandBodyText.setVisibility(View.GONE);
            mIslandChatColumn.setVisibility(View.VISIBLE);
            populateRuntimeColumn();
        } else {
            mIslandChatColumn.setVisibility(View.GONE);
            mIslandBodyText.setVisibility(View.VISIBLE);
        }
    }

    private IslandPresentation presentationForMode() {
        if ("answer_ready".equals(mMode)) {
            if (mInspectExpanded) {
                return IslandPresentation.expanded("✓", detailOr("Done"), false, 4);
            }
            return IslandPresentation.compact("", "✓", 0xff20e36a);
        }
        if ("listening".equals(mMode)) {
            if (mInspectExpanded) {
                return IslandPresentation.expanded("Listening", detailOr("Listening"), false, 4);
            }
            return IslandPresentation.compact("●", "■", 0xffff6b6b);
        }
        if ("transcript".equals(mMode)) {
            String transcript = mTranscriptText == null ? "" : mTranscriptText;
            if (hasMultiLineTranscript()) {
                return IslandPresentation.expanded(runtimeExpandedTitle(), transcript, false,
                        REPLY_MAX_LINES);
            }
            return IslandPresentation.compact("You said", transcript, 0xfff4f7f8);
        }
        if ("reply".equals(mMode)) {
            return IslandPresentation.expanded(runtimeExpandedTitle(),
                    mReplyText == null ? "" : mReplyText, false, REPLY_MAX_LINES);
        }
        if ("thinking".equals(mMode)) {
            if (mInspectExpanded) {
                return IslandPresentation.expanded(runtimeThinkingTitle(),
                        detailOr("Thinking"), false, 4);
            }
            return IslandPresentation.compact(runtimeThinkingGlyph(), thinkingDots(),
                    runtimeAccentColor(0xff9ab8ff));
        }
        if ("realtime".equals(mMode)) {
            if (mInspectExpanded) {
                return IslandPresentation.expanded(runtimeRealtimeTitle(),
                        detailOr("Live Realtime 2"), false, 4);
            }
            return IslandPresentation.compact(runtimeRealtimeGlyph(), thinkingDots(),
                    runtimeAccentColor(0xffffcc6c));
        }
        if ("action_running".equals(mMode)) {
            if (mInspectExpanded) {
                return IslandPresentation.expanded(yoloPrefix() + "Running",
                        detailOr("Task running"), false, 4);
            }
            return IslandPresentation.compact(yoloPrefix() + "●", "■", 0xffff6b6b);
        }
        if ("needs_review".equals(mMode)) {
            String body = mStateDetail == null || mStateDetail.isEmpty()
                    ? "Approval needed" : mStateDetail;
            return IslandPresentation.expanded("!", body, true, 6);
        }
        if ("error".equals(mMode)) {
            if (mInspectExpanded) {
                return IslandPresentation.expanded("!", detailOr("Something went wrong"),
                        false, 5);
            }
            return IslandPresentation.compact("!", "", 0xffff6b6b);
        }
        if ("watching".equals(mMode)) {
            if (mInspectExpanded) {
                return backgroundStatusPresentation();
            }
            return IslandPresentation.compact(runtimeCompactTitle(),
                    mWatchingCount > 1 ? "◎ " + mWatchingCount : "◎",
                    runtimeAccentColor(0xff9ab8ff));
        }
        if (mInspectExpanded) {
            return backgroundStatusPresentation();
        }
        return IslandPresentation.compact(runtimeCompactTitle(), "◉",
                runtimeAccentColor(OPENPHONE_ACCENT));
    }

    private IslandPresentation backgroundStatusPresentation() {
        int watcherCount = Math.max(mWatchingCount, activeWatchers(50).size());
        boolean showStop = mStatusTab == STATUS_TAB_WATCHERS && watcherCount > 0;
        return IslandPresentation.expandedStatus(runtimeExpandedTitle(), backgroundStatusBody(),
                true, showStop, 10);
    }

    private String backgroundStatusBody() {
        switch (mStatusTab) {
            case STATUS_TAB_RUNTIME:
                return runtimeStatusBody();
            case STATUS_TAB_WATCHERS:
                return watchersStatusBody();
            case STATUS_TAB_RUNS:
                return runsStatusBody();
            case STATUS_TAB_CHAT:
            default:
                return chatStatusBody();
        }
    }

    private String chatStatusBody() {
        int watcherCount = Math.max(mWatchingCount, activeWatchers(50).size());
        int jobCount = activeJobCount();
        StringBuilder body = new StringBuilder();
        body.append(mYoloActive ? "YOLO idle" : "Idle");
        if (mStateDetail != null && !mStateDetail.trim().isEmpty()) {
            body.append("\n").append(shortText(mStateDetail, 96));
        }
        String latest = latestConversationBody();
        if (!latest.isEmpty()) {
            body.append("\n").append(latest);
        } else {
            body.append("\nNo recent chat.");
        }
        body.append("\nWatchers: ").append(watcherCount);
        body.append("  Runs: ").append(jobCount);
        return body.toString();
    }

    private void populateChatColumn() {
        if (mIslandChatColumn == null) {
            return;
        }
        mIslandChatColumn.removeAllViews();
        int watcherCount = Math.max(mWatchingCount, activeWatchers(50).size());
        int jobCount = activeJobCount();
        addChatMetaLine((mYoloActive ? "YOLO idle" : "Idle")
                + "  Watchers " + watcherCount + "  Runs " + jobCount);
        if (mStateDetail != null && !mStateDetail.trim().isEmpty()) {
            addChatMetaLine(shortText(mStateDetail, 120));
        }
        String[] pair = latestConversationPair();
        boolean hasUser = pair[0] != null && !pair[0].trim().isEmpty();
        boolean hasAssistant = pair[1] != null && !pair[1].trim().isEmpty();
        if (!hasUser && !hasAssistant) {
            addEmptyState("◌", "No recent chat");
            return;
        }
        if (hasUser) {
            addChatBubble("You", pair[0], true);
        }
        if (hasAssistant) {
            addChatBubble("OpenPhone", pair[1], false);
        }
    }

    private void addChatMetaLine(String text) {
        TextView view = new TextView(mContext);
        view.setText(text);
        view.setTextColor(0xffaeb8bf);
        view.setTextSize(11);
        view.setSingleLine(false);
        view.setPadding(2, 0, 2, 10);
        mIslandChatColumn.addView(view, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
    }

    private void addEmptyState(String icon, String text) {
        TextView view = new TextView(mContext);
        view.setText(icon + "\n" + text);
        view.setTextColor(0xffcbd3d8);
        view.setTextSize(13);
        view.setGravity(Gravity.CENTER);
        view.setLineSpacing(4f, 1.0f);
        view.setPadding(0, 22, 0, 22);
        mIslandChatColumn.addView(view, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
    }

    private void addChatBubble(String label, String text, boolean fromUser) {
        TextView labelView = new TextView(mContext);
        labelView.setText(label);
        labelView.setTextColor(0xffaeb8bf);
        labelView.setTextSize(10);
        labelView.setGravity(fromUser ? Gravity.END : Gravity.START);
        labelView.setPadding(6, 4, 6, 4);
        mIslandChatColumn.addView(labelView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        LinearLayout row = new LinearLayout(mContext);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(fromUser ? Gravity.END : Gravity.START);
        TextView bubble = new TextView(mContext);
        bubble.setText(shortText(text, mLargeExpanded ? 900 : 280));
        bubble.setTextColor(0xfff4f7f8);
        bubble.setTextSize(14);
        bubble.setLineSpacing(3f, 1.08f);
        bubble.setGravity(Gravity.START);
        bubble.setPadding(20, 14, 20, 14);
        bubble.setMaxWidth(Math.max(260, expandedIslandWidth() - 170));
        bubble.setBackground(chatBubbleBackground(fromUser));
        row.addView(bubble, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        rowLp.bottomMargin = 10;
        mIslandChatColumn.addView(row, rowLp);
    }

    private void populateRuntimeColumn() {
        if (mIslandChatColumn == null) {
            return;
        }
        mIslandChatColumn.removeAllViews();
        RuntimeConfig config = RuntimeConfig.load(mContext);
        addRuntimeCard(runtimeCardTitle(AssistantBrainConfig.BUILTIN,
                RuntimeRegistry.label(AssistantBrainConfig.BUILTIN)), "",
                AssistantBrainConfig.BUILTIN, config);
        if (!config.globallyEnabled) {
            return;
        }
        for (RuntimeConfig.RuntimeSettings settings : config.remoteSettings()) {
            if (settings == null || !settings.configured()) {
                continue;
            }
            addRuntimeCard(runtimeCardTitle(settings.runtime, settings.label),
                    endpointLabel(settings.url), settings.runtime, config);
        }
    }

    private void addRuntimeCard(String title, String endpoint, String runtime,
            RuntimeConfig config) {
        String surfaces = runtimeSurfaceLabels(runtime, config);
        boolean selected = !surfaces.isEmpty();
        LinearLayout card = new LinearLayout(mContext);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setPadding(20, 14, 20, 14);
        card.setClickable(true);
        card.setFocusable(true);
        card.setBackground(runtimeCardBackground(runtime, selected));
        card.setOnClickListener(v -> selectRuntime(runtime));

        TextView titleView = new TextView(mContext);
        titleView.setText(title);
        titleView.setTextColor(selected ? runtimeSelectedTextColor(runtime) : 0xffffffff);
        titleView.setTextSize(15);
        titleView.setTypeface(Typeface.DEFAULT_BOLD);
        titleView.setSingleLine(true);
        titleView.setGravity(Gravity.START);
        card.addView(titleView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        StringBuilder detail = new StringBuilder();
        if (endpoint != null && !endpoint.isEmpty()) {
            detail.append(endpoint);
        }
        String status = runtimeAdapterStatus(runtime);
        if (!status.isEmpty()) {
            if (detail.length() > 0) {
                detail.append(" · ");
            }
            detail.append(status);
        }
        if (selected) {
            if (detail.length() > 0) {
                detail.append("\n");
            }
            detail.append(surfaces);
        }
        if (detail.length() > 0) {
            TextView detailView = new TextView(mContext);
            detailView.setText(detail.toString());
            detailView.setTextColor(selected ? runtimeSelectedSecondaryTextColor(runtime)
                    : 0xccffffff);
            detailView.setTextSize(12);
            detailView.setTypeface(Typeface.DEFAULT);
            detailView.setLineSpacing(2f, 1.05f);
            detailView.setGravity(Gravity.START);
            detailView.setSingleLine(false);
            LinearLayout.LayoutParams detailLp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            detailLp.topMargin = 4;
            card.addView(detailView, detailLp);
        }
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = 8;
        mIslandChatColumn.addView(card, lp);
    }

    private void selectRuntime(String runtime) {
        AssistantBrainConfig.persistMode(mContext, runtime);
        AssistantBrainConfig.persistVolumeMode(mContext, runtime);
        AssistantBrainConfig.persistBackgroundMode(mContext, runtime);
        mStateDetail = runtimeLabel(runtime) + " selected";
        if (!AssistantBrainConfig.BUILTIN.equals(runtime)) {
            Intent reload = new Intent(mContext, OpenPhoneAssistantService.class);
            reload.setAction(OpenPhoneAssistantService.ACTION_RELOAD_RUNTIMES);
            try {
                mContext.startService(reload);
            } catch (RuntimeException ignored) {
            }
        }
        updateIslandViews();
    }

    private String watchersStatusBody() {
        List<WatcherRecord> watchers = activeWatchers(5);
        int watcherCount = Math.max(mWatchingCount, watchers.size());
        StringBuilder body = new StringBuilder();
        body.append("Monitors events and reacts later.");
        if (watcherCount <= 0) {
            body.append("\n\n◎\nNo active watchers");
            return body.toString();
        }
        body.append("\nWatchers: ").append(watcherCount).append(" active");
        for (WatcherRecord watcher : watchers) {
            body.append("\n").append(compactStatusLine(watcher.id, watcher.title,
                    watcher.type, watcher.status, watcher.nextRunAtMillis));
        }
        if (watcherCount > watchers.size()) {
            body.append("\n").append(watcherCount - watchers.size()).append(" more watcher");
            if (watcherCount - watchers.size() != 1) {
                body.append("s");
            }
        }
        return body.toString();
    }

    private String runsStatusBody() {
        List<AgentJobRecord> jobs = activeJobs(5);
        int jobCount = activeJobCount();
        StringBuilder body = new StringBuilder();
        body.append("Queued agent tasks that keep working after current chat.");
        if (jobCount <= 0) {
            body.append("\n\n◌\nNo queued runs");
            return body.toString();
        }
        body.append("\nRuns: ").append(jobCount).append(" active");
        for (AgentJobRecord job : jobs) {
            body.append("\n").append(compactStatusLine(job.id, job.title,
                    job.type, job.status, job.nextRunAtMillis));
        }
        return body.toString();
    }

    private String runtimeStatusBody() {
        RuntimeConfig config = RuntimeConfig.load(mContext);
        StringBuilder body = new StringBuilder();
        for (RuntimeConfig.RuntimeSettings settings : config.remoteSettings()) {
            appendRuntimeEnvironmentLine(body, settings, config);
        }
        appendLocalRuntimeLine(body, config);
        if (body.length() == 0) {
            body.append("No runtimes configured");
        }
        return body.toString();
    }

    private void appendRuntimeEnvironmentLine(StringBuilder body,
            RuntimeConfig.RuntimeSettings settings, RuntimeConfig config) {
        if (settings == null || !config.globallyEnabled || !settings.configured()) {
            return;
        }
        appendRuntimeLinePrefix(body);
        body.append(runtimeCardTitle(settings.runtime, settings.label));
        String endpoint = endpointLabel(settings.url);
        if (!endpoint.isEmpty()) {
            body.append(" IP ").append(endpoint);
        }
        String status = runtimeAdapterStatus(settings.runtime);
        if (!status.isEmpty()) {
            body.append(" · ").append(status);
        }
        String surfaces = runtimeSurfaceLabels(settings.runtime, config);
        if (!surfaces.isEmpty()) {
            body.append("\n").append(surfaces);
        }
    }

    private void appendLocalRuntimeLine(StringBuilder body, RuntimeConfig config) {
        String surfaces = runtimeSurfaceLabels(AssistantBrainConfig.BUILTIN, config);
        appendRuntimeLinePrefix(body);
        body.append("⚡ Phone");
        if (!surfaces.isEmpty()) {
            body.append("\n").append(surfaces);
        }
    }

    private void appendRuntimeLinePrefix(StringBuilder body) {
        if (body.length() > 0) {
            body.append("\n\n");
        }
    }

    private String runtimeSurfaceLabels(String runtime, RuntimeConfig config) {
        StringBuilder surfaces = new StringBuilder();
        appendSurfaceLabel(surfaces, "Chat", AssistantBrainConfig.routeRuntime(mContext, config),
                runtime);
        appendSurfaceLabel(surfaces, "Volume",
                AssistantBrainConfig.routeVolumeRuntime(mContext, config), runtime);
        appendSurfaceLabel(surfaces, "Background",
                AssistantBrainConfig.routeBackgroundRuntime(mContext, config), runtime);
        return surfaces.toString();
    }

    private void appendSurfaceLabel(StringBuilder surfaces, String label, String selected,
            String runtime) {
        if (!RuntimeRegistry.normalize(runtime).equals(RuntimeRegistry.normalize(selected))) {
            return;
        }
        if (surfaces.length() > 0) {
            surfaces.append(" · ");
        }
        surfaces.append(label);
    }

    private String runtimeAdapterStatus(String runtime) {
        String statusJson = OpenPhoneAssistantService.latestRuntimeStatusJson();
        try {
            JSONObject status = new JSONObject(statusJson == null ? "{}" : statusJson);
            JSONArray adapters = status.optJSONArray("adapters");
            if (adapters == null || adapters.length() == 0) {
                return "";
            }
            for (int i = 0; i < adapters.length(); i++) {
                JSONObject adapter = adapters.optJSONObject(i);
                if (adapter == null) {
                    continue;
                }
                if (runtime.equals(normalizeRuntime(adapter.optString("name", "")))) {
                    return adapter.optString("status", "unknown");
                }
            }
            return "";
        } catch (JSONException e) {
            return "";
        }
    }

    private static String endpointLabel(String url) {
        String value = url == null ? "" : url.trim();
        if (value.isEmpty()) {
            return "";
        }
        int scheme = value.indexOf("://");
        if (scheme >= 0) {
            value = value.substring(scheme + 3);
        }
        int slash = value.indexOf('/');
        if (slash >= 0) {
            value = value.substring(0, slash);
        }
        int at = value.lastIndexOf('@');
        if (at >= 0) {
            value = value.substring(at + 1);
        }
        return value;
    }

    private static String normalizeRuntime(String runtime) {
        return RuntimeRegistry.normalize(runtime);
    }

    private static String runtimeLabel(String runtime) {
        String label = RuntimeRegistry.label(runtime);
        return label.isEmpty() ? "unknown" : label;
    }

    private List<WatcherRecord> activeWatchers(int limit) {
        try {
            return new WatcherStore(mContext).active(limit);
        } catch (RuntimeException e) {
            return new ArrayList<>();
        }
    }

    private List<AgentJobRecord> activeJobs(int limit) {
        List<AgentJobRecord> out = new ArrayList<>();
        try {
            for (AgentJobRecord job : new AgentJobStore(mContext).list("", 50)) {
                if (!isLiveJob(job)) {
                    continue;
                }
                if (out.size() < Math.max(1, limit)) {
                    out.add(job);
                }
            }
        } catch (RuntimeException ignored) {
        }
        return out;
    }

    private int activeJobCount() {
        int count = 0;
        try {
            for (AgentJobRecord job : new AgentJobStore(mContext).list("", 50)) {
                if (isLiveJob(job)) {
                    count++;
                }
            }
        } catch (RuntimeException ignored) {
        }
        return count;
    }

    private static boolean isLiveJob(AgentJobRecord job) {
        return job != null && ("active".equals(job.status) || "running".equals(job.status));
    }

    private String latestConversationBody() {
        String[] pair = latestConversationPair();
        return formatLatestConversation(pair[0], pair[1]);
    }

    private String[] latestConversationPair() {
        String[] local = latestConversationPairFromMemory();
        if (!local[0].isEmpty() || !local[1].isEmpty()) {
            return local;
        }
        try {
            JSONArray conversation = new JSONArray(
                    new ContextIndexStore(mContext).recentConversationJson(6));
            String user = "";
            String assistant = "";
            for (int i = conversation.length() - 1; i >= 0; i--) {
                JSONObject item = conversation.optJSONObject(i);
                if (item == null) {
                    continue;
                }
                String speaker = item.optString("speaker", "");
                String text = item.optString("text", "").trim();
                if (text.isEmpty()) {
                    continue;
                }
                if (user.isEmpty() && isUserSpeaker(speaker)) {
                    user = text;
                } else if (assistant.isEmpty()) {
                    assistant = text;
                }
                if (!user.isEmpty() && !assistant.isEmpty()) {
                    break;
                }
            }
            return new String[] { user, assistant };
        } catch (JSONException | RuntimeException e) {
            return new String[] { "", "" };
        }
    }

    private static boolean isUserSpeaker(String speaker) {
        return speaker != null && "you".equals(speaker.trim().toLowerCase(java.util.Locale.US));
    }

    static void rememberConversationMessage(String speaker, String text) {
        if (isUserSpeaker(speaker)) {
            rememberUserMessage(text);
        } else {
            rememberAssistantMessage(text);
        }
    }

    private static void rememberUserMessage(String text) {
        String clean = text == null ? "" : text.trim();
        if (clean.isEmpty()) {
            return;
        }
        synchronized (PointerOverlayController.class) {
            sLatestUserMessage = clean;
            sLatestConversationAtMillis = System.currentTimeMillis();
        }
    }

    private static void rememberAssistantMessage(String text) {
        String clean = text == null ? "" : text.trim();
        if (clean.isEmpty()) {
            return;
        }
        synchronized (PointerOverlayController.class) {
            sLatestAssistantMessage = clean;
            sLatestConversationAtMillis = System.currentTimeMillis();
        }
    }

    private static String latestConversationBodyFromMemory() {
        String[] pair = latestConversationPairFromMemory();
        return formatLatestConversation(pair[0], pair[1]);
    }

    private static String[] latestConversationPairFromMemory() {
        synchronized (PointerOverlayController.class) {
            if (sLatestConversationAtMillis <= 0L
                    || (sLatestUserMessage.isEmpty() && sLatestAssistantMessage.isEmpty())) {
                return new String[] { "", "" };
            }
            return new String[] { sLatestUserMessage, sLatestAssistantMessage };
        }
    }

    private static String formatLatestConversation(String user, String assistant) {
        String cleanUser = shortText(user, 96);
        String cleanAssistant = shortText(assistant, 150);
        StringBuilder body = new StringBuilder();
        if (!cleanUser.isEmpty()) {
            body.append("You\n").append(cleanUser);
        }
        if (!cleanAssistant.isEmpty()) {
            if (body.length() > 0) {
                body.append("\n");
            }
            body.append("OpenPhone\n").append(cleanAssistant);
        }
        return body.toString();
    }

    private static String compactStatusLine(long id, String title, String type, String status,
            long nextRunAtMillis) {
        String cleanTitle = shortText(firstNonEmpty(title, type, "Background item"), 44);
        String cleanType = shortText(type, 18);
        String cleanStatus = shortText(status, 18);
        String timing = relativeTime(nextRunAtMillis);
        StringBuilder line = new StringBuilder();
        line.append("- ");
        if (id > 0) {
            line.append("#").append(id).append(" ");
        }
        line.append(cleanTitle);
        if (!cleanType.isEmpty()) {
            line.append(" (").append(cleanType).append(")");
        }
        if (!cleanStatus.isEmpty() && !"active".equals(cleanStatus)) {
            line.append(" ").append(cleanStatus);
        }
        if (!timing.isEmpty()) {
            line.append(" ").append(timing);
        }
        return line.toString();
    }

    private static String relativeTime(long epochMillis) {
        if (epochMillis <= 0) {
            return "";
        }
        long deltaMillis = epochMillis - System.currentTimeMillis();
        if (deltaMillis <= 0) {
            return "due now";
        }
        long minutes = Math.max(1L, Math.round(deltaMillis / 60000.0));
        if (minutes < 60) {
            return "in " + minutes + "m";
        }
        long hours = Math.max(1L, Math.round(minutes / 60.0));
        if (hours < 24) {
            return "in " + hours + "h";
        }
        long days = Math.max(1L, Math.round(hours / 24.0));
        return "in " + days + "d";
    }

    private static String firstNonEmpty(String first, String second, String fallback) {
        if (first != null && !first.trim().isEmpty()) {
            return first.trim();
        }
        if (second != null && !second.trim().isEmpty()) {
            return second.trim();
        }
        return fallback;
    }

    private static String shortText(String text, int maxChars) {
        String clean = text == null ? "" : text.trim().replace('\n', ' ');
        int max = Math.max(4, maxChars);
        return clean.length() <= max ? clean : clean.substring(0, max - 3) + "...";
    }

    private boolean hasMultiLineTranscript() {
        return mTranscriptText != null && mTranscriptText.length() > 28;
    }

    private void applyCompactIslandLayout() {
        if (mIslandCompactRow == null || mIslandExpandedColumn == null) {
            return;
        }
        mIslandExpanded = false;
        mLargeExpanded = false;
        mIslandCompactRow.setVisibility(View.VISIBLE);
        mIslandCompactRow.animate().cancel();
        mIslandCompactRow.setAlpha(1f);
        mIslandCompactRow.setBackground(chipBackground(mYoloActive, false));
        mIslandCompactRow.setLayoutParams(compactRowParams(false));
        if (mIslandDragHandle != null) {
            mIslandDragHandle.setVisibility(View.VISIBLE);
        }
        mIslandExpandedColumn.animate().cancel();
        mIslandExpandedColumn.setVisibility(View.GONE);
        mIslandExpandedColumn.setAlpha(1f);
        if (mIslandActionRow != null) {
            mIslandActionRow.setVisibility(View.GONE);
        }
        animateIslandTo(compactIslandWidth(), compactIslandWindowHeight(),
                CAMERA_ISLAND_FALLBACK_TOP);
    }

    private void applyExpandedIslandLayout(IslandPresentation presentation) {
        if (mIslandCompactRow == null || mIslandExpandedColumn == null) {
            return;
        }
        mIslandExpanded = true;
        mIslandCompactRow.animate().cancel();
        mIslandCompactRow.setVisibility(View.VISIBLE);
        mIslandCompactRow.setAlpha(1f);
        mIslandCompactRow.setBackground(chipBackground(mYoloActive, true));
        mIslandCompactRow.setLayoutParams(compactRowParams(true));
        if (mIslandDragHandle != null) {
            mIslandDragHandle.setVisibility(View.GONE);
        }
        mIslandExpandedColumn.setVisibility(View.VISIBLE);
        mIslandExpandedColumn.animate().cancel();
        mIslandExpandedColumn.setAlpha(1f);
        if (mIslandActionRow != null) {
            if (presentation.showActions) {
                configureReviewActions();
                mIslandActionRow.setVisibility(View.VISIBLE);
            } else if (presentation.showStopWatcherAction) {
                configureStopWatcherAction();
                mIslandActionRow.setVisibility(View.VISIBLE);
            } else {
                mIslandActionRow.setVisibility(View.GONE);
            }
        }
        int targetWidth = expandedIslandWidth();
        setBodyScrollFillMode(false);
        int panelHeight = mLargeExpanded
                ? largeExpandedPanelHeight()
                : measureExpandedHeight(targetWidth);
        setBodyScrollFillMode(true);
        mIslandExpandedColumn.setLayoutParams(expandedColumnParams(panelHeight));
        int targetHeight = ISLAND_HEIGHT + ISLAND_EXPANDED_PANEL_GAP + panelHeight;
        animateIslandTo(targetWidth, targetHeight, CAMERA_ISLAND_FALLBACK_TOP);
    }

    private FrameLayout.LayoutParams compactRowParams(boolean expanded) {
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
                expanded ? compactIslandWidth() : FrameLayout.LayoutParams.MATCH_PARENT,
                ISLAND_HEIGHT);
        params.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        return params;
    }

    private FrameLayout.LayoutParams expandedColumnParams(int panelHeight) {
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, panelHeight);
        params.gravity = Gravity.TOP | Gravity.LEFT;
        params.topMargin = ISLAND_HEIGHT + ISLAND_EXPANDED_PANEL_GAP;
        return params;
    }

    private int expandedIslandWidth() {
        int width = displayWidth();
        if (width <= 0) {
            return ISLAND_EXPANDED_WIDTH;
        }
        return Math.max(ISLAND_WIDTH, Math.min(ISLAND_EXPANDED_WIDTH,
                width - ISLAND_EXPANDED_SIDE_MARGIN * 2));
    }

    private int compactIslandWidth() {
        int width = displayWidth();
        if (width <= 0) {
            return ISLAND_WIDTH;
        }
        return Math.max(260, Math.min(ISLAND_WIDTH, width - ISLAND_SIDE_MARGIN * 2));
    }

    private static int compactIslandWindowHeight() {
        return ISLAND_HEIGHT + ISLAND_DRAG_HANDLE_HEIGHT;
    }

    private int measureExpandedHeight(int expandedWidth) {
        if (mIslandExpandedColumn == null) {
            return ISLAND_EXPANDED_MIN_HEIGHT;
        }
        mIslandExpandedColumn.measure(
                View.MeasureSpec.makeMeasureSpec(expandedWidth, View.MeasureSpec.AT_MOST),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int columnHeight = mIslandExpandedColumn.getMeasuredHeight();
        return Math.max(ISLAND_EXPANDED_MIN_HEIGHT,
                Math.min(ISLAND_EXPANDED_MAX_HEIGHT, columnHeight));
    }

    private int largeExpandedPanelHeight() {
        int displayHeight = displayHeight();
        if (displayHeight <= 0) {
            return ISLAND_EXPANDED_MAX_HEIGHT;
        }
        int targetTotalHeight = Math.round(displayHeight * 0.75f);
        int maxTotalHeight = Math.max(ISLAND_HEIGHT + ISLAND_EXPANDED_MIN_HEIGHT,
                displayHeight - CAMERA_ISLAND_FALLBACK_TOP - 24);
        targetTotalHeight = Math.min(targetTotalHeight, maxTotalHeight);
        return Math.max(ISLAND_EXPANDED_MIN_HEIGHT,
                targetTotalHeight - ISLAND_HEIGHT - ISLAND_EXPANDED_PANEL_GAP);
    }

    private void setBodyScrollFillMode(boolean fill) {
        if (mIslandBodyScroll == null) {
            return;
        }
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                fill ? 0 : LinearLayout.LayoutParams.WRAP_CONTENT);
        if (fill) {
            params.weight = 1f;
        }
        mIslandBodyScroll.setLayoutParams(params);
    }

    private void configureReviewActions() {
        if (mDenyButton == null || mApproveButton == null) {
            return;
        }
        mDenyButton.setVisibility(View.VISIBLE);
        styleActionButton(mDenyButton, "×", "Deny", 0xfff4f7f8, 0x33ffffff,
                v -> {
                    if (mConfirmationHandler != null) {
                        mConfirmationHandler.deny();
                    }
                });
        styleActionButton(mApproveButton, "✓", "Approve", 0xff101418, 0xff20e36a,
                v -> {
                    if (mConfirmationHandler != null) {
                        mConfirmationHandler.approve();
                    }
                });
    }

    private void configureStopWatcherAction() {
        if (mDenyButton == null || mApproveButton == null) {
            return;
        }
        mDenyButton.setVisibility(View.GONE);
        styleActionButton(mApproveButton, "×", "Stop all watchers",
                0xfffff2f2, 0xff7b1f2a, v -> stopAllWatchersFromIsland());
    }

    private void styleActionButton(TextView button, String label, String contentDescription,
            int textColor, int backgroundColor, View.OnClickListener listener) {
        if (button == null) {
            return;
        }
        button.setText(label);
        button.setContentDescription(contentDescription);
        button.setTextColor(textColor);
        button.setOnClickListener(listener);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(28f);
        bg.setColor(backgroundColor);
        button.setBackground(bg);
    }

    private TextView islandActionButton(String label, String contentDescription,
            int textColor, int backgroundColor) {
        TextView button = new TextView(mContext);
        button.setText(label);
        button.setContentDescription(contentDescription);
        button.setTextColor(textColor);
        button.setTextSize(18);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setGravity(Gravity.CENTER);
        button.setPadding(18, 12, 18, 12);
        button.setMinWidth(64);
        button.setMinHeight(44);
        button.setClickable(true);
        button.setFocusable(true);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.RECTANGLE);
        bg.setCornerRadius(28f);
        bg.setColor(backgroundColor);
        button.setBackground(bg);
        return button;
    }

    private void stopAllWatchersFromIsland() {
        int stopped = 0;
        try {
            WatcherStore store = new WatcherStore(mContext);
            for (WatcherRecord watcher : store.active(50)) {
                if (watcher != null && watcher.id > 0 && store.stop(watcher.id)) {
                    stopped++;
                }
            }
            if (stopped > 0) {
                OpenPhoneWatcherScheduler.scheduleNext(mContext);
            }
            mWatchingCount = activeWatchers(50).size();
            if (mWatchingCount <= 0 && "watching".equals(mMode)) {
                mMode = "idle";
            }
            publishWatchingCount(mWatchingCount);
            mStateDetail = stopped == 1 ? "Stopped 1 watcher."
                    : "Stopped " + stopped + " watchers.";
        } catch (RuntimeException e) {
            mStateDetail = "Could not stop watchers.";
        }
        mInspectExpanded = true;
        updateIslandViews();
    }

    private void animateIslandTo(int targetWidth, int targetHeight, int targetTop) {
        if (mWindowManager == null || mIslandRoot == null || mIslandParams == null) {
            return;
        }
        if (mIslandResizeAnimator != null) {
            mIslandResizeAnimator.cancel();
            mIslandResizeAnimator = null;
        }
        final int startWidth = mIslandParams.width;
        final int startHeight = mIslandParams.height;
        final int startTop = mIslandParams.y;
        final int startX = mIslandParams.x;
        final int targetX = Math.max(0, (displayWidth() - targetWidth) / 2);
        if (startWidth == targetWidth && startHeight == targetHeight
                && startTop == targetTop && startX == targetX) {
            return;
        }
        ValueAnimator animator = ValueAnimator.ofFloat(0f, 1f);
        animator.setDuration(ISLAND_RESIZE_MS);
        // Material standard easing: starts a bit fast, settles softly.
        animator.setInterpolator(new PathInterpolator(0.4f, 0f, 0.2f, 1f));
        animator.addUpdateListener(a -> {
            if (mWindowManager == null || mIslandRoot == null
                    || mIslandParams == null) {
                return;
            }
            float t = (float) a.getAnimatedValue();
            mIslandParams.width = (int) (startWidth + (targetWidth - startWidth) * t);
            mIslandParams.height = (int) (startHeight + (targetHeight - startHeight) * t);
            mIslandParams.x = (int) (startX + (targetX - startX) * t);
            mIslandParams.y = (int) (startTop + (targetTop - startTop) * t);
            float settle = 0.985f + (0.015f * t);
            mIslandRoot.setScaleX(settle);
            mIslandRoot.setScaleY(settle);
            try {
                mWindowManager.updateViewLayout(mIslandRoot, mIslandParams);
            } catch (RuntimeException ignored) {
            }
        });
        mIslandResizeAnimator = animator;
        animator.addListener(new android.animation.AnimatorListenerAdapter() {
            @Override
            public void onAnimationEnd(android.animation.Animator animation) {
                if (mIslandRoot != null) {
                    mIslandRoot.setScaleX(1f);
                    mIslandRoot.setScaleY(1f);
                }
                if (mIslandResizeAnimator == animation) {
                    mIslandResizeAnimator = null;
                }
            }
        });
        animator.start();
    }

    private String yoloPrefix() {
        if (!mYoloActive || hasSelectedRemoteRuntime()) {
            return "";
        }
        return "⚡ ";
    }

    private String runtimeCompactTitle() {
        String runtime = selectedRemoteRuntime();
        return runtime.isEmpty() ? yoloPrefix() + "AI" : runtimeGlyph(runtime);
    }

    private String runtimeExpandedTitle() {
        String runtime = selectedRemoteRuntime();
        return runtime.isEmpty() ? "AI" : RuntimeRegistry.label(runtime);
    }

    private String runtimeThinkingTitle() {
        String runtime = selectedRemoteRuntime();
        return runtime.isEmpty() ? "Thinking" : RuntimeRegistry.label(runtime);
    }

    private String runtimeThinkingGlyph() {
        String runtime = selectedRemoteRuntime();
        return runtime.isEmpty() ? "" : runtimeGlyph(runtime);
    }

    private String runtimeRealtimeTitle() {
        String runtime = selectedRemoteRuntime();
        return runtime.isEmpty() ? "Realtime" : RuntimeRegistry.label(runtime);
    }

    private String runtimeRealtimeGlyph() {
        String runtime = selectedRemoteRuntime();
        return runtime.isEmpty() ? "⚡" : runtimeGlyph(runtime);
    }

    private int runtimeAccentColor(int localAccent) {
        String runtime = selectedRemoteRuntime();
        return runtime.isEmpty() ? localAccent : runtimeAccent(runtime, localAccent);
    }

    private boolean hasSelectedRemoteRuntime() {
        return !selectedRemoteRuntime().isEmpty();
    }

    private String selectedRemoteRuntime() {
        RuntimeConfig config = RuntimeConfig.load(mContext);
        String chat = AssistantBrainConfig.routeRuntime(mContext, config);
        if (RuntimeRegistry.isRemoteRuntime(chat)) {
            return chat;
        }
        String volume = AssistantBrainConfig.routeVolumeRuntime(mContext, config);
        if (RuntimeRegistry.isRemoteRuntime(volume)) {
            return volume;
        }
        String background = AssistantBrainConfig.routeBackgroundRuntime(mContext, config);
        return RuntimeRegistry.isRemoteRuntime(background) ? background : "";
    }

    private String thinkingDots() {
        switch (mThinkingDotsFrame) {
            case 0:
                return ".";
            case 1:
                return "..";
            default:
                return "...";
        }
    }

    private String detailOr(String fallback) {
        return mStateDetail == null || mStateDetail.trim().isEmpty()
                ? fallback : mStateDetail.trim();
    }

    private void positionActionLabel() {
        if (mRoot == null || mActionLabel == null) {
            return;
        }
        int actionWidth = measuredWidth(mActionLabel);
        FrameLayout.LayoutParams actionParams =
                (FrameLayout.LayoutParams) mActionLabel.getLayoutParams();
        actionParams.gravity = Gravity.TOP | Gravity.LEFT;
        int rootWidth = mRoot.getWidth();
        actionParams.leftMargin = rootWidth > 0 && actionWidth > 0
                ? Math.max(0, (rootWidth - actionWidth) / 2) : 0;
        actionParams.topMargin = (mIslandParams == null
                ? CAMERA_ISLAND_FALLBACK_TOP : mIslandParams.y)
                + ISLAND_HEIGHT + ACTION_LABEL_GAP;
        mActionLabel.setLayoutParams(actionParams);
    }

    private int displayWidth() {
        if (mRoot != null && mRoot.getWidth() > 0) {
            return mRoot.getWidth();
        }
        if (mWindowManager != null) {
            try {
                return mWindowManager.getCurrentWindowMetrics().getBounds().width();
            } catch (RuntimeException ignored) {
            }
        }
        return mContext.getResources().getDisplayMetrics().widthPixels;
    }

    private int displayHeight() {
        if (mRoot != null && mRoot.getHeight() > 0) {
            return mRoot.getHeight();
        }
        if (mWindowManager != null) {
            try {
                return mWindowManager.getCurrentWindowMetrics().getBounds().height();
            } catch (RuntimeException ignored) {
            }
        }
        return mContext.getResources().getDisplayMetrics().heightPixels;
    }

    private static int measuredWidth(View view) {
        if (view.getWidth() > 0) {
            return view.getWidth();
        }
        view.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
        return view.getMeasuredWidth();
    }

    private static int measuredHeight(View view) {
        if (view.getHeight() > 0) {
            return view.getHeight();
        }
        view.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
        return view.getMeasuredHeight();
    }

    private static final class IslandPresentation {
        final boolean expanded;
        final String leftText;
        final String rightText;
        final String bodyText;
        final boolean showActions;
        final boolean showTabs;
        final boolean showStopWatcherAction;
        final int accentColor;
        final int maxBodyLines;

        private IslandPresentation(boolean expanded, String leftText, String rightText,
                String bodyText, boolean showActions, boolean showTabs,
                boolean showStopWatcherAction, int accentColor, int maxBodyLines) {
            this.expanded = expanded;
            this.leftText = leftText;
            this.rightText = rightText;
            this.bodyText = bodyText;
            this.showActions = showActions;
            this.showTabs = showTabs;
            this.showStopWatcherAction = showStopWatcherAction;
            this.accentColor = accentColor;
            this.maxBodyLines = maxBodyLines;
        }

        static IslandPresentation compact(String leftText, String rightText, int accentColor) {
            return new IslandPresentation(false, safe(leftText), safe(rightText), "",
                    false, false, false, accentColor, 1);
        }

        static IslandPresentation expanded(String leftText, String bodyText,
                boolean showActions, int maxBodyLines) {
            return new IslandPresentation(true, safe(leftText), "", safe(bodyText),
                    showActions, false, false, 0xfff4f7f8, maxBodyLines);
        }

        static IslandPresentation expandedStatus(String leftText, String bodyText,
                boolean showTabs, boolean showStopWatcherAction, int maxBodyLines) {
            return new IslandPresentation(true, safe(leftText), "", safe(bodyText),
                    false, showTabs, showStopWatcherAction, 0xfff4f7f8, maxBodyLines);
        }

        private static String safe(String text) {
            return text == null ? "" : text;
        }
    }

    private void showAction(String label) {
        if (mActionLabel == null) {
            return;
        }
        positionActionLabel();
        mActionLabel.setText(label == null || label.isEmpty() ? "Working" : label);
        mActionLabel.animate().cancel();
        mActionLabel.setAlpha(1f);
        mActionLabel.animate().alpha(0f).setStartDelay(850).setDuration(220).start();
    }

    private void moveDotNow(float x, float y) {
        if (mDot == null) {
            return;
        }
        showPointerDot();
        FrameLayout.LayoutParams params = (FrameLayout.LayoutParams) mDot.getLayoutParams();
        params.leftMargin = Math.max(0, Math.round(x) - CURSOR_SIZE / 2);
        params.topMargin = Math.max(0, Math.round(y) - CURSOR_SIZE / 2);
        mDot.setLayoutParams(params);
    }

    private void pulseDot() {
        if (mDot == null) {
            return;
        }
        showPointerDot();
        mDot.animate().cancel();
        mDot.animate().scaleX(1.35f).scaleY(1.35f).setDuration(80).withEndAction(
                () -> {
                    if (mDot != null) {
                        mDot.animate().scaleX(1f).scaleY(1f).setDuration(120).start();
                    }
                }).start();
    }

    private void addRipple(float x, float y, boolean longPress) {
        if (mRoot == null) {
            return;
        }
        View ripple = new View(mContext);
        ripple.setBackground(rippleBackground(longPress));
        ripple.setAlpha(0.9f);
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(RIPPLE_SIZE, RIPPLE_SIZE);
        params.leftMargin = Math.max(0, Math.round(x) - RIPPLE_SIZE / 2);
        params.topMargin = Math.max(0, Math.round(y) - RIPPLE_SIZE / 2);
        mRoot.addView(ripple, params);
        ripple.setScaleX(0.25f);
        ripple.setScaleY(0.25f);
        ripple.animate().scaleX(longPress ? 1.45f : 1.15f)
                .scaleY(longPress ? 1.45f : 1.15f)
                .alpha(0f)
                .setDuration(longPress ? 520 : 320)
                .withEndAction(() -> removeTransientView(ripple))
                .start();
    }

    private void addSwipeTrail(float startX, float startY, float endX, float endY) {
        if (mRoot == null) {
            return;
        }
        float dx = endX - startX;
        float dy = endY - startY;
        int length = Math.max(48, Math.round((float) Math.hypot(dx, dy)));
        View trail = new View(mContext);
        trail.setBackground(trailBackground());
        trail.setAlpha(0.85f);
        FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(length, 10);
        params.leftMargin = Math.round((startX + endX) / 2f - length / 2f);
        params.topMargin = Math.round((startY + endY) / 2f - 5);
        mRoot.addView(trail, params);
        trail.setRotation((float) Math.toDegrees(Math.atan2(dy, dx)));
        trail.animate().alpha(0f).setStartDelay(320).setDuration(260)
                .withEndAction(() -> removeTransientView(trail)).start();
    }

    private void removeTransientView(View view) {
        if (mRoot == null || view == null) {
            return;
        }
        try {
            mRoot.removeView(view);
        } catch (RuntimeException ignored) {
        }
    }

    private void clearTransientViews() {
        if (mRoot == null) {
            return;
        }
        for (int i = mRoot.getChildCount() - 1; i >= 0; i--) {
            View child = mRoot.getChildAt(i);
            if (child != mGlowView && child != mActionLabel && child != mDot) {
                child.animate().cancel();
                mRoot.removeViewAt(i);
            }
        }
        if (mActionLabel != null) {
            mActionLabel.animate().cancel();
            mActionLabel.setAlpha(0f);
        }
        if (mDot != null) {
            mDot.animate().cancel();
            mDot.setScaleX(1f);
            mDot.setScaleY(1f);
        }
    }

    private void removePointerLayer() {
        if (mRoot == null || mWindowManager == null) {
            return;
        }
        clearTransientViews();
        try {
            mWindowManager.removeView(mRoot);
        } catch (RuntimeException ignored) {
        }
        mRoot = null;
        mDot = null;
        mGlowView = null;
        mActionLabel = null;
    }

    private static void removeAllPointerLayers() {
        ArrayList<PointerOverlayController> controllers;
        synchronized (sControllers) {
            controllers = new ArrayList<>(sControllers);
        }
        for (PointerOverlayController controller : controllers) {
            controller.mHandler.post(controller::removePointerLayer);
        }
    }

    private void showPointerDot() {
        if (mDot != null) {
            mDot.setVisibility(View.VISIBLE);
        }
    }

    private void hidePointerDot() {
        if (mDot != null) {
            mDot.animate().cancel();
            mDot.setVisibility(View.GONE);
        }
    }

    private void launchVoiceCapture() {
        Intent intent = new Intent(mContext, AgentControlActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        intent.putExtra(AgentControlActivity.EXTRA_START_VOICE, true);
        try {
            mContext.startActivity(intent);
        } catch (RuntimeException ignored) {
        }
    }

    private void launchStopAgent() {
        Intent intent = new Intent(mContext, AgentControlActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        intent.putExtra(AgentControlActivity.EXTRA_STOP_AGENT, true);
        try {
            mContext.startActivity(intent);
        } catch (RuntimeException ignored) {
        }
    }

    private GradientDrawable chipBackground(boolean yoloActive, boolean attachedToPanel) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(0xff000000);
        float radius = ISLAND_HEIGHT / 2f;
        if (attachedToPanel) {
            drawable.setCornerRadii(new float[] {
                    radius, radius,
                    radius, radius,
                    0f, 0f,
                    0f, 0f
            });
        } else {
            drawable.setCornerRadius(radius);
        }
        if (yoloActive) {
            String runtime = selectedRemoteRuntime();
            drawable.setStroke(3, runtime.isEmpty()
                    ? YOLO_ACCENT : runtimeAccent(runtime, YOLO_ACCENT));
        }
        return drawable;
    }

    private static GradientDrawable cursorBackground() {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setShape(GradientDrawable.OVAL);
        drawable.setColor(OPENPHONE_ACCENT);
        drawable.setStroke(4, 0xdd101418);
        return drawable;
    }

    private static GradientDrawable actionBackground() {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(0xee72e0c4);
        drawable.setCornerRadius(28);
        drawable.setStroke(2, 0xaa101418);
        return drawable;
    }

    private static GradientDrawable tabBackground(boolean selected) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(selected ? 0xfff4f7f8 : 0x22ffffff);
        drawable.setCornerRadius(22);
        if (!selected) {
            drawable.setStroke(1, 0x33ffffff);
        }
        return drawable;
    }

    private static GradientDrawable chatBubbleBackground(boolean fromUser) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fromUser ? 0xff1f5eff : 0xff20272d);
        drawable.setCornerRadius(24);
        if (!fromUser) {
            drawable.setStroke(1, 0x33ffffff);
        }
        return drawable;
    }

    private static GradientDrawable runtimeCardBackground(String runtime, boolean selected) {
        GradientDrawable drawable = new GradientDrawable();
        int accent = runtimeAccent(runtime, OPENPHONE_ACCENT);
        drawable.setColor(selected ? accent : 0x1affffff);
        drawable.setCornerRadius(30);
        drawable.setStroke(selected ? 0 : 1, selected ? accent : 0x44ffffff);
        return drawable;
    }

    private static String runtimeCardTitle(String runtime, String label) {
        String cleanLabel = label == null || label.trim().isEmpty()
                ? RuntimeRegistry.label(runtime) : label.trim();
        return runtimeGlyph(runtime) + " " + cleanLabel;
    }

    private static String runtimeGlyph(String runtime) {
        String clean = normalizeRuntime(runtime);
        if (AssistantBrainConfig.OPENCLAW.equals(clean)) {
            return "🦞";
        }
        if (RuntimeRegistry.HERMES.equals(clean)) {
            return "H";
        }
        if (AssistantBrainConfig.BUILTIN.equals(clean)) {
            return "⚡";
        }
        return "◉";
    }

    private static int runtimeAccent(String runtime, int fallback) {
        String clean = normalizeRuntime(runtime);
        if (AssistantBrainConfig.OPENCLAW.equals(clean)) {
            return OPENCLAW_ACCENT;
        }
        if (RuntimeRegistry.HERMES.equals(clean)) {
            return 0xff5b6ee1;
        }
        if (AssistantBrainConfig.BUILTIN.equals(clean)) {
            return OPENPHONE_ACCENT;
        }
        return fallback;
    }

    private static int runtimeSelectedTextColor(String runtime) {
        return runtimeAccentNeedsLightText(runtime) ? 0xffffffff : 0xff101418;
    }

    private static int runtimeSelectedSecondaryTextColor(String runtime) {
        return runtimeAccentNeedsLightText(runtime) ? 0xeeffffff : 0xdd101418;
    }

    private static boolean runtimeAccentNeedsLightText(String runtime) {
        String clean = normalizeRuntime(runtime);
        return AssistantBrainConfig.OPENCLAW.equals(clean)
                || RuntimeRegistry.HERMES.equals(clean);
    }

    private static GradientDrawable rippleBackground(boolean longPress) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setShape(GradientDrawable.OVAL);
        drawable.setColor(0x2272e0c4);
        drawable.setStroke(longPress ? 6 : 4, longPress ? 0xffffd166 : 0xff72e0c4);
        return drawable;
    }

    private static GradientDrawable trailBackground() {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(0xcc72e0c4);
        drawable.setCornerRadius(12);
        return drawable;
    }

    private static final class GlowBorderView extends View {
        private final Paint mBlurPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint mCorePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF mBounds = new RectF();
        private float mShift;

        GlowBorderView(Context context) {
            super(context);
            setWillNotDraw(false);
            setLayerType(View.LAYER_TYPE_SOFTWARE, null);
            mBlurPaint.setStyle(Paint.Style.STROKE);
            mBlurPaint.setStrokeWidth(GLOW_STROKE_WIDTH);
            mBlurPaint.setStrokeCap(Paint.Cap.ROUND);
            mBlurPaint.setStrokeJoin(Paint.Join.ROUND);
            mBlurPaint.setMaskFilter(new BlurMaskFilter(GLOW_BLUR_RADIUS,
                    BlurMaskFilter.Blur.NORMAL));

            mCorePaint.setStyle(Paint.Style.STROKE);
            mCorePaint.setStrokeWidth(GLOW_CORE_STROKE_WIDTH);
            mCorePaint.setStrokeCap(Paint.Cap.ROUND);
            mCorePaint.setStrokeJoin(Paint.Join.ROUND);
            mCorePaint.setAlpha(255);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            int width = getWidth();
            int height = getHeight();
            if (width <= 0 || height <= 0) {
                return;
            }
            Shader shader = gradient(width, height);
            mBlurPaint.setShader(shader);
            mCorePaint.setShader(shader);
            float inset = GLOW_EDGE_INSET;
            mBounds.set(inset, inset, width - inset, height - inset);
            float radius = displayCornerRadius(width, height);
            canvas.drawRoundRect(mBounds, radius, radius, mBlurPaint);
            canvas.drawRoundRect(mBounds, radius, radius, mCorePaint);

            mShift = (mShift + 0.008f) % 1f;
            postInvalidateDelayed(16);
        }

        private Shader gradient(int width, int height) {
            int[] colors = {
                    Color.argb(255, 93, 220, 255),
                    Color.argb(255, 148, 108, 255),
                    Color.argb(255, 255, 86, 168),
                    Color.argb(255, 255, 204, 108),
                    Color.argb(255, 93, 220, 255)
            };
            float startX = -width * 0.4f + width * 1.8f * mShift;
            float endX = startX + width * 1.2f;
            return new LinearGradient(startX, 0, endX, height, colors, null,
                    Shader.TileMode.MIRROR);
        }

        private float displayCornerRadius(int width, int height) {
            float fallback = Math.min(145, Math.min(width, height) * 0.135f);
            if (getRootWindowInsets() == null) {
                return Math.max(1f, fallback - GLOW_CORE_STROKE_WIDTH / 2f);
            }
            float radius = 0f;
            int[] positions = {
                    RoundedCorner.POSITION_TOP_LEFT,
                    RoundedCorner.POSITION_TOP_RIGHT,
                    RoundedCorner.POSITION_BOTTOM_RIGHT,
                    RoundedCorner.POSITION_BOTTOM_LEFT
            };
            for (int position : positions) {
                RoundedCorner corner = getRootWindowInsets().getRoundedCorner(position);
                if (corner != null) {
                    radius = Math.max(radius, corner.getRadius());
                }
            }
            if (radius <= 0f) {
                radius = fallback;
            }
            return Math.max(1f, (radius * 1.40f) - GLOW_CORE_STROKE_WIDTH / 2f);
        }
    }
}
