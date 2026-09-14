// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package app.offlinerailwaymap.map

import android.content.Context
import android.content.res.AssetManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.util.DisplayMetrics
import android.util.Log
import android.util.LruCache
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.roundToInt

/**
 * Draws the icons described by [ComposedImage] from the bundled sprite sheet, for the map's and the
 * key's "style image missing" callbacks. Like the website, both the normal and the SDF variant are
 * made at once, so whichever the style asks for first, the other is already there.
 *
 * MapLibre needs the image before the callback returns, so composing happens on the main thread and
 * must be quick. Decoding a region of the PNG sheet is not (the rows above it are decoded too), so
 * [warmUp] decodes the icons composed icons are made of in the background, a few strips at a time.
 */
class SpriteComposer private constructor(private val assets: AssetManager, private val suffix: String) {
    /** A composed icon, registered as [id] and `sdf:`[id]. */
    class Images(val id: String, val image: Bitmap, val sdf: Bitmap) {
        fun addTo(addImage: (name: String, bitmap: Bitmap, sdf: Boolean) -> Unit) {
            addImage(id, image, false)
            addImage(ComposedImage.SDF_PREFIX + id, sdf, true)
        }
    }

    private val sprite: Map<String, ComposedImage.SpriteImage> by lazy {
        ComposedImage.parseSprite(assets.open("sprites/symbols$suffix.json").bufferedReader().use { it.readText() })
    }

    private val decoder: BitmapRegionDecoder by lazy {
        assets.open("sprites/symbols$suffix.png").use { stream ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                BitmapRegionDecoder.newInstance(stream)
            } else {
                @Suppress("DEPRECATION")
                BitmapRegionDecoder.newInstance(stream, false)
            }
        } ?: error("cannot decode sprites/symbols$suffix.png")
    }

    /** Decoded sprite icons. Only components of composed icons end up here, which keeps it small. */
    private val icons = ConcurrentHashMap<ComposedImage.SpriteImage, Bitmap>()
    private val composed = object : LruCache<String, Images>(8 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Images) = value.image.byteCount + value.sdf.byteCount
    }
    private val failed = HashSet<String>()

    /**
     * Decodes the icons used by the composed icons in legend.json, which lists the website's catalogue
     * of signals. Call off the main thread; composing meanwhile still works, just slower.
     */
    fun warmUp() {
        val start = System.nanoTime()
        val legend = JSONObject(assets.open("style/legend.json").bufferedReader().use { it.readText() })
        val wanted = ComposedImage.components(ComposedImage.composites(legend), sprite).filter { !icons.containsKey(it) }
        val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
        for (band in ComposedImage.bands(wanted, BAND_HEIGHT)) {
            val strip = decoder.decodeRegion(Rect(band.left, band.top, band.right, band.bottom), options) ?: continue
            for (image in band.images) {
                icons.putIfAbsent(
                    image,
                    Bitmap.createBitmap(strip, image.x - band.left, image.y - band.top, image.width, image.height),
                )
            }
        }
        Log.d(TAG, "decoded ${wanted.size} icons in ${(System.nanoTime() - start) / 1_000_000} ms")
    }

    /** The composed icon for a requested image name (with or without `sdf:`), or null if it cannot be made. */
    fun compose(requested: String): Images? = synchronized(this) {
        val id = ComposedImage.rawId(requested)
        composed.get(id)?.let { return it }
        if (id in failed) {
            return null
        }
        val images = try {
            ComposedImage.layout(id, sprite)?.let { draw(id, it) }
        } catch (e: Exception) {
            Log.w(TAG, "composing $id failed", e)
            null
        }
        if (images == null) {
            Log.w(TAG, "cannot compose missing image $requested")
            failed += id
        } else {
            composed.put(id, images)
        }
        images
    }

    private fun draw(id: String, layout: ComposedImage.Layout): Images {
        val width = layout.pixelWidth
        val height = layout.pixelHeight
        val density = (layout.pixelRatio * DisplayMetrics.DENSITY_DEFAULT).roundToInt()

        // Normal icons drawn over each other at their (possibly half pixel) offsets, as the website's canvas does.
        val image = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(image)
        canvas.density = Bitmap.DENSITY_NONE
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        for (placed in layout.images) {
            canvas.drawBitmap(icon(placed.image), placed.x.toFloat(), placed.y.toFloat(), paint)
        }
        image.density = density

        val alphas = layout.images.map { placed ->
            val icon = icon(placed.sdfImage)
            val pixels = IntArray(icon.width * icon.height)
            icon.getPixels(pixels, 0, icon.width, 0, 0, icon.width, icon.height)
            IntArray(pixels.size) { pixels[it] ushr 24 }
        }
        val distances = ComposedImage.composeSdf(layout, alphas)
        val sdf = Bitmap.createBitmap(IntArray(distances.size) { distances[it] shl 24 }, width, height, Bitmap.Config.ARGB_8888)
        sdf.density = density

        return Images(id, image, sdf)
    }

    private fun icon(entry: ComposedImage.SpriteImage): Bitmap = icons.getOrPut(entry) {
        Log.d(TAG, "decoding sprite icon at ${entry.x},${entry.y} on demand")
        val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
        val rect = Rect(entry.x, entry.y, entry.x + entry.width, entry.y + entry.height)
        decoder.decodeRegion(rect, options) ?: error("cannot decode sprite region $rect")
    }.also { it.density = Bitmap.DENSITY_NONE }

    companion object {
        private const val TAG = "SpriteComposer"

        /** Strip height for [warmUp]: bounds the memory of one region decode. */
        private const val BAND_HEIGHT = 1024

        private val instances = HashMap<String, SpriteComposer>()

        /** The composer for the sprite sheet MapLibre loads at [pixelRatio] (`@2x` above 1). */
        @Synchronized
        fun forPixelRatio(context: Context, pixelRatio: Float): SpriteComposer {
            val suffix = if (pixelRatio > 1) "@2x" else ""
            return instances.getOrPut(suffix) { SpriteComposer(context.applicationContext.assets, suffix) }
        }
    }
}
