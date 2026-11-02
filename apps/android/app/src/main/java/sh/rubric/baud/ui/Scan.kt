// A link as a QR code, for people in the room, and the camera reading one. Both with ZXing's core
// and CameraX: nothing from Google Play services, so it works on phones without them.
package sh.rubric.baud.ui

import android.annotation.SuppressLint
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.BitMatrix
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/// The QR on a white card with its quiet zone; greyed when it must not be used.
@Composable
fun QRSquare(text: String, side: Dp = 186.dp, greyed: Boolean = false) {
    val matrix = remember(text) { encode(text) }
    Box(
        Modifier.size(side).clip(RoundedCornerShape(12.dp)).background(Color.White).padding(10.dp)
            .semantics { contentDescription = if (greyed) "Not reachable yet" else "Your link" },
    ) {
        Canvas(Modifier.size(side - 20.dp)) {
            val m = matrix ?: return@Canvas
            val cell = size.minDimension / m.width
            val ink = Color.Black.copy(alpha = if (greyed) 0.18f else 1f)
            for (y in 0 until m.height) for (x in 0 until m.width) {
                // Each module a hair larger than its cell, so no seams show between them.
                if (m[x, y]) drawRect(ink, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
            }
        }
    }
}

private fun encode(text: String): BitMatrix? = runCatching {
    QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 0))
}.getOrNull()

/// The camera, reading QR codes: the first one `accept` takes is the one.
@Composable
fun Scanner(modifier: Modifier, accept: (String) -> Boolean) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val done = remember { AtomicBoolean(false) }
    val worker = remember { Executors.newSingleThreadExecutor() }
    val view = remember { PreviewView(context).apply {
        scaleType = PreviewView.ScaleType.FILL_CENTER
        // Drawn in the view tree (a TextureView): the sheet is its own window, and a SurfaceView's
        // surface would sit under it, black.
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
    } }
    DisposableEffect(owner) {
        val future = ProcessCameraProvider.getInstance(context)
        var provider: ProcessCameraProvider? = null
        future.addListener({
            runCatching {
                val p = future.get(); provider = p
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val reader = MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)) }
                val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysis.setAnalyzer(worker) { image ->
                    val text = read(reader, image)
                    image.close()
                    if (text != null && !done.get()) ContextCompat.getMainExecutor(context).execute { if (!done.get() && accept(text)) done.set(true) }
                }
                p.unbindAll()
                p.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }.onFailure { e ->
                // No back camera (an emulator set up without one): try the front, else nothing.
                runCatching {
                    val p = future.get()
                    val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                    p.bindToLifecycle(owner, CameraSelector.DEFAULT_FRONT_CAMERA, preview)
                }.onFailure { Log.w("baud", "camera: $e / $it") }
            }
        }, ContextCompat.getMainExecutor(context))
        onDispose { provider?.unbindAll(); worker.shutdown() }
    }
    AndroidView({ view }, modifier.clip(RoundedCornerShape(12.dp)).background(Color.Black))
}

private var frames = 0L

@SuppressLint("UnsafeOptInUsageError")
private fun read(reader: MultiFormatReader, image: ImageProxy): String? {
    val plane = image.planes.firstOrNull() ?: return null
    val buf = plane.buffer
    val data = ByteArray(buf.remaining()).also { buf.get(it) }
    if (frames++ % 60 == 0L) Log.d("baud", "scan: frame ${image.width}x${image.height} stride ${plane.rowStride} mean ${data.asSequence().take(200_000).map { it.toInt() and 0xFF }.average().toInt()}")
    val width = plane.rowStride
    val source = PlanarYUVLuminanceSource(data, width, image.height, 0, 0, image.width, image.height, false)
    return runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text }.getOrNull()
        ?: runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(source.invert()))).text }.getOrNull()
        .also { reader.reset() }
}
