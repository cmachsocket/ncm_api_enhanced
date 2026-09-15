// android/src/main/kotlin/to/holepunch/ncm_enhanced/NcmBareBridge.kt
//
// Android platform plugin for ncm_api_enhanced.
//
// Implements FlutterPlugin so the Flutter build toolchain wires it up
// automatically when this package is added to a host app's
// pubspec.yaml dependencies — no host-app glue required.
//
// Wire protocol on the Dart side (see lib/src/mobile_bridge.dart):
//
//   MethodChannel("ncm_bridge/methods")
//     "start"      → loads dist/ncm.bundle into a bare Worklet
//                    and opens an IPC channel.
//     "write"      → forwards NDJSON bytes to the Worklet's IPC.
//     "shutdown"   → terminates the Worklet.
//     "isRunning"  → returns Boolean.
//     "dataDir"    → returns the host app's filesDir.
//
//   EventChannel("ncm_bridge/events")
//     Emits:
//       { "type": "ready" }
//       { "type": "stdout", "data": "<line>" }
//       { "type": "stderr", "data": "<line>" }
//       { "type": "fatal",  "data": "<message>" }
//
// The Worklet speaks NDJSON over IPC — the same protocol used by
// the bridge.js consumer.

package to.holepunch.ncm_enhanced

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import to.holepunch.bare.kit.IPC
import to.holepunch.bare.kit.Worklet
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

class NcmBareBridge : FlutterPlugin, ActivityAware {

    companion object {
        private const val TAG = "NcmBareBridge"

        private const val METHOD_CHANNEL = "ncm_bridge/methods"
        private const val EVENT_CHANNEL = "ncm_bridge/events"

        /*
         * Keep these in sync with:
         *
         *   pubspec.yaml
         *   mobile_bridge.dart
         */
        // Flutter packages declared assets at
        //   assets/flutter_assets/packages/<package_name>/<pubspec-relative-path>
        // inside the APK. Our pubspec.yaml declares
        //   assets/bridge/dist/
        // so the bare bundle lives at
        //   assets/flutter_assets/packages/ncm_api_enhanced/assets/bridge/dist/ncm.bundle
        // — read only, locked in the APK, inaccessible to Dart's File API.
        //
        // Verified with `unzip -l app-arm64-v8a-release.apk | grep ncm.bundle`:
        //   assets/flutter_assets/packages/ncm_api_enhanced/assets/bridge/dist/ncm.bundle
        //
        // We mirror that exact layout under <filesDir>, dropping only the
        // APK's leading `assets/` directory (which is an AAPT packaging
        // detail, not part of the asset name AssetManager exposes). The
        // Dart side (mobile_bridge.dart::_tryResolveBridgeRootFromDataDir)
        // probes <filesDir>/flutter_assets/<...>/ncm.bundle and is kept in
        // sync with these constants.
        private const val ASSET_BUNDLE_PATH =
            "flutter_assets/packages/ncm_api_enhanced/assets/bridge/dist/ncm.bundle"

        private const val EXTRACTED_ROOT =
            "flutter_assets/packages/ncm_api_enhanced/assets/bridge"

        private const val EXTRACTED_BUNDLE =
            "flutter_assets/packages/ncm_api_enhanced/assets/bridge/dist/ncm.bundle"

        /*
         * Defensive limit for a single NDJSON message.
         *
         * Normal NCM RPC messages are much smaller than this. The limit
         * prevents a broken/malicious peer from growing an unbounded
         * in-memory line buffer.
         */
        private const val MAX_NDJSON_LINE_BYTES = 8 * 1024 * 1024

        private const val COPY_BUFFER_SIZE = 64 * 1024
    }

    // ---------------------------------------------------------------------------
    // Flutter state
    // ---------------------------------------------------------------------------

    @Volatile
    private var appContext: Context? = null

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    // ---------------------------------------------------------------------------
    // Bare state
    // ---------------------------------------------------------------------------

    @Volatile
    private var worklet: Worklet? = null

    @Volatile
    private var ipc: IPC? = null

    /*
     * Protects Worklet/IPC lifecycle transitions.
     *
     * MethodChannel callbacks normally arrive serially, but IPC callbacks
     * execute independently, so lifecycle state must still be treated as
     * concurrent state.
     */
    private val lifecycleLock = Any()

