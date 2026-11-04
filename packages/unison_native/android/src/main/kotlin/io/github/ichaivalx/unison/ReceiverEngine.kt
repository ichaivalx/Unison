package io.github.ichaivalx.unison

object ReceiverEngine {
    init { System.loadLibrary("unison") }
    external fun start(sourceHost: String): Boolean
    external fun stop()
    external fun setOffsetUs(us: Long)
    external fun statsJson(): String
    external fun routeChanged()
    external fun receiverId(): Long
}
