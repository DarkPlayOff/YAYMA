package io.github.darkplayoff.yayma

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        initRustls(this.applicationContext)
        super.onCreate(savedInstanceState)
    }

    private external fun initRustls(context: android.content.Context)

    companion object {
        init {
            System.loadLibrary("yayma")
        }
    }
}