    // ---------------------------------------------------------------------------
    // IPC write queue
    // ---------------------------------------------------------------------------

    /*
     * IPC.write(ByteBuffer, callback) already handles partial writes in
     * Bare Kit. We only need to serialize complete logical messages so
     * multiple Dart calls cannot overtake each other.
     */
    private val writeLock = Any()

    private val writeQueue = ArrayDeque<ByteBuffer>()

    private var writeInFlight = false

    // ---------------------------------------------------------------------------
    // IPC read framing
    // ---------------------------------------------------------------------------

    /*
     * IPC is a byte stream. One read() is NOT guaranteed to correspond to
     * one NDJSON line.
     *
     * We therefore buffer raw UTF-8 bytes until '\n'. Keeping bytes instead
     * of decoded Strings also means a multi-byte UTF-8 character can safely
     * cross an IPC chunk boundary.
     */
    private val readBuffer = ByteArrayOutputStream()

    // ---------------------------------------------------------------------------
    // Asset extraction
    // ---------------------------------------------------------------------------

    /*
     * Extraction is deliberately asynchronous so the first 35 MB-ish bundle
     * copy does not execute on the Flutter/Android main thread.
     *
     * Unlike the previous AtomicBoolean + Future + spin design, the Future
     * itself is the single synchronization point.
     */
    private val extractionLock = Any()

    private var extractionExecutor: ExecutorService? = null

    private var extractionFuture: Future<*>? = null

    // ---------------------------------------------------------------------------
    // FlutterPlugin lifecycle
    // ---------------------------------------------------------------------------

    override fun onAttachedToEngine(
        binding: FlutterPlugin.FlutterPluginBinding,
    ) {
        appContext = binding.applicationContext

        synchronized(extractionLock) {
            ensureExtractionExecutorLocked()
        }

        methodChannel = MethodChannel(
            binding.binaryMessenger,
            METHOD_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(::onMethodCall)
        }

        eventChannel = EventChannel(
            binding.binaryMessenger,
            EVENT_CHANNEL,
        ).also { channel ->
            channel.setStreamHandler(
                object : EventChannel.StreamHandler {

                    override fun onListen(
                        arguments: Any?,
                        sink: EventChannel.EventSink,
                    ) {
                        eventSink = sink
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                },
            )
        }
    }

    override fun onDetachedFromEngine(
        binding: FlutterPlugin.FlutterPluginBinding,
    ) {
        stopWorklet()

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null

        eventChannel?.setStreamHandler(null)
        eventChannel = null

        eventSink = null

        synchronized(extractionLock) {
            extractionFuture = null

            extractionExecutor?.shutdownNow()
            extractionExecutor = null
        }

        appContext = null
    }

    // ---------------------------------------------------------------------------
    // ActivityAware
    // ---------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        // No Activity reference is required.
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // No Activity reference is required.
    }

    override fun onReattachedToActivityForConfigChanges(
        binding: ActivityPluginBinding,
    ) {
        // No Activity reference is required.
    }

    override fun onDetachedFromActivity() {
        // No Activity reference is required.
    }

    // ---------------------------------------------------------------------------
    // Method dispatch
    // ---------------------------------------------------------------------------

    private fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "start" -> handleStart(result)
            "write" -> handleWrite(call, result)
            "shutdown" -> handleShutdown(result)
            "isRunning" -> result.success(worklet != null)
            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Start
    //
    // The Dart side calls `methods.start()` with no arguments. The Kotlin
    // shim is the single owner of:
    //
    //   1. Knowing where the bridge assets live inside the APK
    //      (AssetManager — read-only).
    //   2. Materializing them into a writable directory (<filesDir>).
    //   3. Resolving the on-disk path of ncm.bundle.
    //   4. Loading it into a Worklet and opening IPC.
    //
    // Dart used to do (3) by probing <filesDir>/flutter_assets/... on its
    // own. That made Dart aware of Android's APK asset layout, broke every
    // time the layout changed (the `packages/<pkg>/` prefix in particular),
    // and added a redundant MethodChannel round-trip. Self-contained: the
    // Dart side now treats start() as a black box.
    // -------------------------------------------------------------------------

