package com.example.ncm_api_enhanced

import android.content.Context
import android.content.res.AssetManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flutter plugin that drives libnode.so (nodejs-mobile v18.20.4) on Android.
 *
 * Contract with Dart `MobileNcmBridge`:
 *   Method channel: "ncm_api_enhanced/bridge"
 *     start(Map)    → Map {ready: true}
 *     call(Map)     → null
 *     shutdown()    → null
 *   Event channel:  "ncm_api_enhanced/events"
 *     emits one event per NDJSON line emitted by bridge.js.
 */
class NcmNodeBridge : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG = "NcmNodeBridge"
        init {
            // libnode.so must load first; libncm_node_bridge.so resolves
            // node::Start from it at runtime.
            System.loadLibrary("node")
            System.loadLibrary("ncm_node_bridge")
        }
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ncm-node-io").apply { isDaemon = true }
    }
    private val started = AtomicBoolean(false)
    private var appContext: Context? = null

    // -------- FlutterPlugin --------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ncm_api_enhanced/bridge").apply {
            setMethodCallHandler(this@NcmNodeBridge)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "ncm_api_enhanced/events").apply {
            setStreamHandler(this@NcmNodeBridge)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null
        appContext = null
    }

    // -------- EventChannel.StreamHandler --------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // -------- JNI callbacks (invoked from C++ reader threads) --------

    /**
     * Called from native when bridge.js emits one stdout line. Forward to
     * Flutter on the main thread.
     */
    fun onStdoutLine(line: String) {
        mainHandler.post {
            val sink = eventSink ?: return@post
            try {
                sink.success(line)
            } catch (e: Throwable) {
                Log.w(TAG, "eventSink.success threw: $e")
            }
        }
    }

    fun onStderrLine(line: String) {
        val trimmed = line.trim { it == '\n' || it == '\r' }
        if (trimmed.isEmpty()) return
        mainHandler.post {
            val sink = eventSink ?: return@post
            // Wrap so Dart's `bridgeEvents` stream receives a log event
            // without parsing stderr content.
            try {
                sink.success(
                    """{"event":"log","data":{"level":"stderr","line":${jsonString(trimmed)}}}"""
                )
            } catch (e: Throwable) {
                Log.w(TAG, "eventSink.success (stderr) threw: $e")
            }
        }
    }

    // -------- MethodCallHandler --------

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> handleStart(result)
            "call"  -> handleCall(call, result)
            "shutdown" -> handleShutdown(result)
            else -> result.notImplemented()
        }
    }

    private fun handleStart(result: Result) {
        if (!started.compareAndSet(false, true)) {
            result.error("ALREADY_STARTED", "node bridge already started", null)
            return
        }
        val ctx = appContext
        if (ctx == null) {
            started.set(false)
            result.error("NO_CONTEXT", "plugin detached from engine", null)
            return
        }
        ioExecutor.execute {
            try {
                // 1. Wire JNI callbacks so C++ reader threads can find us.
                registerNativeCallbacks(this)

                // 2. Copy assets/ncm_bridge → filesDir/ncm_bridge.
                val dest = copyBridgeAssets(ctx)

                // 3. Spawn node. node::Start is blocking — it MUST run on
                //    a non-main thread. We invoke it on yet another
                //    worker thread and never wait for it.
                val bridgeJs = File(dest, "bridge.js").absolutePath
                val args = arrayOf("node", bridgeJs)
                val rc = startNode(args)
                if (rc != 0) {
                    started.set(false)
                    mainHandler.post {
                        result.error(
                            "NODE_START_FAILED",
                            "node::Start returned $rc",
                            null
                        )
                    }
                    return@execute
                }

                // Dart waits for {"event":"ready"} on the event channel
                // before its start() future resolves. Here we just
                // acknowledge that node was launched.
                mainHandler.post { result.success(mapOf("ready" to true)) }
            } catch (e: Throwable) {
                started.set(false)
                Log.e(TAG, "start failed", e)
                mainHandler.post {
                    result.error("START_FAILED", e.message, e.stackTraceToString())
                }
            }
        }
    }

    private fun handleCall(call: MethodCall, result: Result) {
        val id = call.argument<Int>("id")
        val method = call.argument<String>("method")
        @Suppress("UNCHECKED_CAST")
        val params = call.argument<Map<String, Any?>>("params")
        if (id == null || method == null) {
            result.error("BAD_ARGS", "id and method are required", null)
            return
        }
        if (!started.get()) {
            result.error("NOT_STARTED", "node bridge not started", null)
            return
        }
        ioExecutor.execute {
            try {
                val line = buildString {
                    append("{\"id\":").append(id)
                    append(",\"method\":").append(jsonString(method))
                    append(",\"params\":").append(jsonEncode(params ?: emptyMap()))
                    append("}\n")
                }
                writeToNodeStdin(line)
                result.success(null)
            } catch (e: Throwable) {
                result.error("WRITE_FAILED", e.message, null)
            }
        }
    }

    private fun handleShutdown(result: Result) {
        // Embedded node has no clean shutdown. Treat as advisory.
        started.set(false)
        result.success(null)
    }

    // -------- Native bridge helpers (JNI) --------

    private external fun registerNativeCallbacks(plugin: Any)
    private external fun startNode(args: Array<String>): Int
    private external fun requestNativeShutdown()
    private external fun writeToNodeStdin(line: String)

    // -------- Asset copy --------

    /**
     * Copy `assets/flutter_assets/bridge/` → `filesDir/ncm_bridge/`. The
     * `flutter_assets/` prefix is where Flutter writes asset bundle files
     * bundled via the `flutter.assets:` pubspec entry.
     */
    private fun copyBridgeAssets(ctx: Context): File {
        val dest = File(ctx.filesDir, "ncm_bridge")
        if (dest.exists()) dest.deleteRecursively()
        dest.mkdirs()
        copyAssetDir(ctx.assets, "flutter_assets/bridge", dest)
        return dest
    }

    @Throws(IOException::class)
    private fun copyAssetDir(assets: AssetManager, assetPath: String, outFile: File) {
        val names = assets.list(assetPath)
        if (names.isNullOrEmpty()) {
            // Leaf file.
            assets.open(assetPath).use { input ->
                val tmp = File(outFile.parentFile, outFile.name + ".tmp")
                FileOutputStream(tmp).use { os ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        os.write(buf, 0, n)
                    }
                }
                if (!tmp.renameTo(outFile)) {
                    throw IOException("rename ${tmp.path} -> ${outFile.path} failed")
                }
            }
            return
        }
        if (!outFile.exists() && !outFile.mkdirs()) {
            throw IOException("mkdir ${outFile.path} failed")
        }
        for (name in names) {
            copyAssetDir(assets, "$assetPath/$name", File(outFile, name))
        }
    }

    // -------- JSON helpers --------
    //
    // We hand-roll a tiny JSON encoder/escaper for the values that flow
    // through the IPC bridge. Avoiding org.json / kotlinx.serialization
    // keeps this plugin dependency-free.

    private fun jsonEncode(v: Any?): String = when (v) {
        null    -> "null"
        is Boolean -> v.toString()
        is Number  -> v.toString()
        is String  -> jsonString(v)
        is Map<*, *> -> {
            val sb = StringBuilder("{")
            var first = true
            for ((k, vv) in v) {
                if (!first) sb.append(',')
                first = false
                sb.append(jsonString(k.toString())).append(':').append(jsonEncode(vv))
            }
            sb.append('}')
            sb.toString()
        }
        is List<*> -> {
            val sb = StringBuilder("[")
            for ((i, vv) in v.withIndex()) {
                if (i > 0) sb.append(',')
                sb.append(jsonEncode(vv))
            }
            sb.append(']')
            sb.toString()
        }
        else -> jsonString(v.toString())
    }

    private fun jsonString(s: String): String {
        val sb = StringBuilder(s.length + 2)
        sb.append('"')
        for (c in s) {
            when (c) {
                '"'  -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> {
                    if (c.code < 0x20) {
                        sb.append("\\u%04x".format(c.code))
                    } else {
                        sb.append(c)
                    }
                }
            }
        }
        sb.append('"')
        return sb.toString()
    }
}