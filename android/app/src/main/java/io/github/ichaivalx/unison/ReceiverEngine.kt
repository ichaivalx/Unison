package io.github.ichaivalx.unison

object ReceiverEngine {
    init { System.loadLibrary("unison") }
    external fun start(): Boolean
    external fun stop()
    external fun setOffsetMs(ms: Float)
    external fun statsJson(): String
    external fun routeChanged()
}
