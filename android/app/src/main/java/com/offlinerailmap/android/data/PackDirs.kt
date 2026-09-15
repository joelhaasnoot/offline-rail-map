// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

/**
 * Naming of pack folders under `filesDir/packs`.
 *
 * A download goes into `<id>@<timestamp>.download` and is renamed to `<id>@<timestamp>` once every
 * file and `pack.json` are in place, so an installed pack is never half-written. An update therefore
 * sits next to the previous copy for a moment; the newest copy wins and the older one is removed.
 * Each copy has its own path, so the map never mixes cached data of two versions. Packs installed by
 * earlier app versions live in a plain `<id>` folder and count as the oldest copy.
 */
object PackDirs {
    const val STAGING_SUFFIX = ".download"

    fun stagingName(id: String, timestamp: Long): String = "$id@$timestamp$STAGING_SUFFIX"

    fun installedName(stagingName: String): String = stagingName.removeSuffix(STAGING_SUFFIX)

    fun isStaging(name: String): Boolean = name.endsWith(STAGING_SUFFIX)

    /** True for every folder, finished or not, that belongs to pack [id]. */
    fun belongsTo(name: String, id: String): Boolean = name == id || name.startsWith("$id@")

    private fun timestamp(name: String): Long = name.substringAfterLast('@', "").removeSuffix(STAGING_SUFFIX).toLongOrNull() ?: 0L

    /**
     * Splits installed copies into the one to use per pack id (highest version, then newest folder)
     * and the superseded ones that can be deleted.
     */
    fun <T> choose(copies: List<T>, id: (T) -> String, version: (T) -> Int, folderName: (T) -> String): Pair<List<T>, List<T>> {
        val chosen = ArrayList<T>()
        val superseded = ArrayList<T>()
        for ((_, group) in copies.groupBy(id)) {
            val sorted = group.sortedWith(compareByDescending<T> { version(it) }.thenByDescending { timestamp(folderName(it)) })
            chosen.add(sorted.first())
            superseded.addAll(sorted.drop(1))
        }
        return chosen to superseded
    }
}
