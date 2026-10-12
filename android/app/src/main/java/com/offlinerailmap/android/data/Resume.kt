// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

package com.offlinerailmap.android.data

/**
 * HTTP rules for continuing a partly downloaded file. A request for the rest of a file carries
 * `Range` plus `If-Range` with the validator of the response the partial file came from, so a file
 * that changed on the server in the meantime is sent whole instead of being stitched together.
 */
object Resume {
    /** The validator to store for a response: a strong ETag, else Last-Modified, else nothing. */
    fun validator(etag: String?, lastModified: String?): String? = when {
        etag != null && !etag.startsWith("W/") -> etag
        else -> lastModified
    }

    /**
     * Where to continue writing after a response to a request for bytes from [have] onwards: [have]
     * when the server sent exactly that range, 0 when it sent the whole file, null when the response
     * cannot be used and the partial file should be dropped.
     */
    fun writeOffset(code: Int, contentRange: String?, have: Long): Long? = when (code) {
        206 -> if (contentRange != null && rangeStart(contentRange) == have) have else null
        in 200..299 -> 0L
        else -> null
    }

    /** First byte of a `Content-Range: bytes <first>-<last>/<size>` header. */
    private fun rangeStart(contentRange: String): Long? =
        contentRange.trim().removePrefix("bytes").trim().substringBefore('-').toLongOrNull()

    /** Server errors and rate limiting are worth trying again; other failed responses are not. */
    fun isRetryable(code: Int): Boolean = code >= 500 || code == 408 || code == 429
}
