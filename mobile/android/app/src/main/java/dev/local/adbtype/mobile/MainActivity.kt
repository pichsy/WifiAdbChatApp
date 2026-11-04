package dev.local.adbtype.mobile

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.local.adbtype.mobile.core.StatusKind
import dev.local.adbtype.mobile.ui.LanApp
import dev.local.adbtype.mobile.ui.theme.AdbTypeTheme

class MainActivity : ComponentActivity() {

    private var viewModelRef: LanViewModel? = null

    /** API 28 的运行时存储权限请求（API 29+ 走 MediaStore，不需要权限）。 */
    private val storagePermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val viewModel = viewModelRef ?: return@registerForActivityResult
        viewModel.onStoragePermissionChanged()
        viewModel.setStatusMessage(
            if (granted) {
                "已授权存储权限，收到的文件会保存到 下载/文件互传助手"
            } else {
                "未授予存储权限，收到的文件只能先保存到应用专属目录"
            },
            if (granted) StatusKind.SUCCESS else StatusKind.WARNING,
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            AdbTypeTheme {
                val viewModel: LanViewModel = viewModel()
                viewModelRef = viewModel
                LanApp(viewModel = viewModel)
            }
        }
        requestLegacyStoragePermissionIfNeeded()
    }

    private fun requestLegacyStoragePermissionIfNeeded() {
        if (Build.VERSION.SDK_INT > Build.VERSION_CODES.P) return
        val permission = Manifest.permission.WRITE_EXTERNAL_STORAGE
        val granted = ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
        if (granted) return
        storagePermissionLauncher.launch(permission)
    }
}
