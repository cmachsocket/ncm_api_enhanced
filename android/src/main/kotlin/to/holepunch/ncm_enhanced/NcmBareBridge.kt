// android/src/main/kotlin/to/holepunch/ncm_enhanced/NcmBareBridge.kt
//
// Android platform plugin for ncm_api_enhanced. Implements
// FlutterPlugin so the Flutter build toolchain wires it up
// automatically when this package is added to a host app's
// pubspec.yaml dependencies — no host-app glue required.
//
// Wire protocol on the Dart side (see lib/src/mobile_bridge.dart):
//
//   MethodChannel("ncm_bridge/methods")
//     "start"      → loads dist/ncm.bundle into a bare Worklet and
//                    opens an IPC channel.
//     "write"      → forwards a NDJSON line to the Worklet's IPC.
//     "shutdown"   → terminates the Worklet.
//     "isRunning"  → returns Boolean.
//     "dataDir"    → returns the host app's filesDir (used by Dart to
//                    locate the extracted bridge assets).
//
//   EventChannel("ncm_bridge/events")
//     Emits one event per IPC read. Each event is a Map:
//
//       { "type": "ready" }
//       { "type": "stdout", "data": "<line>" }
//       { "type": "stderr", "data": "<line>" }
//       { "type": "fatal",  "data": "<message>" }
//
// The worklet speaks NDJSON over IPC — the same protocol the
// nodejs-mobile stdio design used — so bridge.js runs unchanged.
// See assets/bridge/bridge.js for the consumer.

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
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

class NcmBareBridge : FlutterPlugin, ActivityAware {
  companion object {
    private const val TAG = "NcmBareBridge"
    private const val METHOD_CHANNEL = "ncm_bridge/methods"
    private const val EVENT_CHANNEL = "ncm_bridge/events"
  }

  // -----------------------------------------------------------------
  // State
  // -----------------------------------------------------------------

  @Volatile private var worklet: Worklet? = null
  @Volatile private var ipc: IPC? = null
  @Volatile private var lineBuffer = StringBuilder()

  private val mainHandler = Handler(Looper.getMainLooper())

  private var appContext: Context? = null
  private var methodChannel: MethodChannel? = null
  private var eventChannel: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null

  // -----------------------------------------------------------------
  // FlutterPlugin lifecycle
  // -----------------------------------------------------------------

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext

    methodChannel = MethodChannel(
      binding.binaryMessenger,
      METHOD_CHANNEL,
    ).also {
      it.setMethodCallHandler(::onMethodCall)
    }

    eventChannel = EventChannel(
      binding.binaryMessenger,
      EVENT_CHANNEL,
    ).also {
      it.setStreamHandler(
        object : EventChannel.StreamHandler {
          override fun onListen(args: Any?, sink: EventChannel.EventSink) {
            eventSink = sink
          }

          override fun onCancel(args: Any?) {
            eventSink = null
          }
        },
      )
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    try {
      ipc?.close()
      ipc = null
      worklet?.terminate()
      worklet = null
    } catch (_: Throwable) {
      // Detach path is best-effort; the process is going away.
    }

    methodChannel?.setMethodCallHandler(null)
    methodChannel = null

    eventChannel?.setStreamHandler(null)
    eventChannel = null
    eventSink = null

    appContext = null
  }

  // ActivityAware is implemented so we can pick up a Context whose
  // filesDir we can hand to Dart. We do not need to react to
  // onAttachedToActivity beyond caching the binding's activity.

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {}

  override fun onDetachedFromActivityForConfigChanges() {}

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {}

  override fun onDetachedFromActivity() {}

