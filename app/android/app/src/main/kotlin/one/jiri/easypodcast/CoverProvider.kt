package one.jiri.easypodcast

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

class CoverProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val covers = File(requireNotNull(context).cacheDir, "podcast-covers")
        val cover = uri.pathSegments.singleOrNull()
            ?.takeIf { it.endsWith(".img") }
            ?.let { File(covers, it) }
            ?.takeIf { it.parentFile == covers }
            ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(cover, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    // ImageDecoder opens content URIs only as a matching "image/*" type.
    override fun getType(uri: Uri) = "image/*"

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0
}
