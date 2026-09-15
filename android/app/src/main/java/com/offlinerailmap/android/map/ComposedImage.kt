// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.map

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Icons the style asks for but the sprite does not contain, composed from sprite icons, ported from
 * the OpenRailwayMap website (`generateImage`, `loadImages` and `layoutImages` in proxy/js/ui.js).
 *
 * An id such as `fi/t-270|fi/t-271-top-{1}` stacks several sprite icons; each part after the first
 * may carry a position (`@center`, `@bottom`, `@top`, `@right`, `@left`, default centre) relative to
 * what has been composed so far. A request for `sdf:<id>` wants the SDF variant of the same id,
 * composed from the `sdf:` icons of the parts. Sizes are in sprite pixels.
 *
 * This object only parses ids and computes the layout; drawing happens in [SpriteComposer].
 */
object ComposedImage {
    const val SDF_PREFIX = "sdf:"

    enum class Position { CENTER, BOTTOM, TOP, RIGHT, LEFT }

    data class Part(val id: String, val position: Position)

    /** One icon of the sprite sheet (an entry of `symbols*.json`). */
    data class SpriteImage(
        val x: Int,
        val y: Int,
        val width: Int,
        val height: Int,
        val pixelRatio: Double,
        val sdf: Boolean,
    )

    /**
     * A part placed in the composed image: [x]/[y] is the top left corner of the normal icon (may be
     * a half pixel, as on the website), [sdfX]/[sdfY] that of its larger SDF icon.
     */
    data class Placed(
        val part: Part,
        val image: SpriteImage,
        val sdfImage: SpriteImage,
        val x: Double,
        val y: Double,
        val sdfX: Int,
        val sdfY: Int,
    )

    data class Layout(val width: Double, val height: Double, val images: List<Placed>) {
        /** Bitmap size: a canvas truncates a fractional size, as the website's canvas does. */
        val pixelWidth: Int get() = width.toInt()
        val pixelHeight: Int get() = height.toInt()
        val pixelRatio: Double get() = images[0].image.pixelRatio
    }

    private val imageMatcher = Regex("([^@]+)(@(center|bottom|top|right|left))?")

    /** The id without an `sdf:` prefix; both variants of a composed image are registered under it. */
    fun rawId(requested: String): String = requested.removePrefix(SDF_PREFIX)

    fun isSdf(requested: String): Boolean = requested.startsWith(SDF_PREFIX)

    /** Whether a string looks like a composed icon id (stacked or positioned), as opposed to a plain sprite icon. */
    fun isComposite(value: String): Boolean = '|' in value || '@' in value

    /** The parts of a raw id, or null when a part cannot be parsed (the website throws). */
    fun parse(rawId: String): List<Part>? = rawId.split("|").map { imageId ->
        val match = imageMatcher.matchEntire(imageId) ?: return null
        val position = match.groupValues[3].takeIf { it.isNotEmpty() }?.let { Position.valueOf(it.uppercase()) }
        Part(match.groupValues[1], position ?: Position.CENTER)
    }

    /** Sprite index from a `symbols*.json` file. */
    fun parseSprite(json: String): Map<String, SpriteImage> {
        val obj = JSONObject(json)
        val result = HashMap<String, SpriteImage>(obj.length() * 2)
        for (name in obj.keys()) {
            val e = obj.getJSONObject(name)
            result[name] = SpriteImage(
                x = e.getInt("x"),
                y = e.getInt("y"),
                width = e.getInt("width"),
                height = e.getInt("height"),
                pixelRatio = e.optDouble("pixelRatio", 1.0),
                sdf = e.optBoolean("sdf", false),
            )
        }
        return result
    }

    /** Layout for a raw id, or null when it cannot be parsed or a part (or its SDF icon) is not in the sprite. */
    fun layout(rawId: String, sprite: Map<String, SpriteImage>): Layout? {
        val parts = parse(rawId) ?: return null
        return layout(parts, sprite)
    }