  // -----------------------------------------------------------------
  // Method dispatch
  // -----------------------------------------------------------------

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> handleStart(call, result)
      "write" -> handleWrite(call, result)
      "shutdown" -> handleShutdown(result)
      "isRunning" -> result.success(worklet != null)
      "dataDir" -> handleDataDir(result)
      else -> result.notImplemented()
    }
  }

  // -----------------------------------------------------------------
  // start
  //
  // The Dart side passes the absolute path of dist/ncm.bundle (the
  // bare-pack output). We read the file, hand it to
  // Worklet.start("/app.js", source, …), then open an IPC channel and
  // register a polling callback so each chunk delivered by the
  // worklet becomes one or more NDJSON events on the Dart side.
  // -----------------------------------------------------------------

  private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
    if (worklet != null) {
      result.error("already_started", "Worklet is already running", null)
      return
    }

    val bundlePath = call.argument<String>("bundlePath")
    if (bundlePath == null) {
      result.error("invalid_args", "bundlePath is required", null)
      return
    }

    try {
      val file = File(bundlePath)
      if (!file.exists()) {
        result.error("bundle_not_found", "no such file: $bundlePath", null)
        return
      }

      val sourceBytes = file.readBytes()
      val source = ByteBuffer.allocateDirect(sourceBytes.size).apply {
        put(sourceBytes)
        flip()
      }

      // 24 MiB — same default bare-kit's Android sample uses.
      val options = Worklet.Options().memoryLimit(24 * 1024 * 1024)

      val w = Worklet(options)
      w.start("/app.js", source, null)

      val i = IPC(w)

      worklet = w
      ipc = i

      i.readable { drainIpc() }
      i.writable {
        // Slow-path completion for partial IPC writes. For typical
        // NDJSON request lines (a few hundred bytes) the first write
        // almost always accepts the full payload and this callback
        // is not invoked.
      }

      emit(mapOf("type" to "ready"))

      result.success(null)
    } catch (e: Throwable) {
      Log.e(TAG, "start failed", e)
      result.error("start_failed", e.message, null)
    }
  }

  // -----------------------------------------------------------------
  // write
  //
  // NDJSON line from Dart. Append to a line buffer until we see
  // '\n', then forward the complete line to the worklet over IPC.
  // -----------------------------------------------------------------

  private fun handleWrite(call: MethodCall, result: MethodChannel.Result) {
    val i = ipc ?: run {
      result.error("not_running", "Worklet is not running", null)
      return
    }

    val bytes = call.argument<ByteArray>("bytes")
    if (bytes == null) {
      result.error("invalid_args", "bytes is required", null)
      return
    }

    try {
      lineBuffer.append(String(bytes, StandardCharsets.UTF_8))

      var newlineIndex = lineBuffer.indexOf("\n")
      while (newlineIndex >= 0) {
        val line = lineBuffer.substring(0, newlineIndex)
        lineBuffer.delete(0, newlineIndex + 1)

        writeLine(i, line)
        newlineIndex = lineBuffer.indexOf("\n")
      }

      result.success(null)
    } catch (e: Throwable) {
      Log.e(TAG, "write failed", e)
      result.error("write_failed", e.message, null)
    }
  }

  private fun writeLine(ipc: IPC, line: String) {
    val payload = "$line\n".toByteArray(StandardCharsets.UTF_8)
    val buffer = ByteBuffer.allocateDirect(payload.size).apply {
      put(payload)
      flip()
    }

    val written = ipc.write(buffer)
    if (written < buffer.limit()) {
      Log.w(TAG, "IPC partial write: $written / ${buffer.limit()}")
    }
  }

  // -----------------------------------------------------------------
  // IPC read loop
  // -----------------------------------------------------------------

  private fun drainIpc() {
    val i = ipc ?: return

    while (true) {
      val data: ByteBuffer = i.read() ?: break

      val text = StandardCharsets.UTF_8.decode(data).toString()
      text.split("\n").forEach { line ->
        val cleaned = line.trimEnd('\r')
        if (cleaned.isNotEmpty()) {
          emit(mapOf("type" to "stdout", "data" to cleaned))
        }
      }
    }
  }

  // -----------------------------------------------------------------
  // shutdown
  // -----------------------------------------------------------------

  private fun handleShutdown(result: MethodChannel.Result) {
    try {
      ipc?.close()
      ipc = null

      worklet?.terminate()
      worklet = null

      lineBuffer = StringBuilder()

      result.success(null)
    } catch (e: Throwable) {
      Log.e(TAG, "shutdown failed", e)
      result.error("shutdown_failed", e.message, null)
    }
  }

  // -----------------------------------------------------------------
  // dataDir
  // -----------------------------------------------------------------

  private fun handleDataDir(result: MethodChannel.Result) {
    val ctx = appContext
    if (ctx == null) {
      result.error("no_context", "plugin is not attached to an engine", null)
      return
    }
    result.success(ctx.filesDir.absolutePath)
  }

  // -----------------------------------------------------------------
  // Emit a Dart-side event
  // -----------------------------------------------------------------

  private fun emit(event: Map<String, Any?>) {
    val sink = eventSink ?: return

    mainHandler.post {
      try {
        sink.success(event)
      } catch (e: Throwable) {
        Log.w(TAG, "eventSink.success failed", e)
      }
    }
  }
}
