package one.jiri.easypodcast

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

// Android Auto loads list covers in its own process, so it needs content URIs.
class CoverProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val name = uri.pathSegments.singleOrNull()
        if (mode != "r" || name == null || !coverName.matches(name)) {
            throw FileNotFoundException(uri.toString())
        }
        val covers = File(requireNotNull(context).cacheDir, "podcast-covers")
        return ParcelFileDescriptor.open(File(covers, name), ParcelFileDescriptor.MODE_READ_ONLY)
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

    private companion object {
        // CoverImage names files by a signed 64-bit hash of the cover address.
        val coverName = Regex("-?[0-9a-f]{1,16}\\.img")
    }
}
