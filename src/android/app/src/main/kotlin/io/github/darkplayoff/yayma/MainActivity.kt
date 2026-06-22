package io.github.darkplayoff.yayma

import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initRustls(this.applicationContext)
    }

    private external fun initRustls(context: android.content.Context)

    companion object {
        init {
            System.loadLibrary("yayma")
        }
    }
}