    fun layout(parts: List<Part>, sprite: Map<String, SpriteImage>): Layout? {
        if (parts.isEmpty()) {
            return null
        }
        val images = parts.map { sprite[it.id] ?: return null }
        val sdfImages = parts.map { sprite[SDF_PREFIX + it.id] ?: return null }

        // Ignore position of first image. The width and height grow as more images are composed.
        var width = images[0].width.toDouble()
        var height = images[0].height.toDouble()

        // Top left corner of each image.
        val xs = DoubleArray(parts.size)
        val ys = DoubleArray(parts.size)

        // Offset of the top left corner of the composed image, so images can be added to the top or
        // left without moving the images placed before.
        var globalX = 0.0
        var globalY = 0.0

        for (i in 1 until parts.size) {
            val w = images[i].width.toDouble()
            val h = images[i].height.toDouble()
            when (parts[i].position) {
                Position.CENTER -> {
                    xs[i] = globalX + width / 2 - w / 2
                    ys[i] = globalY + height / 2 - h / 2
                    globalX = min(globalX, xs[i])
                    globalY = min(globalY, ys[i])
                    width = max(width, w)
                    height = max(height, h)
                }
                Position.BOTTOM -> {
                    xs[i] = globalX + width / 2 - w / 2
                    ys[i] = globalY + height
                    globalX = min(globalX, xs[i])
                    globalY = min(globalY, ys[i])
                    width = max(width, w)
                    height += h
                }
                Position.TOP -> {
                    xs[i] = globalX + width / 2 - w / 2
                    ys[i] = globalY - h
                    globalX = min(globalX, xs[i])
                    globalY = min(globalY, ys[i])
                    width = max(width, w)
                    height += h
                }
                Position.RIGHT -> {
                    xs[i] = globalX + width
                    ys[i] = globalY + height / 2 - h / 2
                    globalX = min(globalX, xs[i])
                    globalY = min(globalY, ys[i])
                    width += w
                    height = max(height, h)
                }
                Position.LEFT -> {
                    // Upstream places it half its width to the left, not its full width.
                    xs[i] = globalX - w / 2
                    ys[i] = globalY + height / 2 - h / 2
                    globalX = min(globalX, xs[i])
                    globalY = min(globalY, ys[i])
                    width += w
                    height = max(height, h)
                }
            }
        }

        // SDF images are larger than the normal images due to padding pixels.
        for (i in parts.indices) {
            width = max(width, xs[i] - globalX + sdfImages[i].width)
            height = max(height, ys[i] - globalY + sdfImages[i].height)
        }
        for (i in parts.indices) {
            globalX = min(globalX, xs[i] + images[i].width / 2.0 - sdfImages[i].width / 2.0)
            globalY = min(globalY, ys[i] + images[i].height / 2.0 - sdfImages[i].height / 2.0)
        }

        val placed = parts.indices.map { i ->
            val x = xs[i] - globalX
            val y = ys[i] - globalY
            Placed(
                part = parts[i],
                image = images[i],
                sdfImage = sdfImages[i],
                x = x,
                y = y,
                sdfX = floor(x + images[i].width / 2.0 - sdfImages[i].width / 2.0).toInt(),
                sdfY = floor(y + images[i].height / 2.0 - sdfImages[i].height / 2.0).toInt(),
            )
        }
        return Layout(width, height, placed)
    }

    /** Composed icon ids among the string values of a legend.json tree (feature keys are skipped). */
    fun composites(json: Any?): Set<String> {
        val result = LinkedHashSet<String>()
        fun walk(value: Any?) {
            when (value) {
                is JSONObject -> value.keys().forEach { key ->
                    if (key != "keys") {
                        walk(value.opt(key))
                    }
                }
                is JSONArray -> (0 until value.length()).forEach { walk(value.opt(it)) }
                is String -> if (isComposite(value)) {
                    result += value
                }
            }
        }
        walk(json)
        return result
    }

    private val valuePlaceholder = Regex("\\{[^}]+\\}") // closing brace escaped: Android's ICU regex rejects a bare one

    /**
     * The sprite icons (normal and SDF) that [composites] are made of, plus the other values of icons
     * with a `{value}` placeholder (e.g. every `fi/t-271-top-{n}` when one is used), which the map data
     * combines in ways the legend does not list.
     */
    fun components(composites: Iterable<String>, sprite: Map<String, SpriteImage>): Set<SpriteImage> {
        val names = composites.flatMap { parse(it).orEmpty() }.map { it.id }.filter { it in sprite }.toMutableSet()
        val families = names.filter { '{' in it }.map { valuePlaceholder.replace(it, "{}") }.toSet()
        if (families.isNotEmpty()) {
            sprite.keys.filterTo(names) { !isSdf(it) && '{' in it && valuePlaceholder.replace(it, "{}") in families }
        }
        return names.flatMap { listOfNotNull(sprite[it], sprite[SDF_PREFIX + it]) }.toSet()
    }

    /** A horizontal strip of the sprite sheet holding [images]; right and bottom are exclusive. */
    data class Band(val left: Int, val top: Int, val right: Int, val bottom: Int, val images: List<SpriteImage>)

    /**
     * Groups [images] into strips at most [maxHeight] pixels high (or one icon high, if taller), so
     * they can be decoded with a few region decodes instead of one per icon.
     */
    fun bands(images: Collection<SpriteImage>, maxHeight: Int): List<Band> {
        val result = ArrayList<Band>()
        var current = ArrayList<SpriteImage>()
        var top = 0
        var bottom = 0
        fun flush() {
            if (current.isNotEmpty()) {
                result += Band(current.minOf { it.x }, top, current.maxOf { it.x + it.width }, bottom, current)
                current = ArrayList()
            }
        }
        for (image in images.sortedBy { it.y }) {
            if (current.isNotEmpty() && max(bottom, image.y + image.height) - top > maxHeight) {
                flush()
            }
            if (current.isEmpty()) {
                top = image.y
                bottom = image.y + image.height
            }
            bottom = max(bottom, image.y + image.height)
            current += image
        }
        flush()
        return result
    }

    /**
     * The composed SDF image: per pixel the largest distance value (alpha) of the SDF icons covering it.
     *
     * @param alphas alpha channel of each placed part's SDF icon, row by row, in [Layout.images] order
     * @return alpha per pixel of the [Layout.pixelWidth] x [Layout.pixelHeight] image, row by row
     */
    fun composeSdf(layout: Layout, alphas: List<IntArray>): IntArray {
        val width = layout.pixelWidth
        val height = layout.pixelHeight
        val result = IntArray(width * height)
        layout.images.forEachIndexed { index, placed ->
            val source = alphas[index]
            val sw = placed.sdfImage.width
            val sh = placed.sdfImage.height
            for (y in max(0, placed.sdfY) until min(height, placed.sdfY + sh)) {
                for (x in max(0, placed.sdfX) until min(width, placed.sdfX + sw)) {
                    val value = source[(y - placed.sdfY) * sw + (x - placed.sdfX)]
                    val i = y * width + x
                    if (value > result[i]) {
                        result[i] = value
                    }
                }
            }
        }
        return result
    }
}