    private fun handleStart(result: MethodChannel.Result) {
        synchronized(lifecycleLock) {
            if (worklet != null) {
                result.error(
                    "already_started",
                    "Worklet is already running",
                    null,
                )
                return
            }
        }

        try {
            val context = appContext
                ?: throw IllegalStateException(
                    "handleStart: plugin is not attached to an engine",
                )

            /*
             * Block until the bridge assets have been materialized into
             * <filesDir>. awaitExtraction() is idempotent and cached, so
             * every start() after the first pays zero I/O.
             */
            awaitExtraction()

            /*
             * The extraction target mirrors the APK asset layout under
             * <filesDir>, dropping the leading `assets/` directory that
             * is an AAPT packaging detail. See extractBridgeAssets().
             */
            val bundleFile = File(context.filesDir, EXTRACTED_BUNDLE)

            if (!bundleFile.isFile) {
                /*
                 * Should be unreachable: extractBridgeAssets() either
                 * produced a complete file or threw. Kept as a defensive
                 * check because the cache check (size match) is the only
                 * thing standing between us and an incomplete file.
                 */
                result.error(
                    "bundle_not_found",
                    "extraction target missing after awaitExtraction: " +
                            bundleFile.absolutePath,
                    null,
                )
                return
            }

            /*
             * Worklet.start() accepts a ByteBuffer.
             *
             * This is the existing contract used by the package. The bundle
             * itself is already on disk, so this allocation is limited to the
             * actual Bare bundle passed to Worklet and does not affect the
             * APK asset extraction path.
             */
            val sourceBytes = bundleFile.readBytes()

            val source = ByteBuffer
                .allocateDirect(sourceBytes.size)
                .apply {
                    put(sourceBytes)
                    flip()
                }

            val options = Worklet.Options()
                .memoryLimit(24 * 1024 * 1024)

            val newWorklet = Worklet(options)

            try {
                /*
                 * Keep the .bundle filename semantics expected by Bare/bare-pack.
                 */
                newWorklet.start(
                    "/app.bundle",
                    source,
                    null,
                )

                val newIpc = IPC(newWorklet)

                synchronized(lifecycleLock) {
                    /*
                     * A shutdown could theoretically race with setup. Do not publish
                     * the Worklet unless the plugin is still detached from no one.
                     */
                    if (worklet != null || ipc != null) {
                        newIpc.close()
                        newWorklet.terminate()

                        result.error(
                            "already_started",
                            "Worklet was started concurrently",
                            null,
                        )
                        return
                    }

                    worklet = newWorklet
                    ipc = newIpc
                }

                /*
                 * Read callback.
                 *
                 * Bare Kit's polling IPC API can deliver arbitrary-sized chunks,
                 * so drainIpc() performs NDJSON framing itself.
                 */
                newIpc.readable {
                    drainIpc(newIpc)
                }

                /*
                 * We use the asynchronous write API from Bare Kit.
                 *
                 * Partial writes are handled by Bare Kit itself; this callback is
                 * only used by our queue to advance to the next logical message.
                 */
                newIpc.writable(null)

                emit(
                    mapOf(
                        "type" to "ready",
                    ),
                )

                result.success(null)
            } catch (e: Throwable) {
                try {
                    newWorklet.terminate()
                } catch (_: Throwable) {
                    // Best effort.
                }

                throw e
            }
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)

            result.error(
                "start_failed",
                e.message ?: e.javaClass.simpleName,
                null,
            )
        }
    }

    // ---------------------------------------------------------------------------
    // Write
    // ---------------------------------------------------------------------------

    private fun handleWrite(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val bytes = call.argument<ByteArray>("bytes")

        if (bytes == null) {
            result.error(
                "invalid_args",
                "bytes is required",
                null,
            )
            return
        }

        val currentIpc = ipc

        if (currentIpc == null) {
            result.error(
                "not_running",
                "Worklet is not running",
                null,
            )
            return
        }

        try {
            /*
             * The Dart side already speaks NDJSON, so preserve the bytes exactly.
             *
             * We intentionally do not decode/re-encode here. This avoids:
             *
             *   Dart UTF-8
             *       ↓
             *   String
             *       ↓
             *   UTF-8
             *
             * and therefore avoids corrupting a partial UTF-8 write.
             */
            enqueueWrite(
                currentIpc,
                ByteBuffer
                    .allocateDirect(bytes.size)
                    .apply {
                        put(bytes)
                        flip()
                    },
            )

            result.success(null)
        } catch (e: Throwable) {
            Log.e(TAG, "write failed", e)

            result.error(
                "write_failed",
                e.message ?: e.javaClass.simpleName,
                null,
            )
        }
    }

    private fun enqueueWrite(
        targetIpc: IPC,
        buffer: ByteBuffer,
    ) {
        var startNow = false

        synchronized(writeLock) {
            /*
             * Do not enqueue data for an obsolete IPC instance.
             */
            if (ipc !== targetIpc) {
                throw IllegalStateException("IPC is no longer running")
            }

            writeQueue.addLast(buffer)

            if (!writeInFlight) {
                writeInFlight = true
                startNow = true
            }
        }

        if (startNow) {
            startNextWrite(targetIpc)
        }
    }

    private fun startNextWrite(
        targetIpc: IPC,
    ) {
        val next: ByteBuffer?

        synchronized(writeLock) {
            /*
             * If the IPC instance has already been replaced/closed, drop the
             * pending queue.
             */
            if (ipc !== targetIpc) {
                writeQueue.clear()
                writeInFlight = false
                return
            }

            next = writeQueue.pollFirst()

            if (next == null) {
                writeInFlight = false
                return
            }
        }

        try {
            /*
             * Bare Kit's implementation internally retries partial writes via
             * the writable callback and invokes this callback only after the
             * complete ByteBuffer has been written.
             */
            targetIpc.write(next) { exception ->
                mainHandler.post {
                    if (exception != null) {
                        Log.e(TAG, "IPC write failed", exception)

                        synchronized(writeLock) {
                            writeQueue.clear()
                            writeInFlight = false
                        }

                        emit(
                            mapOf(
                                "type" to "fatal",
                                "data" to (
                                        exception.message
                                            ?: exception.javaClass.simpleName
                                        ),
                            ),
                        )

                        return@post
                    }

                    startNextWrite(targetIpc)
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "IPC write threw", e)

            synchronized(writeLock) {
                writeQueue.clear()
                writeInFlight = false
            }

            emit(
                mapOf(
                    "type" to "fatal",
                    "data" to (e.message ?: e.javaClass.simpleName),
                ),
            )
        }
    }

    // ---------------------------------------------------------------------------
    // IPC read / NDJSON framing
    // ---------------------------------------------------------------------------

    private fun drainIpc(
        sourceIpc: IPC,
    ) {
        /*
         * Ignore callbacks belonging to an IPC instance that has already
         * been replaced by shutdown/restart.
         */
        if (ipc !== sourceIpc) {
            return
        }

        while (true) {
            val data = try {
                sourceIpc.read()
            } catch (e: Throwable) {
                Log.e(TAG, "IPC read failed", e)

                emit(
                    mapOf(
                        "type" to "fatal",
                        "data" to (e.message ?: e.javaClass.simpleName),
                    ),
                )

                return
            } ?: break

            consumeReadChunk(data)
        }
    }

    private fun consumeReadChunk(
        data: ByteBuffer,
    ) {
        /*
         * Copy the chunk into a local byte array.
         *
         * We then scan for '\n'. We deliberately decode only complete lines,
         * which makes UTF-8 safe even when a multibyte code point is split
         * between two IPC chunks.
         */
        val bytes = ByteArray(data.remaining())
        data.get(bytes)

        var start = 0

        for (index in bytes.indices) {
            if (bytes[index].toInt() == '\n'.code) {
                appendReadBytes(bytes, start, index - start)
                emitReadLine()
                start = index + 1
            }
        }

        if (start < bytes.size) {
            appendReadBytes(
                bytes,
                start,
                bytes.size - start,
            )
        }
    }

    private fun appendReadBytes(
        bytes: ByteArray,
        offset: Int,
        length: Int,
    ) {
        if (length <= 0) {
            return
        }

        if (
            readBuffer.size() + length >
            MAX_NDJSON_LINE_BYTES
        ) {
            readBuffer.reset()

            emit(
                mapOf(
                    "type" to "fatal",
                    "data" to "NDJSON line exceeds ${MAX_NDJSON_LINE_BYTES} bytes",
                ),
            )

            throw IllegalStateException(
                "NDJSON line exceeds $MAX_NDJSON_LINE_BYTES bytes",
            )
        }

        readBuffer.write(
            bytes,
            offset,
            length,
        )
    }

    private fun emitReadLine() {
        if (readBuffer.size() == 0) {
            return
        }

        var line = String(
            readBuffer.toByteArray(),
            StandardCharsets.UTF_8,
        )

        readBuffer.reset()

        /*
         * NDJSON commonly permits CRLF even though the bridge normally emits LF.
         */
        if (line.endsWith('\r')) {
            line = line.dropLast(1)
        }

        if (line.isNotEmpty()) {
            emit(
                mapOf(
                    "type" to "stdout",
                    "data" to line,
                ),
            )
        }
    }

    // ---------------------------------------------------------------------------
    // Shutdown
    // ---------------------------------------------------------------------------

    private fun handleShutdown(
        result: MethodChannel.Result,
    ) {
        try {
            stopWorklet()
            result.success(null)
        } catch (e: Throwable) {
            Log.e(TAG, "shutdown failed", e)

            result.error(
                "shutdown_failed",
                e.message ?: e.javaClass.simpleName,
                null,
            )
        }
    }

    private fun stopWorklet() {
        val oldIpc: IPC?
        val oldWorklet: Worklet?

        synchronized(lifecycleLock) {
            oldIpc = ipc
            oldWorklet = worklet

            ipc = null
            worklet = null
        }

        synchronized(writeLock) {
            writeQueue.clear()
            writeInFlight = false
        }

        readBuffer.reset()

        try {
            oldIpc?.writable(null)
        } catch (_: Throwable) {
            // Best effort.
        }

        try {
            oldIpc?.readable(null)
        } catch (_: Throwable) {
            // Best effort.
        }

        try {
            oldIpc?.close()
        } catch (e: Throwable) {
            Log.w(TAG, "IPC close failed", e)
        }

        try {
            oldWorklet?.terminate()
        } catch (e: Throwable) {
            Log.w(TAG, "Worklet terminate failed", e)
        }
    }

    // -------------------------------------------------------------------------
    // dataDir — removed.
    //
    // The previous design leaked the host app's filesDir into Dart so Dart
    // could probe for the extracted bridge assets itself. The Kotlin shim is
    // now the single owner of asset extraction and bundle path resolution,
    // so Dart never needs to know the filesDir path. See handleStart().
    // -------------------------------------------------------------------------
    // ---------------------------------------------------------------------------
    // EventChannel
    // ---------------------------------------------------------------------------

    private fun emit(
        event: Map<String, Any?>,
    ) {
        /*
         * EventSink is expected to be used on the Flutter main thread.
         *
         * IPC callbacks may run on another thread, so always marshal through
         * the main Handler.
         */
        mainHandler.post {
            val sink = eventSink ?: return@post

            try {
                sink.success(event)
            } catch (e: Throwable) {
                Log.w(
                    TAG,
                    "eventSink.success failed",
                    e,
                )
            }
        }
    }

    // ---------------------------------------------------------------------------
    // Asset extraction
    // ---------------------------------------------------------------------------

    private fun ensureExtractionExecutorLocked() {
        val existing = extractionExecutor

        if (
            existing != null &&
            !existing.isShutdown &&
            !existing.isTerminated
        ) {
            return
        }

        extractionExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(
                runnable,
                "ncm-bridge-extractor",
            ).apply {
                isDaemon = true
            }
        }
    }

    private fun awaitExtraction() {
        val future: Future<*>

        synchronized(extractionLock) {
            ensureExtractionExecutorLocked()

            val existing = extractionFuture

            if (existing != null) {
                future = existing
            } else {
                val executor = extractionExecutor
                    ?: throw IllegalStateException(
                        "Extraction executor is unavailable",
                    )

                future = executor.submit<Unit> {
                    extractBridgeAssets()
                }

                extractionFuture = future
            }
        }

        try {
            /*
             * The MethodChannel callback waits here, but the actual 35 MB copy
             * happens on the dedicated extraction executor.
             */
            future.get()
        } catch (e: Throwable) {
            /*
             * Allow a later start() to retry extraction after a failed attempt.
             */
            synchronized(extractionLock) {
                if (extractionFuture === future) {
                    extractionFuture = null
                }
            }

            throw e
        }
    }

    private fun extractBridgeAssets() {
        val context = appContext
            ?: throw IllegalStateException(
                "extractBridgeAssets: plugin is not attached to an engine",
            )

        val assets = context.assets
        val filesDir = context.filesDir

        val rootDir = File(
            filesDir,
            EXTRACTED_ROOT,
        )

        if (!rootDir.exists() && !rootDir.mkdirs()) {
            throw IllegalStateException(
                "cannot create ${rootDir.absolutePath}",
            )
        }

        val distDir = File(
            rootDir,
            "dist",
        )

        if (!distDir.exists() && !distDir.mkdirs()) {
            throw IllegalStateException(
                "cannot create ${distDir.absolutePath}",
            )
        }

        val target = File(
            filesDir,
            EXTRACTED_BUNDLE,
        )

        /*
         * Cache check.
         *
         * We deliberately do not validate against the source asset size
         * here. `AssetManager.openFd()` exposes the asset length but
         * only for assets stored uncompressed in the APK — AAPT's
         * compression decision is a build-tool choice that this plugin
         * should not couple to. A future Flutter / AAPT version that
         * flips the default to compressed would silently break any
         * code path that assumes `openFd()` works.
         *
         * The cache is therefore validated by (a) existence and (b) a
         * non-zero size. The atomic `.tmp → target` rename below
         * guarantees a partial write can never produce a valid-looking
         * cache hit.
         */
        if (target.isFile && target.length() > 0) {
            Log.i(
                TAG,
                "extract: cache hit " +
                        "${target.absolutePath} " +
                        "(${target.length()} bytes)",
            )

            return
        }

        Log.i(
            TAG,
            "extract: copying " +
                    "$ASSET_BUNDLE_PATH → ${target.absolutePath}",
        )

        /*
         * Never write directly to the final bundle.
         *
         * A unique temporary filename also prevents an interrupted extraction
         * from colliding with a later plugin-engine instance.
         */
        val temp = File(
            target.parentFile,
            "${target.name}.tmp-${Thread.currentThread().id}",
        )

        try {

            assets.open(ASSET_BUNDLE_PATH).use { input ->

                FileOutputStream(temp).use { output ->
                    val buffer = ByteArray(COPY_BUFFER_SIZE)

                    while (true) {
                        val count = input.read(buffer)

                        if (count < 0) {
                            break
                        }

                        if (count > 0) {
                            output.write(
                                buffer,
                                0,
                                count,
                            )
                        }
                    }

                    output.flush()
                }
            }


            if (temp.length() == 0L) {
                throw IllegalStateException(
                    "extract: source asset '$ASSET_BUNDLE_PATH' " +
                            "yielded zero bytes — apk asset may be " +
                            "missing or unreadable",
                )
            }

            /*
             * Replace the final file only after the complete copy has been
             * verified.
             *
             *noinspection ResultOfMethodCallIgnored
             */
            if (
                target.exists() &&
                !target.delete()
            ) {
                throw IllegalStateException(
                    "extract: cannot replace ${target.absolutePath}",
                )
            }

            if (!temp.renameTo(target)) {
                throw IllegalStateException(
                    "extract: cannot rename " +
                            "${temp.absolutePath} → ${target.absolutePath}",
                )
            }

            Log.i(
                TAG,
                "extract: done " +
                        "${target.absolutePath} " +
                        "(${target.length()} bytes)",
            )
        } catch (e: Throwable) {
            /*
             * The temporary file is never exposed as the bundle path.
             */
            try {
                temp.delete()
            } catch (_: Throwable) {
                // Best effort.
            }

            throw e
        } finally {
            /*
             * Covers cancellation/exception paths where the copy failed before
             * reaching the explicit cleanup above.
             */
            if (temp.exists()) {
                try {
                    temp.delete()
                } catch (_: Throwable) {
                    // Best effort.
                }
            }
        }
    }
}
